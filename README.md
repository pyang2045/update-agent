# update-agent

Keep your AI coding CLI tools up to date automatically on macOS.

**update-agent** is a lightweight shell-based tool that runs daily via macOS LaunchAgent to update [Claude Code](https://github.com/anthropics/claude-code), [Codex CLI](https://github.com/openai/codex), and [Gemini CLI](https://github.com/google-gemini/gemini-cli). It sends a native macOS notification with version details after each run, rotates logs to prevent disk bloat, and can be fully managed from a single command.

### Features

- **Scheduled daily updates** via macOS LaunchAgent (runs even after sleep/wake)
- **macOS Notification Center** alerts with version info (updated or up to date)
- **Configurable schedule** — change the hour/minute in a simple config file
- **Configurable tool list** — add or remove tools without editing the script
- **Log rotation** — size-based rotation with configurable max size and retention
- **Interactive console output** — see progress when running manually
- **One-command install and uninstall** — no package manager required
- **Idempotent installer** — safe to re-run, preserves your config
- **curl-pipe install** — single command to get started

### Supported Tools

| Tool | Update Method |
|---|---|
| [Claude Code](https://github.com/anthropics/claude-code) | `claude update` |
| [Codex CLI](https://github.com/openai/codex) | `brew upgrade codex` |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | `brew upgrade gemini-cli` |

New tools can be added by defining a version/update function pair and adding the name to the config.

## Install

From a clone:

    git clone https://github.com/pyang2045/update-agent.git
    cd update-agent
    bash install.sh

Or one-liner:

    curl -fsSL https://raw.githubusercontent.com/pyang2045/update-agent/master/install.sh | bash

### What the installer does

1. Copies `update-agent` to `~/.local/bin/`
2. Creates `~/.update-agent.conf` with sensible defaults (preserves existing config)
3. Generates and loads a LaunchAgent plist for daily scheduling
4. Creates the log directory at `~/.local/share/update-agent/`

## Usage

    update-agent run         # Run all updates now (shows progress in terminal)
    update-agent status      # Show installed versions, last update time, schedule
    update-agent config      # Print current configuration
    update-agent uninstall   # Remove update-agent, LaunchAgent, and optionally config/logs
    update-agent version     # Print update-agent version

## Configuration

Edit `~/.update-agent.conf`:

    SCHEDULE_HOUR=6        # Hour to run (0-23)
    SCHEDULE_MINUTE=0      # Minute to run (0-59)
    TOOLS="claude codex gemini"
    LOG_FILE="$HOME/.local/share/update-agent/update.log"
    LOG_MAX_KB=512         # Rotate log after this size (KB)
    LOG_KEEP=3             # Number of rotated logs to keep

After changing the schedule time, re-run `bash install.sh` to update the LaunchAgent.

## How It Works

1. A macOS LaunchAgent triggers `update-agent run` daily at the configured time
2. For each tool, the script records the current version, runs the update command, and records the new version
3. Results are logged to `~/.local/share/update-agent/update.log`
4. A single macOS notification summarizes the outcome:
   - `claude 2.1.92->2.2.0, codex 0.118.0 (up to date), gemini 0.36.0 (up to date)`
   - Or failure details with a pointer to the log file
5. If the Mac was asleep at the scheduled time, the update runs when it wakes

## Requirements

- macOS
- [Homebrew](https://brew.sh/) (for Codex and Gemini CLI updates)
- The CLI tools you want to update must already be installed

## Uninstall

    update-agent uninstall

This unloads the LaunchAgent, removes the plist and script, and optionally removes config and logs.

## License

MIT
