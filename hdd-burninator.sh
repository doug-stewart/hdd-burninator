#!/usr/bin/env bash
#
# hdd-burninator.sh - parallel burn-in for new hard drives on TrueNAS (Community Edition / SCALE)
#
# For every drive, in parallel:
#   1. Baseline SMART snapshot
#   2. SMART extended (long) self-test
#   3. badblocks destructive write + read-back test (random pattern, one pass)
#        *** THIS ERASES EVERYTHING ON THE DRIVE ***
#   4. Final SMART snapshot, compared against the baseline
#
# The tests run as background processes, so closing the browser shell or SSH
# session does NOT stop them. Re-open the progress display at any time with
# --status.
#
# Usage:
#   sudo bash hdd-burninator.sh              # every spinning disk (skips SSDs, NVMe, USB and the boot drive)
#   sudo bash hdd-burninator.sh sda sdb      # only the drives you name (sda, /dev/sda or /dev/disk/by-id/... all work)
#   sudo bash hdd-burninator.sh --status     # re-open the progress display for the latest run
#
# Options:
#   --status [DIR]    Show progress of a run (default: the latest run)
#   --skip-smart      Skip the SMART long test and go straight to badblocks
#   --refresh SEC     How often the progress display refreshes (default: 30)
#   -h, --help        Show this help
#
# Logs and reports are written to /root/burninator/<date_time>/ (one folder per drive),
# with /root/burninator/latest pointing at the most recent run.

set -uo pipefail

BASE_DIR="${burninator_DIR:-/root/burninator}"
SMART_POLL=${burninator_SMART_POLL:-300}        # seconds between SMART long-test progress checks
SMART_START_WAIT=${burninator_SMART_WAIT:-60}   # pause after starting the SMART test before first check
BB_POLL=${burninator_BB_POLL:-60}               # seconds between badblocks progress checks
REFRESH=${burninator_REFRESH:-30}               # seconds between progress display refreshes
TEMP_WARN=${burninator_TEMP_WARN:-45}           # flag drives at or above this temperature (C)
SELF="$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null)"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date '+%F %T')] $*"; }

usage() { sed -n '2,/^$/p' "$SELF" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------- formatting

fmt_dur() {  # seconds -> "3h 05m" / "1d 4h"
  local s=${1:-0} h m
  [[ $s =~ ^[0-9]+$ ]] || { echo "?"; return; }
  h=$((s / 3600)); m=$(((s % 3600) / 60))
  if ((h >= 24)); then printf '%dd %dh' $((h / 24)) $((h % 24))
  else printf '%dh %02dm' "$h" "$m"; fi
}

hms_to_s() {  # "1:23:45" or "23:45" -> seconds
  local a b c
  IFS=: read -r a b c <<<"$1"
  if [[ -n ${c:-} ]]; then echo $((10#$a * 3600 + 10#$b * 60 + 10#$c))
  else echo $((10#${a:-0} * 60 + 10#${b:-0})); fi
}

squeeze() { tr -s ' \t' ' ' <<<"$1"; }

join_by() {  # join_by " | " a b c
  local sep=$1 out="" x; shift
  for x in "$@"; do [[ -z $out ]] && out=$x || out="$out$sep$x"; done
  printf '%s' "$out"
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

smart_metrics() {  # parse a saved `smartctl -a` file -> key=value counters
  awk '
    /Elements in grown defect list/            { print "grown_defects=" $NF }
    /^(read|write|verify):/                    { k = $1; sub(/:$/, "", k); print "uncorrected_" k "=" $NF }
    $2 == "Reallocated_Sector_Ct"              { print "reallocated=" $10 }
    $2 == "Current_Pending_Sector"             { print "pending=" $10 }
    $2 == "Offline_Uncorrectable"              { print "offline_uncorrectable=" $10 }
    $2 == "Reported_Uncorrect"                 { print "reported_uncorrect=" $10 }
  ' "$1"
}

# ----------------------------------------------------------------- badblocks

bb_status() {  # badblocks log -> "phase_idx pct elapsed_s errors" (empty until first update)
  local log=$1 phase line idx=0
  phase=$(grep -aoE 'Testing with random pattern|Reading and comparing' "$log" 2>/dev/null | tail -1)
  [[ $phase == Reading* ]] && idx=1
  line=$(tail -c 4096 "$log" 2>/dev/null | tr '\b\r' '\n\n' | grep -aE '% done' | tail -1)
  if [[ $line =~ ([0-9]+\.[0-9]+)%\ done,\ ([0-9:]+)\ elapsed\.\ \(([0-9]+)/([0-9]+)/([0-9]+)\ errors\) ]]; then
    echo "$idx ${BASH_REMATCH[1]} $(hms_to_s "${BASH_REMATCH[2]}") $((BASH_REMATCH[3] + BASH_REMATCH[4] + BASH_REMATCH[5]))"
  fi
}

# ---------------------------------------------------------------- state files

write_state() {  # write_state DIR key=value ...
  local dir=$1 kv; shift
  { for kv in "$@"; do printf '%s\n' "$kv"; done; echo "updated=$(date +%s)"; } >"$dir/state.tmp" &&
    mv -f "$dir/state.tmp" "$dir/state"
}

declare -gA S
read_state() {  # read_state DIR -> fills global assoc array S
  S=()
  local k v
  [[ -f $1/state ]] || return 1
  while IFS='=' read -r k v; do [[ -n $k ]] && S[$k]=$v; done <"$1/state"
}

worker_alive() { local p; p=$(cat "$1/pid" 2>/dev/null) && [[ -n $p ]] && kill -0 "$p" 2>/dev/null; }

# -------------------------------------------------------------------- worker

worker() {  # worker DEV DIR SKIP_SMART  (runs detached, one per drive)
  local dev=$1 dir=$2 skip_smart=${3:-0}
  local serial model h fails=() warns=()
  exec >>"$dir/worker.log" 2>&1
  echo $$ >"$dir/pid"
  serial=$(lsblk -dno SERIAL "$dev" | xargs)
  model=$(lsblk -dno MODEL "$dev" | xargs)
  st() { write_state "$dir" "dev=$dev" "serial=$serial" "model=$model" "$@"; }
  log "worker started for $dev ($model, serial $serial)"

  # 1. baseline
  st phase=baseline pct=0 "detail=Saving baseline SMART data"
  smartctl -a "$dev" >"$dir/smart_before.txt" 2>&1
  smartctl -x "$dev" >"$dir/smart_before_full.txt" 2>&1
  h=$(smart_health "$dev")
  [[ $h == PASSED || $h == OK ]] || fails+=("SMART health at start: ${h:-unknown}")

  # 2. SMART long test
  if [[ $skip_smart != 1 ]]; then
    local prev exp start el rem pct detail t head
    prev=$(selftest_head "$dev")
    exp=$(smart_expected_min "$dev")
    log "starting SMART long test (drive estimate: ${exp:-unknown} min)"
    if smartctl -t long "$dev" >"$dir/smart_test_start.txt" 2>&1; then
      start=$(date +%s)
      st phase=smart-long pct=0 "detail=starting"
      sleep "$SMART_START_WAIT"
      while selftest_running "$dev"; do
        el=$(($(date +%s) - start))
        rem=$(selftest_remaining_pct "$dev")
        if [[ -n $rem ]]; then
          pct=$((100 - rem)); detail="$rem% of test remaining"
        elif [[ $exp =~ ^[0-9]+$ ]] && ((exp > 0)); then
          pct=$((el * 100 / (exp * 60))); ((pct > 99)) && pct=99
          if ((exp * 60 > el)); then detail="~$(fmt_dur $((exp * 60 - el))) left (drive estimate)"
          else detail="running $(fmt_dur "$el"), past drive estimate"; fi
        else
          pct=""; detail="running $(fmt_dur "$el")"
        fi
        t=$(drive_temp "$dev")
        st phase=smart-long "pct=$pct" "temp=$t" "detail=$detail"
        sleep "$SMART_POLL"
      done
      head=$(selftest_head "$dev")
      log "self-test log #1: $head"
      if [[ -z $head || $head == "$prev" ]]; then
        fails+=("SMART long test left no new log entry (aborted or never ran)")
      elif grep -qiE 'fail|abort|interrupt' <<<"$head"; then
        fails+=("SMART long test: $(squeeze "$head")")
      elif ! grep -qi 'completed' <<<"$head"; then
        fails+=("SMART long test, unexpected result: $(squeeze "$head")")
      fi
    else
      fails+=("could not start SMART long test (see smart_test_start.txt)")
    fi
  fi

  # 3. badblocks (destructive)
  local size bs bbpid rc idx p els errs=0 overall left nbad=0 phase_name
  size=$(blockdev --getsize64 "$dev")
  bs=4096
  while ((size / bs > 4294967295)); do bs=$((bs * 2)); done   # badblocks limit: 2^32 blocks (matters >16TB)
  : >"$dir/badblocks_bad.txt"
  log "starting badblocks (block size $bs)"
  st phase=badblocks-write pct=0 "temp=$(drive_temp "$dev")" "detail=starting (block size $bs)"
  badblocks -b "$bs" -c 1024 -wsv -t random -o "$dir/badblocks_bad.txt" "$dev" >"$dir/badblocks.log" 2>&1 &
  bbpid=$!
  while kill -0 "$bbpid" 2>/dev/null; do
    sleep "$BB_POLL"
    read -r idx p els errs < <(bb_status "$dir/badblocks.log") || true
    [[ -n ${p:-} ]] || continue
    overall=$(awk -v i="$idx" -v p="$p" 'BEGIN { printf "%d", (i * 100 + p) / 2 }')
    left=$(awk -v i="$idx" -v p="$p" -v e="$els" 'BEGIN {
      if (p <= 0.05) { print ""; exit }
      r = e * (100 - p) / p; if (i == 0) r += e * 100 / p; printf "%d", r }')
    ((idx == 0)) && phase_name=badblocks-write || phase_name=badblocks-verify
    detail="pass $((idx + 1))/2 at ${p}%"
    [[ -n $left ]] && detail+=", ~$(fmt_dur "$left") left (est.)"
    ((errs > 0)) && detail+=", $errs ERRORS"
    st "phase=$phase_name" "pct=$overall" "temp=$(drive_temp "$dev")" "detail=$detail"
  done
  wait "$bbpid"; rc=$?
  nbad=$(grep -c '[0-9]' "$dir/badblocks_bad.txt" 2>/dev/null) || nbad=0
  log "badblocks exited with $rc, $nbad bad blocks"
  ((rc == 0)) || fails+=("badblocks exited with code $rc (see badblocks.log)")
  ((nbad == 0)) || fails+=("badblocks found $nbad bad blocks")
  ((${errs:-0} == 0)) || ((nbad > 0)) || fails+=("badblocks reported ${errs} read/write/compare errors")

  # 4. final SMART + comparison
  st phase=final pct=100 "temp=$(drive_temp "$dev")" "detail=Final SMART check"
  smartctl -a "$dev" >"$dir/smart_after.txt" 2>&1
  smartctl -x "$dev" >"$dir/smart_after_full.txt" 2>&1
  h=$(smart_health "$dev")
  [[ $h == PASSED || $h == OK ]] || fails+=("SMART health at end: ${h:-unknown}")

  local -A b=() a=()
  local k v bv av msum=()
  while IFS='=' read -r k v; do b[$k]=$v; done < <(smart_metrics "$dir/smart_before.txt")
  while IFS='=' read -r k v; do a[$k]=$v; done < <(smart_metrics "$dir/smart_after.txt")
  for k in $(printf '%s\n' "${!a[@]}" | sort); do
    av=${a[$k]}; bv=${b[$k]:-0}
    [[ $av =~ ^[0-9]+$ && $bv =~ ^[0-9]+$ ]] || continue
    msum+=("$k $bv->$av")
    if ((av > bv)); then
      fails+=("$k increased during test ($bv -> $av)")
    elif ((av > 0)); then
      case $k in
        pending | offline_uncorrectable) fails+=("$k is $av") ;;
        *) warns+=("$k is $av (unchanged during test)") ;;
      esac
    fi
  done

  local result=PASS reasons
  ((${#warns[@]})) && result=WARN
  ((${#fails[@]})) && result=FAIL
  reasons=$(join_by " | " "${fails[@]}" "${warns[@]}")
  st phase=done pct=100 "temp=$(drive_temp "$dev")" "result=$result" \
    "detail=${reasons:-all checks passed}" "metrics=$(join_by ", " "${msum[@]}")"
  log "finished: $result ${reasons}"
}

# ----------------------------------------------------------------- dashboard

phase_label() {
  case $1 in
    queued) echo "Queued" ;;
    baseline) echo "Baseline SMART" ;;
    smart-long) echo "SMART long test" ;;
    badblocks-write) echo "badblocks write" ;;
    badblocks-verify) echo "badblocks verify" ;;
    final) echo "Final SMART" ;;
    done) echo "Done" ;;
    *) echo "$1" ;;
  esac
}

drive_dirs() { find "$1" -mindepth 1 -maxdepth 1 -type d | sort; }

render() {
  local run=$1 d name status prog temp detail
  printf '\033[H\033[2J'
  echo "HDD burn-in  |  $run  |  $(date '+%F %T')"
  echo "Steps per drive: baseline SMART -> SMART long test -> badblocks write -> badblocks verify -> final SMART"
  echo
  printf '%-8s %-22s %-18s %5s %6s  %s\n' DRIVE SERIAL STEP PROG TEMP DETAIL
  printf '%-8s %-22s %-18s %5s %6s  %s\n' ------ ------ ---- ---- ---- ------
  while read -r d; do
    name=$(basename "$d")
    read_state "$d" || { printf '%-8s %s\n' "$name" "(no state yet)"; continue; }
    status=$(phase_label "${S[phase]:-?}")
    [[ ${S[phase]:-} == "done" ]] && status="DONE: ${S[result]:-?}"
    detail=${S[detail]:-}
    if [[ ${S[phase]:-} != "done" ]] && ! worker_alive "$d"; then
      status="STOPPED"; detail="worker exited unexpectedly - see $d/worker.log"
    fi
    prog=${S[pct]:+${S[pct]}%}
    temp=${S[temp]:+${S[temp]}C}
    [[ ${S[temp]:-} =~ ^[0-9]+$ ]] && ((S[temp] >= TEMP_WARN)) && temp+="!"
    printf '%-8s %-22s %-18s %5s %6s  %s\n' "$name" "${S[serial]:-?}" "$status" "${prog:--}" "${temp:--}" "$detail"
  done < <(drive_dirs "$run")
  echo
  echo "Temperatures marked ! are at or above ${TEMP_WARN}C - add airflow."
  echo "Ctrl-C closes this display only; the tests keep running. Reopen with: sudo bash $SELF --status"
}

all_done() {
  local d
  while read -r d; do
    read_state "$d" || return 1
    [[ ${S[phase]:-} == "done" ]] || ! worker_alive "$d" || return 1
  done < <(drive_dirs "$1")
  return 0
}

final_report() {
  local run=$1 d name res total=0 bad=0 warn=0
  {
    echo "HDD burn-in summary"
    echo "Run: $run"
    echo "Finished: $(date '+%F %T')"
    echo
    while read -r d; do
      name=$(basename "$d"); total=$((total + 1))
      read_state "$d"
      res=${S[result]:-INCOMPLETE}
      [[ ${S[phase]:-} != "done" ]] && res=INCOMPLETE
      case $res in PASS) ;; WARN) warn=$((warn + 1)) ;; *) bad=$((bad + 1)) ;; esac
      echo "[$res] $name  ${S[model]:-?}  serial ${S[serial]:-?}"
      echo "    ${S[detail]:-}"
      [[ -n ${S[metrics]:-} ]] && echo "    SMART counters (before->after): ${S[metrics]}"
      echo "    Logs: $d/"
      echo
    done < <(drive_dirs "$run")
    if ((bad > 0)); then
      echo "RESULT: $bad of $total drive(s) FAILED or did not finish. Return failed drives within the seller's return window."
    elif ((warn > 0)); then
      echo "RESULT: no failures, but $warn drive(s) have warnings worth reading above (e.g. pre-existing grown defects)."
    else
      echo "RESULT: all $total drive(s) PASSED."
    fi
  } | tee "$run/summary.txt"
  echo
  echo "Summary saved to $run/summary.txt"
}

dashboard() {
  local run=$1
  trap 'echo; echo "Display closed - the tests are still running."; echo "Reopen with: sudo bash $SELF --status"; exit 0' INT
  while :; do
    render "$run"
    all_done "$run" && break
    sleep "$REFRESH"
  done
  echo
  final_report "$run"
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
  local p
  zpool status -P 2>/dev/null | awk '$1 ~ "^/dev/" {print $1}' | while read -r p; do
    p=$(readlink -f "$p")
    local pk; pk=$(lsblk -no PKNAME "$p" 2>/dev/null | head -1)
    if [[ -n $pk ]]; then echo "/dev/$pk"; else echo "$p"; fi
  done | sort -u
}

auto_drives() {  # rotational, whole disks, not USB
  lsblk -dnpo NAME,ROTA,TYPE,TRAN | awk '$2 == 1 && $3 == "disk" && $4 != "usb" {print $1}'
}

# ---------------------------------------------------------------------- main

main() {
  local status_dir="" mode=run skip_smart=0 drives=() d
  while (($#)); do
    case $1 in
      -h | --help) usage; exit 0 ;;
      --worker) shift; worker "$@"; exit $? ;;
      --status) mode=status; if [[ -n ${2:-} && ${2:-} != -* ]]; then status_dir=$2; shift; fi ;;
      --skip-smart) skip_smart=1 ;;
      --refresh) [[ ${2:-} =~ ^[0-9]+$ ]] || die "--refresh needs a number of seconds"; REFRESH=$2; shift ;;
      -*) die "unknown option: $1 (see --help)" ;;
      *) drives+=("$1") ;;
    esac
    shift
  done

  [[ -f $SELF ]] || die "download the script to a file and run it (piping from curl into bash is not supported)"
  ((EUID == 0)) || die "run as root (e.g. sudo bash $0 ...)"

  if [[ $mode == status ]]; then
    status_dir=$(readlink -f "${status_dir:-$BASE_DIR/latest}") || true
    [[ -d $status_dir ]] || die "no burn-in run found at ${status_dir:-$BASE_DIR/latest}"
    dashboard "$status_dir"
    exit 0
  fi

  local c
  for c in smartctl badblocks lsblk blockdev setsid zpool; do
    command -v "$c" >/dev/null || die "required command not found: $c"
  done

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
      die "$d belongs to an imported ZFS pool (possibly the boot pool). Export/destroy that pool first, or leave the drive out."
    [[ -n $(lsblk -nro MOUNTPOINT "$d" | tr -d '[:space:]') ]] && die "$d (or a partition on it) is mounted"
    grep -qE "[[:space:]]$d\$" <<<"$(pgrep -af '^badblocks')" && die "badblocks is already running on $d"
  done

  # Show what will be erased
  echo
  echo "Drives selected for burn-in:"
  echo
  printf '  %-10s %8s  %-28s %-22s %s\n' DEVICE SIZE MODEL SERIAL NOTES
  for d in "${devs[@]}"; do
    local size model serial notes=""
    size=$(lsblk -dno SIZE "$d" | xargs); model=$(lsblk -dno MODEL "$d" | xargs); serial=$(lsblk -dno SERIAL "$d" | xargs)
    grep -q part <<<"$(lsblk -nro TYPE "$d")" && notes="has partitions"
    grep -q zfs_member <<<"$(lsblk -nro FSTYPE "$d")" && notes="has old ZFS data"
    [[ $(lsblk -dno ROTA "$d") == 1 ]] || notes="${notes:+$notes, }NOT a spinning drive"
    printf '  %-10s %8s  %-28s %-22s %s\n' "$d" "$size" "$model" "$serial" "$notes"
  done
  echo
  echo "  Per drive: SMART long test, then a destructive badblocks write/verify pass."
  echo "  Expect roughly 2-3 days for 12-18TB drives. All drives run in parallel."
  echo
  echo "  !!! EVERYTHING ON THESE DRIVES WILL BE PERMANENTLY ERASED !!!"
  echo
  local answer
  read -r -p "  Type ERASE to continue: " answer
  [[ $answer == ERASE ]] || { echo "Cancelled."; exit 1; }

  # Launch
  local run name
  run="$BASE_DIR/$(date '+%Y-%m-%d_%H%M%S')"
  mkdir -p "$run" || die "cannot create $run"
  ln -sfn "$run" "$BASE_DIR/latest"
  printf '%s\n' "${devs[@]}" >"$run/drives.txt"
  for d in "${devs[@]}"; do
    name=$(basename "$d")
    mkdir -p "$run/$name"
    write_state "$run/$name" "dev=$d" "serial=$(lsblk -dno SERIAL "$d" | xargs)" phase=queued "detail=starting"
    setsid nohup bash "$SELF" --worker "$d" "$run/$name" "$skip_smart" >/dev/null 2>&1 </dev/null &
    echo $! >"$run/$name/pid"
  done
  sleep 2
  dashboard "$run"
}

if [[ -z ${BASH_SOURCE[0]:-} || ! -f $SELF ]]; then
  echo "ERROR: download the script to a file and run it with: sudo bash hdd-burninator.sh (piping into bash is not supported)" >&2
  exit 1
elif [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
