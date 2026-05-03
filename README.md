# vpx-autoqa-monitor

Companion scripts for [PinUP Popper](https://www.nailbuster.com/wikipinup/) **PopperAutoQA** that turn its silent table-cycling run into a structured, categorized failure report.

## What it does

PopperAutoQA cycles every table in the database, plays each for ~48s, and moves on. It does *not*:

- close VPX cleanly when a table modal-pops (missing ROM, VBScript error) — those processes leak and accumulate
- log *which* tables failed
- categorize *why* they failed

This repo adds three lightweight PowerShell daemons and a SQL analyzer that fix all three:

| Script | What it does |
|---|---|
| `scripts/autoqa-watcher.ps1`   | Polls likely output dirs every 30s; logs every new/modified file with timestamp + size — useful for forensic correlation. |
| `scripts/autoqa-janitor.ps1`   | Every 15 min, finds any `VPinballX.exe` older than 5 min, captures its window titles + modal dialog body text, then force-kills it. Writes one row per kill to a CSV. |
| `scripts/list-leaked-vpx.ps1`  | One-shot snapshot of currently leaked VPX processes (for ad-hoc inspection). |
| `scripts/get-vpx-crashes.ps1`  | Parses Windows `Application Error` events for VPinballX crashes; emits CSV with timestamp + faulting module + exception code. |
| `analysis/categorize-failures.sql` | Joins everything against `PUPDatabase.db` to produce a failure-type breakdown (pure crash vs hang+kill vs silent hang) per table. |

The combined output lets you go from "1300 tables, ~5–20% break, no idea which" to "here are the 168 broken tables, sorted by failure type, with the modal dialog text for triage."

## Why the janitor is non-trivial

Two gotchas that aren't obvious:

1. **Session 0 vs Session 1.** Windows OpenSSH spawns shells in Session 0 (services). VPX runs in the user's interactive Session 1. `EnumWindows()` only sees windows on the calling thread's desktop, so a janitor launched over SSH **cannot read VPX's modal dialog text**. Solution: launch the janitor as a Task Scheduler task with `/IT` (interactive) so it lands in Session 1. Process-killing works fine cross-session, but window-reading does not.

2. **AutoQA leaks ~3–5% of launches.** Tables that hit a modal error dialog block AutoQA's "next table" advance just enough that AutoQA gives up and moves on without killing VPX. Without the janitor, ~50 zombie VPX processes pile up overnight and exhaust RAM before the run finishes.

## Prerequisites

- Windows 10/11 cabinet running PinUP Popper + Visual Pinball X
- PowerShell 5.1+
- (Optional) `sqlite3` on whatever machine you want to run the analysis from

## Setup

The scripts default to staging in `C:\Users\<user>\AppData\Local\Temp\` and writing logs/CSVs there. Adjust the paths at the top of each `.ps1` if you want them somewhere persistent.

### 1. Stage scripts on the cabinet

Copy `scripts/autoqa-watcher.ps1`, `scripts/autoqa-janitor.ps1`, and `scripts/get-vpx-crashes.ps1` to e.g. `C:\Users\pinball\AppData\Local\Temp\`.

### 2. Take a baseline snapshot (optional, recommended)

Lets you do a clean filesystem diff after the run to catch anything AutoQA writes that the watcher missed.

```powershell
$snap = "$env:TEMP\autoqa-baseline.txt"
$paths = 'D:\vPinball\PinUPSystem','D:\vPinball\VisualPinball\User','C:\Users\pinball\Documents'
Get-ChildItem $paths -Recurse -File -ErrorAction SilentlyContinue |
    Select-Object FullName, Length, @{n='Mtime';e={$_.LastWriteTime.Ticks}} |
    Export-Csv $snap -NoTypeInformation
```

### 3. Launch the watcher (Session 0 is fine)

The watcher only touches the filesystem, so session doesn't matter. Spawn it WMI-detached so it survives SSH disconnects:

```powershell
$cmd = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\Users\pinball\AppData\Local\Temp\autoqa-watcher.ps1'
Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }
```

### 4. Launch the janitor (MUST be in Session 1)

Use Task Scheduler with `/IT` (interactive). This is the critical bit — without `/IT`, dialog-text capture returns empty.

```powershell
schtasks /create /tn 'AutoQAJanitor' /sc once /st '23:59:00' /sd '12/31/2099' `
    /tr 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\Users\pinball\AppData\Local\Temp\autoqa-janitor.ps1' `
    /it /f
schtasks /run /tn 'AutoQAJanitor'
```

The `/sd 12/31/2099` keeps the schedule from firing automatically — we only ever invoke it via `/run`.

### 5. Start the AutoQA run

On the **physical cabinet desktop** (the GUI must be visible):

1. Exit Popper if it's running so AutoQA isn't fighting it for displays.
2. Launch `D:\vPinball\PinUPSystem\PopperAutoQA.exe`.
3. Configure for "all tables / launch test" and start.

Expect ~1 table/min. A 1,300-table library runs ~22 hours.

### 6. (Optional) Engage Pinscape Night Mode

If you have a Pinscape controller, suppress noisy toy outputs at the controller without disrupting DOF:

```
D:\PinscapeConfigTool\PinscapeCmd.exe NightMode=ON Quiet
```

This is a one-shot HID command; AutoQA/DOF traffic is unaffected.

## Live monitoring during the run

| File | What's in it |
|---|---|
| `%TEMP%\autoqa-watch.log`              | Every new/modified file, with tick markers every 30s. |
| `%TEMP%\autoqa-janitor.log`            | Each janitor cycle (`tick @ HH:MM:SS totalVpx=N leaked=N killed=N`) plus per-kill detail lines with PID, age, RAM, table name, window title preview. |
| `%TEMP%\autoqa-failed-tables.csv`      | One row per janitor kill: `KilledAt, PID, AgeMin, TableFile, RamMB, WindowClass, Title, DialogText`. |
| `D:\vPinball\PinUPSystem\PUPDatabase.db` | AutoQA's progress lives in `GamesStats.LastPlayed`. Query to see overall progress. |

Quick "how far along is it?" via SSH:

```powershell
sqlite3 PUPDatabase.db "SELECT COUNT(*) FROM GamesStats WHERE LastPlayed >= date('now')"
sqlite3 PUPDatabase.db "SELECT g.GameDisplay, s.LastPlayed FROM GamesStats s JOIN Games g ON s.GameID=g.GameID WHERE s.LastPlayed >= date('now') ORDER BY s.LastPlayed DESC LIMIT 5"
```

## Post-run analysis

### 1. Capture the crash event log

```powershell
.\scripts\get-vpx-crashes.ps1
# writes %TEMP%\autoqa-crashes.csv
```

### 2. Pull everything to your analysis machine

```bash
scp pinball@cabinet:C:/Users/pinball/AppData/Local/Temp/autoqa-failed-tables.csv .
scp pinball@cabinet:C:/Users/pinball/AppData/Local/Temp/autoqa-crashes.csv .
scp pinball@cabinet:D:/vPinball/PinUPSystem/PUPDatabase.db .
```

### 3. Run the categorizer

```bash
sqlite3 PUPDatabase.db < analysis/categorize-failures.sql
```

You'll get:

- **Headline numbers** — total attempts, crashes, hangs, overlap.
- **Faulting module breakdown** — `VPinballX.exe` (generic crash), `OLEAUT32.dll` (COM/VBScript), `unknown` (hard fault). Small modules → small fix-buckets you can resolve together.
- **Hang severity** — RAM at force-kill correlates with where the launch died (early ROM error <100 MB / mid-load 100–400 MB / render hang 400+ MB).
- **Top dialog texts** — once janitor v2 has been running, the `DialogText` column groups failures by exact error message ("Cannot find ROM 'mm_109c'", "Object required: 'Controller'", etc.).
- **Full failure list** — every broken table with timestamp + type, sorted chronologically.

## Cleanup

Stop the daemons after the run:

```powershell
schtasks /delete /tn 'AutoQAJanitor' /f
Get-Process powershell -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -eq '' -and $_.StartTime -lt (Get-Date).AddHours(-1) } |
    Stop-Process -Force
```

(Adjust the watcher kill heuristic to your situation — easiest is just to grab the watcher's PID at spawn time and `Stop-Process -Id` it.)

Restore Pinscape if you engaged Night Mode:

```
D:\PinscapeConfigTool\PinscapeCmd.exe NightMode=OFF Quiet
```

## Architecture notes

- **Watcher polls instead of using `FileSystemWatcher`.** FSW events get noisy fast on a cabinet's AppData tree; a 30s poll over a tight scoped path list is simpler and bounded (~50 ms per tick on a 4-core box).
- **Janitor uses WMI for command-line capture.** `Get-Process` doesn't expose `CommandLine`; `Get-CimInstance Win32_Process` does, which is how we pull the `-play "<path>"` arg to identify the table.
- **Window enumeration uses Win32 P/Invoke (`EnumWindows`/`EnumChildWindows`/`GetWindowTextW`).** Modal dialog body text lives in child `Static` controls. We capture every child whose text is non-empty + non-trivial. UI Automation would be cleaner but adds a dependency without much benefit.
- **CSV migration is idempotent.** If you upgrade the janitor mid-run from a schema without `WindowClass/Title/DialogText` to one with them, run `Import-Csv | Select-Object ... | Export-Csv` to add empty columns to existing rows.

## License

MIT.
