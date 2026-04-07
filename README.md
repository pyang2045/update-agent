# update-agent

Auto-update Claude Code, Codex, and Gemini CLI daily on macOS.

## Install

From a clone:

    git clone https://github.com/pyang2045/update-agent.git
    cd update-agent
    bash install.sh

Or one-liner:

    curl -fsSL https://raw.githubusercontent.com/pyang2045/update-agent/master/install.sh | bash

## Usage

    update-agent run         # Run all updates now
    update-agent status      # Show installed versions and last update time
    update-agent config      # Print current configuration
    update-agent uninstall   # Remove update-agent

## Configuration

Edit `~/.update-agent.conf`:

    SCHEDULE_HOUR=6        # Hour to run (0-23)
    SCHEDULE_MINUTE=0      # Minute to run (0-59)
    TOOLS="claude codex gemini"
    LOG_FILE="$HOME/.local/share/update-agent/update.log"
    LOG_MAX_KB=512         # Rotate log after this size
    LOG_KEEP=3             # Number of rotated logs to keep

After changing schedule time, re-run `bash install.sh` to update the LaunchAgent.

## How It Works

- A macOS LaunchAgent runs `update-agent run` daily at the configured time
- Each tool is updated using its native method:
  - `claude update` for Claude Code
  - `brew upgrade codex` for Codex
  - `brew upgrade gemini-cli` for Gemini CLI
- Results are logged and a macOS notification is sent
- If the Mac is asleep at the scheduled time, the update runs when it wakes

## Uninstall

    update-agent uninstall

## License

MIT
