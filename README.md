# hdd-burninator

Burn-in test for new or refurbished hard drives on **TrueNAS (Community Edition / SCALE)**, or any Linux box with `smartctl` and `badblocks`. It tests every drive in parallel, shows live progress, and prints a pass/fail table in the console when it's done.

> ⚠️ **This erases every drive it tests.** It refuses to touch drives in an imported ZFS pool (including the boot drive) and asks you to type `ERASE` before it starts.

## What it does

For each drive, all at the same time:

1. **SMART long test:** the drive's own full surface self-test.
2. **badblocks write:** writes random data to every block.
3. **badblocks verify:** reads every block back and compares it.
4. **Final SMART check:** compares error counters against the values from the start.

Works with **SAS and SATA** drives.

| Result | Meaning |
|---|---|
| **PASS** | Every check passed. |
| **WARN** | Passed, but the drive already had defects or uncorrected errors logged before the test. None were added during it. Common on refurbished drives. |
| **FAIL** | The SMART long test failed or was aborted, badblocks found bad blocks or errors, SMART health isn't OK, or defects or uncorrected errors increased during the test. |
| **INCOMPLETE** | The test stopped partway (reboot, power loss, or it was killed). |

**Defects** are the grown defect list on SAS drives, or reallocated sectors on SATA drives. **Uncorrected** is uncorrected read/write/verify errors on SAS drives, or pending + offline-uncorrectable + reported-uncorrectable sectors on SATA drives.

## Usage

Download it (piping it into bash isn't supported):

```bash
curl -LO https://raw.githubusercontent.com/doug-stewart/hdd-burninator/main/hdd-burninator.sh
```

Test every spinning drive. SSDs, NVMe, USB sticks and the boot drive are skipped automatically:

```bash
sudo bash hdd-burninator.sh
```

Or test only specific drives:

```bash
sudo bash hdd-burninator.sh sda sdb sdc sdd
```

Find drive names with `lsblk -o NAME,SIZE,MODEL,SERIAL,ROTA`.

### While it runs

The progress table refreshes every 30 seconds and shows each drive's step, progress, temperature, time left and error count. Temperatures at or above 45°C are marked with `!`. Add airflow if you see them, especially on a test bench.

**The tests run in the background.** Pressing Ctrl-C, closing the browser shell or dropping SSH only closes the view. Reopen it any time with:

```bash
sudo bash hdd-burninator.sh --status
```

### Results

When every drive is finished, the results are printed as a table: model, serial, size, SMART long test result, badblocks result, defects and uncorrected errors (before → after), max temperature and PASS / WARN / FAIL, followed by details for any drive that didn't pass.

If you closed the view before it finished, run `--status` to see the results.

### Options

| Option | Meaning |
|---|---|
| `--status` | Reopen the progress view, or show the results of a finished run |
| `--skip-smart` | Skip the SMART long test and go straight to badblocks |
| `--refresh SEC` | Progress view refresh interval (default 30) |
| `-h`, `--help` | Help |

## How long it takes

Roughly **2–3 days** for 12–18TB drives: about a day for the SMART long test, then 1–1½ days for the badblocks write and verify passes. Drives run in parallel, so four drives take about as long as one.

## Files

None are left behind. While the test runs, progress is tracked in `/run/hdd-burninator`, which lives in memory and is cleared on reboot. It's deleted once the results have been shown.

## Notes

- Drives over 16TB automatically use an 8192-byte badblocks block size, because badblocks can't address them with 4K blocks.
- Colors and box-drawing characters are used when the terminal supports them, with a plain-ASCII fallback otherwise.
- Requires `smartctl`, `badblocks`, `lsblk`, `blockdev`, `setsid`, `stat` and `zpool`, all included in TrueNAS.
