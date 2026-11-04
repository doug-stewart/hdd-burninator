#!/usr/bin/env bash
#
# hdd-burninator - parallel burn-in for new hard drives on TrueNAS (Community Edition / SCALE)
# https://github.com/doug-stewart/hdd-burninator
#
# For every drive, in parallel:
#   1. SMART extended (long) self-test
#   2. badblocks write pass (random pattern)   *** ERASES THE DRIVE ***
#   3. badblocks read-back verify pass
#   4. Final SMART check, compared against the starting values
#
# Results are printed to the console as a table. Nothing is written to disk:
# while the tests run, progress is tracked in /run (memory, cleared on reboot),
# and it is removed once the final results have been shown.
#
# The tests run in the background, so closing the browser shell or SSH session
# does not stop them. Reopen the progress view at any time with --status.
#
# Usage:
#   sudo bash hdd-burninator.sh              # every spinning disk (skips SSDs, NVMe, USB and the boot drive)
#   sudo bash hdd-burninator.sh sda sdb      # only the drives you name (sda, /dev/sda or /dev/disk/by-id/...)
#   sudo bash hdd-burninator.sh --status     # reopen the progress view, or show final results
#
# Options:
#   --status          Reopen the progress view for the current run
#   --skip-smart      Skip the SMART long test and go straight to badblocks
#   --refresh SEC     How often the progress view refreshes (default: 30)
#   -h, --help        Show this help

set -uo pipefail

RUN_ROOT="${BURNIN_DIR:-/run/hdd-burninator}"
SMART_POLL=${BURNIN_SMART_POLL:-300}        # seconds between SMART long-test progress checks
SMART_START_WAIT=${BURNIN_SMART_WAIT:-60}   # pause after starting the SMART test before the first check
BB_POLL=${BURNIN_BB_POLL:-60}               # seconds between badblocks progress checks
BB_TRIM=${BURNIN_BB_TRIM:-262144}           # trim badblocks progress output above this many bytes
REFRESH=${BURNIN_REFRESH:-30}               # seconds between progress view refreshes
TEMP_WARN=${BURNIN_TEMP_WARN:-45}           # flag drives at or above this temperature (C)
SELF="$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null)"

die() { echo "ERROR: $*" >&2; exit 1; }

usage() { sed -n '2,/^$/p' "$SELF" | sed 's/^# \{0,1\}//'; }

# ------------------------------------------------------------ terminal setup

setup_terminal() {
  local locs loc
  UNI=0
  if [[ ${BURNIN_ASCII:-0} != 1 ]]; then
    if [[ ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} =~ [Uu][Tt][Ff]-?8 ]]; then
      UNI=1
    else
      locs=$(locale -a 2>/dev/null)
      for loc in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
        if grep -qxF "$loc" <<<"$locs"; then export LC_ALL=$loc; UNI=1; break; fi
      done
    fi
  fi
  if ((UNI)); then
    H='─' V='│' TL='┌' TM='┬' TR='┐' ML='├' MM='┼' MR='┤' BL='└' BM='┴' BR='┘'
    FULL='█' EMPTY='░' ARROW='→' DEG='°C' DASH='—'
  else
    H='-' V='|' TL='+' TM='+' TR='+' ML='+' MM='+' MR='+' BL='+' BM='+' BR='+'
    FULL='#' EMPTY='.' ARROW='->' DEG='C' DASH='-'
  fi
  C_RED='' C_YEL='' C_GRN='' C_BOLD='' C_OFF=''
  if [[ -t 1 ]] && (($(tput colors 2>/dev/null || echo 0) >= 8)); then
    C_RED=$'\e[31m' C_YEL=$'\e[33m' C_GRN=$'\e[32m' C_BOLD=$'\e[1m' C_OFF=$'\e[0m'
  fi
}

# ---------------------------------------------------------------- formatting

fmt_dur() {  # seconds -> "3h 05m" / "1d 04h 12m"
  local s=${1:-0} d h m
  [[ $s =~ ^[0-9]+$ ]] || { echo "?"; return; }
  d=$((s / 86400)); h=$(((s % 86400) / 3600)); m=$(((s % 3600) / 60))
  if ((d > 0)); then printf '%dd %02dh %02dm' "$d" "$h" "$m"; else printf '%dh %02dm' "$h" "$m"; fi
}

hms_to_s() {  # "1:23:45" or "23:45" -> seconds
  local a b c
  IFS=: read -r a b c <<<"$1"
  if [[ -n ${c:-} ]]; then echo $((10#$a * 3600 + 10#$b * 60 + 10#$c))
  else echo $((10#${a:-0} * 60 + 10#${b:-0})); fi
}

rep() { local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }

join_by() {  # join_by "; " a b c
  local sep=$1 out="" x; shift
  for x in "$@"; do [[ -z $out ]] && out=$x || out="$out$sep$x"; done
  printf '%s' "$out"
}

bar() {  # bar PCT -> "███████░░░░░░░  45%"
  local p=${1:-0} n=20 f
  [[ $p =~ ^[0-9]+$ ]] || p=0
  ((p > 100)) && p=100
  f=$((p * n / 100))
  printf '%s%s %3d%%' "$(rep "$FULL" "$f")" "$(rep "$EMPTY" $((n - f)))" "$p"
}

colorize() {  # colorize PADDED_CELL TEXT
  case $2 in
    *FAIL* | *STOPPED* | *INCOMPLETE*) printf '%s%s%s%s' "$C_BOLD" "$C_RED" "$1" "$C_OFF" ;;
    *WARN*) printf '%s%s%s%s' "$C_BOLD" "$C_YEL" "$1" "$C_OFF" ;;
    *PASS*) printf '%s%s%s%s' "$C_BOLD" "$C_GRN" "$1" "$C_OFF" ;;
    *) printf '%s' "$1" ;;
  esac
}

draw_table() {  # draw_table COLOR_COL "head|head|..." "cell|cell|..." ...
  local color_col=$1; shift
  local -a rows=("$@") w=() cells
  local r i n c line cell first=1
  for r in "${rows[@]}"; do
    IFS='|' read -r -a cells <<<"$r"
    for i in "${!cells[@]}"; do
      c=${cells[$i]}
      ((${#c} > ${w[$i]:-0})) && w[i]=${#c}
    done
  done
  n=${#w[@]}
  _hline() {
    local s=$1 j
    for ((j = 0; j < n; j++)); do
      s+=$(rep "$H" $((w[j] + 2)))
      ((j < n - 1)) && s+=$2
    done
    printf '%s%s\n' "$s" "$3"
  }
  _hline "$TL" "$TM" "$TR"
  for r in "${rows[@]}"; do
    IFS='|' read -r -a cells <<<"$r"
    line=$V
    for ((i = 0; i < n; i++)); do
      c=${cells[$i]:-}
      cell=" $c$(rep ' ' $((w[i] - ${#c}))) "
      ((i == color_col && !first)) && cell=$(colorize "$cell" "$c")
      line+="$cell$V"
    done
    printf '%s\n' "$line"
    if ((first)); then _hline "$ML" "$MM" "$MR"; first=0; fi
  done
  _hline "$BL" "$BM" "$BR"
}

# --------------------------------------------------------------------- SMART
# Works for both SAS (SCSI) and SATA (ATA) drives; smartctl formats differ.

smart_health() {  # -> PASSED / OK / FAILED / ...
  smartctl -H "$1" 2>/dev/null |
    awk -F': *' '/overall-health self-assessment test result|SMART Health Status/ {print $2; exit}'
}

drive_temp() {  # -> degrees C, or empty
  smartctl -A "$1" 2>/dev/null | awk '
    /Current Drive Temperature/ {print $4; exit}
    $2 == "Temperature_Celsius" || $2 == "Airflow_Temperature_Cel" {print $10; exit}'
}

selftest_running() {
  # capture first: `smartctl | grep -q` can falsely fail under pipefail (SIGPIPE)
  local out
  out=$(smartctl -a "$1" 2>/dev/null)
  grep -qiE 'self[- ]test routine in progress|self test in progress|% of test remaining' <<<"$out"
}

selftest_remaining_pct() {  # SATA reports this; most SAS drives do not
  smartctl -a "$1" 2>/dev/null | grep -oE '[0-9]+% of test remaining' | head -1 | grep -oE '^[0-9]+'
}

smart_expected_min() {  # drive's own estimate of long-test duration, in minutes
  smartctl -a "$1" 2>/dev/null | awk '
    /Long \(extended\) [Ss]elf[- ][Tt]est duration/ {
      for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) { print int($i / 60); exit } }
    /Extended self-test routine/ {
      getline
      if (match($0, /\( *[0-9]+\)/)) { s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); print s; exit } }'
}

selftest_head() {  # most recent entry ("# 1") in the self-test log
  smartctl -l selftest "$1" 2>/dev/null | grep -m1 -E '^# *1[[:space:]]'
}

smart_counts() {  # smartctl -a text on stdin -> "defects uncorrected pending" ("-" if unknown)
  # SAS:  defects = grown defect list,   uncorrected = read+write+verify uncorrected errors
  # SATA: defects = reallocated sectors, uncorrected = pending + offline uncorrectable + reported uncorrect
  awk '
    /Elements in grown defect list/ { d = $NF; hd = 1 }
    /^(read|write|verify):/         { u += $NF; hu = 1 }
    $2 == "Reallocated_Sector_Ct"   { d = $10; hd = 1 }
    $2 == "Current_Pending_Sector"  { p = $10; u += $10; hu = 1 }
    $2 == "Offline_Uncorrectable"   { u += $10; hu = 1 }
    $2 == "Reported_Uncorrect"      { u += $10; hu = 1 }
    END { printf "%s %s %s\n", (hd ? d : "-"), (hu ? u : "-"), (p == "" ? 0 : p) }'
}

# ----------------------------------------------------------------- badblocks

bb_parse() {  # badblocks output file -> "phase_idx pct elapsed_s errors" (empty until first update)
  local f=$1 line idx=0
  grep -aq 'Reading and comparing' "$f" 2>/dev/null && idx=1
  line=$(tail -c 4096 "$f" 2>/dev/null | tr '\b\r' '\n\n' | grep -aE '% done' | tail -1)
  if [[ $line =~ ([0-9]+\.[0-9]+)%\ done,\ ([0-9:]+)\ elapsed\.\ \(([0-9]+)/([0-9]+)/([0-9]+)\ errors\) ]]; then
    echo "$idx ${BASH_REMATCH[1]} $(hms_to_s "${BASH_REMATCH[2]}") $((BASH_REMATCH[3] + BASH_REMATCH[4] + BASH_REMATCH[5]))"
  fi
}

# --------------------------------------------------------------- state (/run)

declare -A K S

save_state() {  # write global K to DIR/state
  local dir=$1 k
  { for k in "${!K[@]}"; do printf '%s=%s\n' "$k" "${K[$k]}"; done; } >"$dir/state.tmp" &&
    mv -f "$dir/state.tmp" "$dir/state"
}

read_state() {  # read DIR/state into global S
  S=()
  local k v
  [[ -f $1/state ]] || return 1
  while IFS='=' read -r k v; do [[ -n $k ]] && S[$k]=$v; done <"$1/state"
}

worker_alive() { local p; p=$(cat "$1/pid" 2>/dev/null) && [[ -n $p ]] && kill -0 "$p" 2>/dev/null; }

drive_dirs() { find "$1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort; }

# -------------------------------------------------------------------- worker

worker() {  # worker DEV DIR SKIP_SMART  (runs detached, one per drive)
  local dev=$1 dir=$2 skip_smart=${3:-0}
  local fails=() warns=() h out
  exec >/dev/null 2>&1
  echo $$ >"$dir/pid"
  K=([dev]="$dev" [phase]=baseline [pct]=0 [errs]=0)
  K[serial]=$(lsblk -dno SERIAL "$dev" | xargs)
  K[model]=$(lsblk -dno MODEL "$dev" | xargs)
  K[size]=$(lsblk -dno SIZE "$dev" | xargs)

  st() { local kv; for kv in "$@"; do K[${kv%%=*}]=${kv#*=}; done; save_state "$dir"; }
  temp_update() {
    local t; t=$(drive_temp "$dev")
    [[ $t =~ ^[0-9]+$ ]] || return 0
    K[temp]=$t
    ((t > ${K[max_temp]:-0})) && K[max_temp]=$t
    return 0
  }

  # baseline
  temp_update; st phase=baseline "left="
  local b_def b_unc a_def a_unc a_pend
  out=$(smartctl -a "$dev" 2>/dev/null)
  read -r b_def b_unc _ < <(smart_counts <<<"$out")
  h=$(smart_health "$dev")
  [[ $h == PASSED || $h == OK ]] || fails+=("SMART health at start was ${h:-unknown}")

  # 1. SMART long test
  if [[ $skip_smart == 1 ]]; then
    K[smart_result]=Skipped
  else
    local prev exp start el rem pct head
    prev=$(selftest_head "$dev")
    exp=$(smart_expected_min "$dev")
    if smartctl -t long "$dev" >/dev/null 2>&1; then
      start=$(date +%s)
      st phase=smart-long pct=0 "left="
      sleep "$SMART_START_WAIT"
      while selftest_running "$dev"; do
        el=$(($(date +%s) - start))
        rem=$(selftest_remaining_pct "$dev")
        if [[ -n $rem ]]; then
          pct=$((100 - rem))
          ((pct > 0)) && K[left]=$((el * rem / pct)) || K[left]=""
        elif [[ $exp =~ ^[0-9]+$ ]] && ((exp > 0)); then
          pct=$((el * 100 / (exp * 60))); ((pct > 99)) && pct=99
          ((exp * 60 > el)) && K[left]=$((exp * 60 - el)) || K[left]=""
        else
          pct=0; K[left]=""
        fi
        temp_update
        st phase=smart-long "pct=$pct"
        sleep "$SMART_POLL"
      done
      head=$(selftest_head "$dev")
      if [[ -z $head || $head == "$prev" ]]; then
        K[smart_result]=Aborted; fails+=("SMART long test did not complete (aborted or never ran)")
      elif grep -qiE 'abort|interrupt' <<<"$head"; then
        K[smart_result]=Aborted; fails+=("SMART long test was aborted")
      elif grep -qi 'fail' <<<"$head"; then
        K[smart_result]=Failed; fails+=("SMART long test failed: $(tr -s ' ' <<<"$head")")
      elif grep -qi 'completed' <<<"$head"; then
        K[smart_result]=Passed
      else
        K[smart_result]=Unknown; fails+=("SMART long test result unclear: $(tr -s ' ' <<<"$head")")
      fi
    else
      K[smart_result]="Didn't start"; fails+=("SMART long test could not be started")
    fi
  fi

  # 2-3. badblocks write + verify (destructive)
  local size bs bbpid rc=0 nbad=0 idx=0 p=0 lastp=0 els errs=0 i2 p2 e2 r2 ip
  size=$(blockdev --getsize64 "$dev")
  bs=4096
  while ((size / bs > 4294967295)); do bs=$((bs * 2)); done   # badblocks limit: 2^32 blocks (matters >16TB)
  : >"$dir/bb.out"; : >"$dir/bb.bad"
  temp_update; st phase=badblocks-write pct=0 "left="
  badblocks -b "$bs" -c 1024 -wsv -t random -o "$dir/bb.bad" "$dev" >>"$dir/bb.out" 2>&1 &
  bbpid=$!
  while kill -0 "$bbpid" 2>/dev/null; do
    sleep "$BB_POLL"
    i2="" p2=""
    read -r i2 p2 e2 r2 < <(bb_parse "$dir/bb.out") || true
    if [[ -n $p2 ]]; then
      ip=${p2%%.*}
      # phase is sticky: the read pass starts once, and pct drops back to 0 when it does
      if ((i2 > idx)) || { ((idx == 0)) && ((ip + 20 < lastp)); }; then idx=1; fi
      lastp=$ip; p=$p2; els=$e2
      ((r2 > errs)) && errs=$r2
      K[left]=$(awk -v i="$idx" -v p="$p" -v e="$els" 'BEGIN {
        if (p <= 0.05) { print ""; exit }
        r = e * (100 - p) / p; if (i == 0) r += e * 100 / p; printf "%d", r }')
      ((idx == 0)) && K[phase]=badblocks-write || K[phase]=badblocks-verify
      K[pct]=${ip}
      K[errs]=$errs
    fi
    temp_update; save_state "$dir"
    if (($(stat -c %s "$dir/bb.out" 2>/dev/null || echo 0) > BB_TRIM)); then : >"$dir/bb.out"; fi
  done
  wait "$bbpid"; rc=$?
  nbad=$(grep -c '[0-9]' "$dir/bb.bad" 2>/dev/null) || nbad=0
  if ((rc != 0)); then
    K[bb_result]="Error ($rc)"; fails+=("badblocks stopped with exit code $rc")
  else
    K[bb_result]="$nbad bad"
  fi
  ((nbad == 0)) || fails+=("badblocks found $nbad bad block(s)")
  ((errs == 0 || nbad > 0)) || fails+=("badblocks reported $errs read/write/compare error(s)")
  rm -f "$dir/bb.out" "$dir/bb.bad"

  # 4. final SMART + comparison
  temp_update; st phase=final pct=100 "left="
  out=$(smartctl -a "$dev" 2>/dev/null)
  read -r a_def a_unc a_pend < <(smart_counts <<<"$out")
  h=$(smart_health "$dev")
  [[ $h == PASSED || $h == OK ]] || fails+=("SMART health at end was ${h:-unknown}")

  K[defects]="$b_def $ARROW $a_def"
  K[uncorrected]="$b_unc $ARROW $a_unc"
  if [[ $a_def =~ ^[0-9]+$ && $b_def =~ ^[0-9]+$ ]]; then
    if ((a_def > b_def)); then fails+=("defects rose $b_def $ARROW $a_def")
    elif ((a_def > 0)); then warns+=("$a_def defect(s) were already present before the test; none were added during it"); fi
  fi
  if [[ $a_unc =~ ^[0-9]+$ && $b_unc =~ ^[0-9]+$ ]]; then
    if ((a_unc > b_unc)); then fails+=("uncorrected errors rose $b_unc $ARROW $a_unc")
    elif ((a_unc > 0)); then warns+=("$a_unc uncorrected error(s) were already logged before the test; none were added during it"); fi
  fi
  [[ $a_pend =~ ^[0-9]+$ ]] && ((a_pend > 0)) && fails+=("$a_pend sector(s) pending reallocation")

  local result=PASS
  ((${#warns[@]})) && result=WARN
  ((${#fails[@]})) && result=FAIL
  temp_update
  st phase=done pct=100 "left=" "result=$result" "finished=$(date +%s)" \
    "details=$(join_by "; " "${fails[@]}" "${warns[@]}")"
}

# ------------------------------------------------------------------ display

step_label() {
  case $1 in
    queued) echo "Queued" ;;
    baseline | smart-long) echo "1/4 SMART long test" ;;
    badblocks-write) echo "2/4 badblocks write" ;;
    badblocks-verify) echo "3/4 badblocks verify" ;;
    final) echo "4/4 final SMART" ;;
    *) echo "$1" ;;
  esac
}

fmt_temp() {
  local t=${1:-}
  [[ $t =~ ^[0-9]+$ ]] || { echo "$DASH"; return; }
  if ((t >= TEMP_WARN)); then echo "${t}${DEG}!"; else echo "${t}${DEG}"; fi
}

clear_screen() { [[ -t 1 ]] && printf '\033[H\033[2J'; }

render_live() {
  local run=$1 d started now rows=() step left
  started=$(cat "$run/started" 2>/dev/null || date +%s); now=$(date +%s)
  clear_screen
  echo "${C_BOLD}hdd-burninator${C_OFF}   running $(fmt_dur $((now - started)))   updated $(date '+%F %H:%M')"
  echo
  rows+=("Drive|Serial|Step|Progress|Temp|Time left|Errors")
  while read -r d; do
    read_state "$d" || continue
    step=$(step_label "${S[phase]:-}")
    left=$DASH
    [[ ${S[left]:-} =~ ^[0-9]+$ ]] && left="~$(fmt_dur "${S[left]}")"
    if [[ ${S[phase]:-} == "done" ]]; then
      step="Done: ${S[result]:-?}"; left=$DASH
    elif ! worker_alive "$d"; then
      step="STOPPED"; left=$DASH
    fi
    rows+=("$(basename "$d")|${S[serial]:-?}|$step|$(bar "${S[pct]:-0}")|$(fmt_temp "${S[temp]:-}")|$left|${S[errs]:-0}")
  done < <(drive_dirs "$run")
  draw_table 2 "${rows[@]}"
  echo "! = at or above ${TEMP_WARN}${DEG}, add airflow.   Ctrl-C closes this view; the tests keep running."
  echo "Reopen with: sudo bash $SELF --status"
}

render_final() {
  local run=$1 d name started finished=0 rows=() details=() res total=0 pass=0 warn=0 fail=0 inc=0
  started=$(cat "$run/started" 2>/dev/null || date +%s)
  rows+=("Drive|Model|Serial|Size|SMART long|badblocks|Defects|Uncorrected|Max temp|Result")
  while read -r d; do
    name=$(basename "$d"); total=$((total + 1))
    read_state "$d" || continue
    res=${S[result]:-INCOMPLETE}
    [[ ${S[phase]:-} == "done" ]] || res=INCOMPLETE
    case $res in PASS) pass=$((pass + 1)) ;; WARN) warn=$((warn + 1)) ;; INCOMPLETE) inc=$((inc + 1)) ;; *) fail=$((fail + 1)) ;; esac
    [[ ${S[finished]:-0} -gt $finished ]] && finished=${S[finished]}
    rows+=("$name|${S[model]:-?}|${S[serial]:-?}|${S[size]:-?}|${S[smart_result]:-$DASH}|${S[bb_result]:-$DASH}|${S[defects]:-$DASH}|${S[uncorrected]:-$DASH}|$(fmt_temp "${S[max_temp]:-}")|$res")
    if [[ $res == INCOMPLETE ]]; then
      details+=("$name|INCOMPLETE|stopped during $(step_label "${S[phase]:-?}") (power loss, reboot or the test was killed)")
    elif [[ -n ${S[details]:-} ]]; then
      details+=("$name|$res|${S[details]}")
    fi
  done < <(drive_dirs "$run")
  ((finished > 0)) || finished=$(date +%s)

  clear_screen
  echo "${C_BOLD}hdd-burninator${C_OFF}   finished in $(fmt_dur $((finished - started)))"
  echo
  draw_table 9 "${rows[@]}"
  if ((${#details[@]})); then
    echo
    echo "Details"
    local line n r t
    for line in "${details[@]}"; do
      IFS='|' read -r n r t <<<"$line"
      printf '  %-6s %s  %s\n' "$n" "$(colorize "$(printf '%-10s' "$r")" "$r")" "$t"
    done
  fi
  echo
  local summary="$total drive(s) tested: $pass passed"
  ((warn)) && summary+=", $warn passed with warnings"
  ((fail)) && summary+=", $fail failed"
  ((inc)) && summary+=", $inc incomplete"
  echo "${C_BOLD}${summary}.${C_OFF}"
}

all_done() {
  local d
  while read -r d; do
    read_state "$d" || return 1
    [[ ${S[phase]:-} == "done" ]] || ! worker_alive "$d" || return 1
  done < <(drive_dirs "$1")
  return 0
}

cleanup_run() {
  local run=$1
  rm -rf "$run"
  [[ $(readlink -f "$RUN_ROOT/current" 2>/dev/null) == "$run" || ! -e $RUN_ROOT/current ]] && rm -f "$RUN_ROOT/current"
  rmdir "$RUN_ROOT" 2>/dev/null || true
}

watch_run() {
  local run=$1
  trap 'echo; echo "View closed - the tests are still running in the background."; echo "Reopen with: sudo bash $SELF --status"; exit 0' INT
  while :; do
    render_live "$run"
    all_done "$run" && break
    sleep "$REFRESH"
  done
  trap - INT
  render_final "$run"
  cleanup_run "$run"
}

# ---------------------------------------------------------- drive selection

resolve_dev() {
  local d=$1
  [[ $d == /dev/* ]] || d=/dev/$d
  d=$(readlink -f "$d")
  [[ -b $d ]] || die "$1 is not a block device"
  [[ $(lsblk -dno TYPE "$d") == disk ]] || die "$1 is not a whole disk (use sda, not sda1)"
  echo "$d"
}

pool_disks() {  # whole disks used by any imported ZFS pool (including boot-pool)
  local p pk
  zpool status -P 2>/dev/null | awk '$1 ~ "^/dev/" {print $1}' | while read -r p; do
    p=$(readlink -f "$p")
    pk=$(lsblk -no PKNAME "$p" 2>/dev/null | head -1)
    if [[ -n $pk ]]; then echo "/dev/$pk"; else echo "$p"; fi
  done | sort -u
}

auto_drives() {  # rotational whole disks, not USB
  lsblk -dnpo NAME,ROTA,TYPE,TRAN | awk '$2 == 1 && $3 == "disk" && $4 != "usb" {print $1}'
}

# ---------------------------------------------------------------------- main

main() {
  local mode=run skip_smart=0 drives=() d
  while (($#)); do
    case $1 in
      -h | --help) usage; exit 0 ;;
      --worker) shift; setup_terminal; worker "$@"; exit $? ;;
      --status) mode=status ;;
      --skip-smart) skip_smart=1 ;;
      --refresh) [[ ${2:-} =~ ^[0-9]+$ ]] || die "--refresh needs a number of seconds"; REFRESH=$2; shift ;;
      -*) die "unknown option: $1 (see --help)" ;;
      *) drives+=("$1") ;;
    esac
    shift
  done

  ((EUID == 0)) || die "run as root (e.g. sudo bash $0 ...)"
  setup_terminal

  if [[ $mode == status ]]; then
    local run
    run=$(readlink -f "$RUN_ROOT/current" 2>/dev/null) || true
    [[ -n $run && -d $run ]] || die "no burn-in is running (and no unviewed results are waiting)"
    watch_run "$run"
    exit 0
  fi

  local c
  for c in smartctl badblocks lsblk blockdev setsid zpool stat; do
    command -v "$c" >/dev/null || die "required command not found: $c"
  done
  if [[ -e $RUN_ROOT/current ]] && worker_alive_any "$(readlink -f "$RUN_ROOT/current")"; then
    die "a burn-in is already running - view it with: sudo bash $SELF --status"
  fi

  # Resolve the drive list
  local devs=()
  if ((${#drives[@]})); then
    for d in "${drives[@]}"; do devs+=("$(resolve_dev "$d")") || exit 1; done
  else
    mapfile -t devs < <(auto_drives)
    ((${#devs[@]})) || die "no spinning drives found - pass drive names explicitly"
  fi
  mapfile -t devs < <(printf '%s\n' "${devs[@]}" | sort -u)

  # Safety checks
  local in_pools
  in_pools=$(pool_disks)
  for d in "${devs[@]}"; do
    grep -qxF "$d" <<<"$in_pools" &&
      die "$d belongs to an imported ZFS pool (possibly the boot pool). Export or destroy that pool first, or leave the drive out."
    [[ -n $(lsblk -nro MOUNTPOINT "$d" | tr -d '[:space:]') ]] && die "$d (or a partition on it) is mounted"
    grep -qE "[[:space:]]$d\$" <<<"$(pgrep -af '^badblocks')" && die "badblocks is already running on $d"
  done

  # Show what will be erased
  local rows=("Drive|Size|Model|Serial|Notes") notes
  for d in "${devs[@]}"; do
    notes=""
    grep -q part <<<"$(lsblk -nro TYPE "$d")" && notes="has partitions"
    grep -q zfs_member <<<"$(lsblk -nro FSTYPE "$d")" && notes="has old ZFS data"
    [[ $(lsblk -dno ROTA "$d") == 1 ]] || notes="${notes:+$notes, }not a spinning drive"
    rows+=("$(basename "$d")|$(lsblk -dno SIZE "$d" | xargs)|$(lsblk -dno MODEL "$d" | xargs)|$(lsblk -dno SERIAL "$d" | xargs)|$notes")
  done
  echo
  echo "${C_BOLD}hdd-burninator${C_OFF}"
  echo
  echo "Drives selected for burn-in:"
  echo
  draw_table -1 "${rows[@]}"
  echo
  echo "Each drive: SMART long test $ARROW badblocks write $ARROW badblocks verify $ARROW final SMART."
  echo "Roughly 2-3 days for 12-18TB drives. All drives run in parallel."
  echo
  echo "${C_BOLD}${C_RED}!!! EVERYTHING ON THESE DRIVES WILL BE PERMANENTLY ERASED !!!${C_OFF}"
  local answer
  read -r -p "Type ERASE to continue: " answer
  [[ $answer == ERASE ]] || { echo "Cancelled."; exit 1; }

  # Launch (state lives in /run: memory only, removed when results are shown)
  local run name
  run="$RUN_ROOT/run-$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$run" || die "cannot create $run"
  date +%s >"$run/started"
  ln -sfn "$run" "$RUN_ROOT/current"
  for d in "${devs[@]}"; do
    name=$(basename "$d")
    mkdir -p "$run/$name"
    printf 'dev=%s\nserial=%s\nphase=queued\npct=0\n' "$d" "$(lsblk -dno SERIAL "$d" | xargs)" >"$run/$name/state"
    setsid nohup bash "$SELF" --worker "$d" "$run/$name" "$skip_smart" >/dev/null 2>&1 </dev/null &
    echo $! >"$run/$name/pid"
  done
  sleep 2
  watch_run "$run"
}

worker_alive_any() {
  local d
  while read -r d; do worker_alive "$d" && return 0; done < <(drive_dirs "$1")
  return 1
}

if [[ -z ${BASH_SOURCE[0]:-} || ! -f $SELF ]]; then
  echo "ERROR: download the script to a file and run it with: sudo bash hdd-burninator.sh (piping into bash is not supported)" >&2
  exit 1
elif [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
