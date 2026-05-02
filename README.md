# Time Tracker Skill

A cross-platform OpenClaw skill for collecting 2-hour activity logs and rebuilding daily time statistics from real records.

It is designed to run on both:

- macOS / Linux with `pwsh` or `./run.sh`
- Windows with `pwsh` or `powershell.exe`

## What It Does

- asks what happened in the previous 2-hour slot
- turns free-form replies into structured detail records
- writes detail rows to a Lark/Feishu base
- audits one day of records for duplicates, overlaps, gaps, and timestamp mismatches
- rebuilds daily summary rows from the real detail table instead of session memory

## Repository Safety

This public repository does **not** include any real:

- Lark/Feishu base tokens
- table IDs
- field IDs
- local machine paths or private config files

All private IDs live in a local file named `time-tracker.config.json`, which is gitignored.

## Requirements

- PowerShell 7+ (`pwsh`)
- Python 3
- `lark-cli`
- a local `time-tracker.config.json`

## Setup

1. Copy the example config:

```bash
cp time-tracker.config.example.json time-tracker.config.json
```

2. Fill in your own private values inside `time-tracker.config.json`:

- `BaseToken`
- detail table ID
- stats table ID
- all required field IDs

3. Make sure `pwsh`, `python3`, and `lark-cli` are available.

## Usage

macOS / Linux:

```bash
./run.sh -CurrentHour 10 -Phase ask
./run.sh -CurrentHour 10 -Phase store -UserInput "1小时写代码，1小时开会"
```

PowerShell directly:

```powershell
pwsh -File ./run.ps1 -CurrentHour 10 -Phase ask
pwsh -File ./run.ps1 -CurrentHour 22 -Phase summary -WriteBackStats
```

Windows PowerShell example:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\run.ps1 -CurrentHour 10 -Phase ask
```

## Main Files

- `run.ps1`: main runtime entrypoint
- `run.sh`: macOS / Linux wrapper
- `scripts/get-day-records.ps1`: fetch one day of detail rows
- `scripts/audit-day.ps1`: audit one day's records
- `scripts/rebuild-day.ps1`: rebuild daily stats
- `scripts/repair-date.ps1`: repair wrong dates and optionally rebuild
- `scripts/lib/common.ps1`: shared helper functions
- `scripts/lib/field-map.ps1`: loads private config and exposes schema

## Notes

- `SKILL.md` contains the richer OpenClaw-oriented operating notes.
- Some root-level helper scripts are legacy artifacts kept for reference.
