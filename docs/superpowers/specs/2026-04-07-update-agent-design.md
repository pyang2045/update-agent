# update-agent Design Spec

**Date:** 2026-04-07
**Status:** Draft

## Overview

A shell-based auto-update tool for macOS that keeps Claude Code, Codex, and Gemini CLI up to date on a daily schedule using macOS LaunchAgent. Provides a CLI for manual runs, status checks, and self-uninstall.

## Repository Structure

```
update-agent/
├── update-agent.sh        # Main script (run/status/config/uninstall)
├── install.sh             # Self-contained installer (also supports curl | sh)
├── README.md
└── LICENSE
```

## Installed Files

| File | Path | Purpose |
|---|---|---|
| Main script | `~/.local/bin/update-agent` | CLI entry point |
| Config | `~/.update-agent.conf` | User configuration |
| LaunchAgent | `~/Library/LaunchAgents/com.pyang.update-agent.plist` | Daily schedule |
| Log dir | `~/.local/share/update-agent/` | Update logs |

## Configuration (`~/.update-agent.conf`)

Simple key=value file, sourced directly by the script:

```bash
# Time to run daily (24h format, used by install to write plist)
SCHEDULE_HOUR=6
SCHEDULE_MINUTE=0

# Which tools to update (space-separated)
TOOLS="claude codex gemini"

# Log file location
LOG_FILE="$HOME/.local/share/update-agent/update.log"

# Max log size in KB before rotation (default: 512KB)
LOG_MAX_KB=512

# Number of rotated logs to keep (default: 3)
LOG_KEEP=3
```

- Changing `SCHEDULE_HOUR`/`SCHEDULE_MINUTE` requires re-running `install.sh` to regenerate the plist.
- Changing `TOOLS` takes effect on the next run immediately.
- Adding new tools means adding an update function in the script and the tool name to the config.

## CLI Interface

```bash
update-agent run         # Run all updates immediately
update-agent status      # Show installed versions + last update time
update-agent config      # Print current config
update-agent uninstall   # Unload agent, remove plist, script; prompt about config/logs
```

## Tool Update Commands

Each tool has its own update function. The script captures the version before and after to determine if an update occurred.

| Tool | Version Command | Update Command |
|---|---|---|
| Claude Code | `claude --version` | `claude update` |
| Codex | `codex --version` | `brew upgrade codex` |
| Gemini CLI | `gemini --version` | `brew upgrade gemini-cli` |

## Update Flow

For each run (scheduled or manual):

1. Source `~/.update-agent.conf`
2. Check log size; rotate if it exceeds `LOG_MAX_KB`
   - `update.log` -> `update.log.1` -> `update.log.2` -> ... oldest beyond `LOG_KEEP` deleted
3. For each tool in `TOOLS`:
   - Record current version
   - Run the tool's update command
   - Record new version
   - Log result: `updated X.X.X -> Y.Y.Y`, `already up to date`, or `FAILED`
4. Send a single macOS notification summarizing all results

## Notifications

Uses `osascript -e 'display notification "message" with title "update-agent"'` for native macOS Notification Center banners.

**Notification content:**
- Success: `"update-agent: claude 2.1.92->2.2.0, codex/gemini up to date"`
- Partial failure: `"update-agent: codex update failed. See ~/.local/share/update-agent/update.log"`
- All up to date: `"update-agent: all tools up to date"`

## Scheduling (macOS LaunchAgent)

A plist file at `~/Library/LaunchAgents/com.pyang.update-agent.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.pyang.update-agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/pyang/.local/bin/update-agent</string>
        <string>run</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>6</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>/Users/pyang/.local/share/update-agent/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/pyang/.local/share/update-agent/launchd-stderr.log</string>
</dict>
</plist>
```

- `StartCalendarInterval` triggers daily at the configured hour/minute.
- If the Mac was asleep at the scheduled time, launchd runs the job when it wakes.

## Log Rotation

Before each run, the script checks the log file size:

1. If `LOG_FILE` size > `LOG_MAX_KB` KB:
   - Delete `update.log.{LOG_KEEP}` if it exists
   - Shift `update.log.N` -> `update.log.N+1` for N = LOG_KEEP-1 down to 1
   - Move `update.log` -> `update.log.1`
   - Start fresh `update.log`
2. Otherwise, append to existing log.

## install.sh

**Behavior:**

1. Detect if running from repo directory or piped from curl:
   - If `update-agent.sh` exists in the same directory as `install.sh`, use it directly (repo clone).
   - Otherwise, download `update-agent.sh` from GitHub raw URL to a temp dir (curl pipe case).
2. Copy `update-agent.sh` to `~/.local/bin/update-agent`, `chmod +x`.
   - Create `~/.local/bin/` if it doesn't exist.
3. Write `~/.update-agent.conf` with defaults **only if it doesn't already exist** (preserves user config on re-install).
4. Source the config to read `SCHEDULE_HOUR` and `SCHEDULE_MINUTE`.
5. Generate `~/Library/LaunchAgents/com.pyang.update-agent.plist` with the configured time.
6. `launchctl unload` the plist if already loaded, then `launchctl load` it.
7. Create log directory `~/.local/share/update-agent/`.
8. Print summary: installed path, config path, scheduled time, next steps.

**Idempotent:** Safe to re-run. Updates script and plist, preserves config.

**Distribution:**

```bash
curl -fsSL https://raw.githubusercontent.com/<user>/update-agent/main/install.sh | sh
```

## update-agent uninstall

1. `launchctl unload ~/Library/LaunchAgents/com.pyang.update-agent.plist`
2. Remove `~/Library/LaunchAgents/com.pyang.update-agent.plist`
3. Remove `~/.local/bin/update-agent`
4. Prompt user: remove config (`~/.update-agent.conf`) and logs (`~/.local/share/update-agent/`)? Default: no.
5. Print confirmation.

## Error Handling

- If a tool's binary is not found on PATH, skip it and log a warning.
- If `brew` is not found, skip brew-based tools and log a warning.
- If the update command fails (non-zero exit), log stderr output and include the tool in the failure notification.
- The script continues updating remaining tools even if one fails.

## Adding New Tools

To add a new CLI tool in the future:

1. Add an `update_<toolname>()` function to `update-agent.sh` that defines the version and update commands.
2. Add `<toolname>` to the `TOOLS` variable in `~/.update-agent.conf`.
