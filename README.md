# hdd-burninator

Burn-in test for new or refurbished hard drives on **TrueNAS (Community Edition / SCALE)**, or any Linux box with `smartctl` and `badblocks`. It tests every drive in parallel and gives a live progress display and a pass/fail report at the end.

Use it on new drives **before** you put data on them, while you can still return any that are bad.

> ⚠️ **This erases every drive it tests.** Don't run it on drives with data you want to keep. It refuses to touch drives in an imported ZFS pool (including the boot drive) and asks you to type `ERASE` before starting.

## What it does

For each drive, all at the same time:

1. **Baseline SMART snapshot:** saves the drive's health and error counters.
2. **SMART extended (long) self-test:** the drive's own full surface scan.
3. **badblocks write and verify:** writes random data to every block, then reads it all back and compares (one pass).
4. **Final SMART snapshot:** compares error counters against the baseline.

Works with **SAS and SATA** drives. Their SMART output differs, and the script handles both.

A drive **FAILS** if:
- the SMART long test fails or is aborted
- badblocks finds bad blocks or read/write/compare errors
- SMART health isn't `PASSED`/`OK`
- any error counter goes up during the test: SAS grown defect list or uncorrected errors, SATA reallocated, pending or offline-uncorrectable sectors

A drive gets a **WARN** if a counter was already nonzero before the test but didn't change, which is common on refurbished drives.

## Usage

Download it (don't pipe it into bash):

```bash
curl -LO https://raw.githubusercontent.com/OWNER/REPO/main/hdd-burninator.sh
```

Run it on every spinning drive. SSDs, NVMe, USB sticks and the boot drive are skipped automatically:

```bash
sudo bash hdd-burninator.sh
```

Or on specific drives only:

```bash
sudo bash hdd-burninator.sh sda sdb sdc sdd
```

Find drive names with `lsblk -o NAME,SIZE,MODEL,SERIAL,ROTA`.

### Progress display

The display refreshes every 30 seconds and shows each drive's step, progress, temperature and estimated time left.

**The tests run in the background.** Pressing Ctrl-C, closing the browser shell or dropping SSH only closes the display. Reopen it any time with:

```bash
sudo bash hdd-burninator.sh --status
```

Temperatures at or above 45°C are flagged with `!`. Add airflow if you see them, especially on a test bench.

### Options

| Option | Meaning |
|---|---|
| `--status [DIR]` | Reopen the progress display (default: latest run) |
| `--skip-smart` | Skip the SMART long test and go straight to badblocks |
| `--refresh SEC` | Display refresh interval (default 30) |
| `-h`, `--help` | Help |

## How long it takes

Roughly **2–3 days** for 12–18TB drives: about a day for the SMART long test, plus 1–1½ days for the badblocks write and verify pass. All drives run in parallel, so four drives take about as long as one.

## Output

Each run gets a folder under `/root/burninator/<date_time>/`, and `/root/burninator/latest` points at the newest one:

```
summary.txt                  final pass/fail report
sda/worker.log               timeline of what happened
sda/smart_before.txt         SMART at start (smart_before_full.txt = smartctl -x)
sda/smart_after.txt          SMART at end
sda/badblocks.log            badblocks output
sda/badblocks_bad.txt        list of bad blocks (empty = good)
```

## Notes

- Drives larger than 16TB automatically use an 8192-byte block size, since badblocks can't address them with 4K blocks.
- Return any drive that FAILS within the seller's return window.
- Requires `smartctl`, `badblocks`, `lsblk`, `blockdev`, `setsid` and `zpool`, all included in TrueNAS.
