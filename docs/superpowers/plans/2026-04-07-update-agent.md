# update-agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a shell-based macOS CLI that auto-updates Claude Code, Codex, and Gemini CLI daily via LaunchAgent, with manual run, status, config, and self-uninstall commands.

**Architecture:** A single bash script (`update-agent.sh`) handles all CLI subcommands. A separate `install.sh` copies the script to `~/.local/bin/`, writes a default config file, generates a LaunchAgent plist, and loads it. Configuration is a key=value file sourced at runtime.

**Tech Stack:** Bash, macOS launchd/launchctl, osascript (notifications), Homebrew (for codex/gemini updates)

---

## File Structure

| File | Responsibility |
|---|---|
| `update-agent.sh` | Main script: CLI dispatch, per-tool update functions, log rotation, notifications, version queries, config display, self-uninstall |
| `install.sh` | Installer: detect context (repo vs curl-pipe), copy script, write default config, generate plist, load agent, print summary |
| `README.md` | Usage documentation |

---

### Task 1: Core update-agent.sh — CLI skeleton and config loading

**Files:**
- Create: `update-agent.sh`

This task builds the outer shell: shebang, usage/help, config loading with defaults, and subcommand dispatch. No actual subcommand logic yet — just the structure.

- [ ] **Step 1: Create `update-agent.sh` with shebang, constants, and config loading**

```bash
#!/usr/bin/env bash
set -euo pipefail

readonly VERSION="1.0.0"
readonly CONFIG_FILE="$HOME/.update-agent.conf"
readonly PLIST_PATH="$HOME/Library/LaunchAgents/com.pyang.update-agent.plist"
readonly SCRIPT_PATH="$HOME/.local/bin/update-agent"

# Defaults (overridden by config file)
SCHEDULE_HOUR=6
SCHEDULE_MINUTE=0
TOOLS="claude codex gemini"
LOG_FILE="$HOME/.local/share/update-agent/update.log"
LOG_MAX_KB=512
LOG_KEEP=3

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
}

usage() {
    cat <<'EOF'
Usage: update-agent <command>

Commands:
  run         Run all updates immediately
  status      Show installed versions and last update time
  config      Print current configuration
  uninstall   Remove update-agent, LaunchAgent, and optionally config/logs
  version     Print update-agent version
  help        Show this help message

EOF
}

main() {
    local cmd="${1:-help}"
    load_config

    case "$cmd" in
        run)       cmd_run ;;
        status)    cmd_status ;;
        config)    cmd_config ;;
        uninstall) cmd_uninstall ;;
        version)   echo "update-agent $VERSION" ;;
        help|--help|-h) usage ;;
        *)
            echo "Unknown command: $cmd" >&2
            usage >&2
            exit 1
            ;;
    esac
}

main "$@"
```

- [ ] **Step 2: Verify script is syntactically valid**

Run: `bash -n update-agent.sh`
Expected: No output (clean parse). The script will fail at runtime since `cmd_run` etc. aren't defined yet — that's fine, we just need the syntax check.

- [ ] **Step 3: Commit**

```bash
git add update-agent.sh
git commit -m "feat: add CLI skeleton with config loading and subcommand dispatch"
```

---

### Task 2: Log rotation

**Files:**
- Modify: `update-agent.sh`

Add the `rotate_log` function that checks log size and rotates when needed. This is called at the start of every `run`.

- [ ] **Step 1: Add `rotate_log` function above `main`**

Insert before the `usage()` function:

```bash
rotate_log() {
    [[ -f "$LOG_FILE" ]] || return 0

    local size_kb
    size_kb=$(du -k "$LOG_FILE" | cut -f1)

    if (( size_kb > LOG_MAX_KB )); then
        # Delete oldest if at limit
        if [[ -f "${LOG_FILE}.${LOG_KEEP}" ]]; then
            rm -f "${LOG_FILE}.${LOG_KEEP}"
        fi

        # Shift existing rotated logs
        local i
        for (( i = LOG_KEEP - 1; i >= 1; i-- )); do
            if [[ -f "${LOG_FILE}.${i}" ]]; then
                mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
            fi
        done

        # Rotate current log
        mv "$LOG_FILE" "${LOG_FILE}.1"
    fi
}
```

- [ ] **Step 2: Test log rotation manually**

```bash
mkdir -p "$HOME/.local/share/update-agent"
# Create a fake log that exceeds 512KB
dd if=/dev/zero bs=1024 count=600 2>/dev/null | tr '\0' 'X' > "$HOME/.local/share/update-agent/update.log"
# Source the script functions and run rotate
bash -c '
source ./update-agent.sh 2>/dev/null || true
LOG_FILE="$HOME/.local/share/update-agent/update.log"
LOG_MAX_KB=512
LOG_KEEP=3
rotate_log
ls -la "$HOME/.local/share/update-agent/"
'
```

Expected: `update.log` is gone, `update.log.1` exists (~600KB). A fresh `update.log` does not exist yet (the run creates it).

- [ ] **Step 3: Clean up test files and commit**

```bash
rm -f "$HOME/.local/share/update-agent/update.log"*
git add update-agent.sh
git commit -m "feat: add log rotation by size with configurable max and keep count"
```

---

### Task 3: Notification helper

**Files:**
- Modify: `update-agent.sh`

Add a `notify` function that sends macOS Notification Center banners via osascript.

- [ ] **Step 1: Add `notify` function after `rotate_log`**

```bash
notify() {
    local title="update-agent"
    local message="$1"
    osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
}
```

- [ ] **Step 2: Test notification**

```bash
bash -c 'source ./update-agent.sh 2>/dev/null || true; notify "test notification from update-agent"'
```

Expected: A macOS notification banner appears with title "update-agent" and body "test notification from update-agent".

- [ ] **Step 3: Commit**

```bash
git add update-agent.sh
git commit -m "feat: add macOS notification helper via osascript"
```

---

### Task 4: Per-tool version and update functions

**Files:**
- Modify: `update-agent.sh`

Add `get_version_<tool>` and `update_<tool>` functions for claude, codex, and gemini.

- [ ] **Step 1: Add version and update functions after `notify`**

```bash
get_version_claude() {
    claude --version 2>/dev/null | head -1 || echo "not installed"
}

update_claude() {
    claude update 2>&1
}

get_version_codex() {
    codex --version 2>/dev/null | head -1 || echo "not installed"
}

update_codex() {
    brew upgrade codex 2>&1
}

get_version_gemini() {
    gemini --version 2>/dev/null | head -1 || echo "not installed"
}

update_gemini() {
    brew upgrade gemini-cli 2>&1
}
```

- [ ] **Step 2: Test version functions**

```bash
bash -c '
source ./update-agent.sh 2>/dev/null || true
echo "claude: $(get_version_claude)"
echo "codex: $(get_version_codex)"
echo "gemini: $(get_version_gemini)"
'
```

Expected: Version strings for each installed tool (e.g., `claude: 2.1.92 (Claude Code)`, `codex: codex-cli 0.118.0`, `gemini: 0.36.0`).

- [ ] **Step 3: Commit**

```bash
git add update-agent.sh
git commit -m "feat: add per-tool version and update functions for claude, codex, gemini"
```

---

### Task 5: `cmd_run` — the main update loop

**Files:**
- Modify: `update-agent.sh`

This is the core logic. Iterate over `TOOLS`, call each tool's version/update functions, log results, collect a summary, and send one notification.

- [ ] **Step 1: Add `cmd_run` function after the per-tool functions**

```bash
log_msg() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local msg="[$timestamp] $1"
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$msg" >> "$LOG_FILE"
}

cmd_run() {
    rotate_log
    log_msg "=== update-agent run started ==="

    local summary=""
    local failures=""

    for tool in $TOOLS; do
        local version_fn="get_version_${tool}"
        local update_fn="update_${tool}"

        # Check if functions exist
        if ! declare -f "$version_fn" > /dev/null 2>&1; then
            log_msg "WARN: unknown tool '$tool', skipping"
            continue
        fi

        # Check if tool binary exists
        if ! command -v "$tool" > /dev/null 2>&1; then
            log_msg "WARN: '$tool' not found on PATH, skipping"
            continue
        fi

        # Check if brew is needed but missing
        if [[ "$update_fn" == update_codex || "$update_fn" == update_gemini ]]; then
            if ! command -v brew > /dev/null 2>&1; then
                log_msg "WARN: brew not found, skipping $tool"
                continue
            fi
        fi

        local old_version new_version output
        old_version=$("$version_fn")

        log_msg "Updating $tool (current: $old_version)..."

        if output=$("$update_fn" 2>&1); then
            new_version=$("$version_fn")
            if [[ "$old_version" != "$new_version" ]]; then
                log_msg "$tool updated: $old_version -> $new_version"
                summary="${summary}${tool} ${old_version}->${new_version}, "
            else
                log_msg "$tool already up to date ($old_version)"
                summary="${summary}${tool} up to date, "
            fi
        else
            log_msg "FAIL: $tool update failed: $output"
            failures="${failures}${tool}, "
        fi
    done

    # Trim trailing comma-space
    summary="${summary%, }"
    failures="${failures%, }"

    log_msg "=== update-agent run finished ==="

    # Send notification
    if [[ -n "$failures" ]]; then
        notify "$failures update failed. See $LOG_FILE"
    elif [[ -n "$summary" ]]; then
        notify "$summary"
    else
        notify "No tools configured"
    fi
}
```

- [ ] **Step 2: Test `cmd_run` with a dry run**

```bash
bash update-agent.sh run
```

Expected: Each tool is checked and updated (or reported up to date). A notification appears. Check the log:

```bash
cat "$HOME/.local/share/update-agent/update.log"
```

Expected: Log entries showing timestamps, version checks, and results.

- [ ] **Step 3: Commit**

```bash
git add update-agent.sh
git commit -m "feat: add cmd_run with update loop, logging, and notification summary"
```

---

### Task 6: `cmd_status` — show versions and last update

**Files:**
- Modify: `update-agent.sh`

- [ ] **Step 1: Add `cmd_status` function**

```bash
cmd_status() {
    echo "update-agent $VERSION"
    echo ""
    echo "Installed tool versions:"
    for tool in $TOOLS; do
        local version_fn="get_version_${tool}"
        if declare -f "$version_fn" > /dev/null 2>&1; then
            echo "  $tool: $($version_fn)"
        else
            echo "  $tool: (unknown tool)"
        fi
    done

    echo ""
    if [[ -f "$LOG_FILE" ]]; then
        local last_run
        last_run=$(grep '=== update-agent run started ===' "$LOG_FILE" | tail -1 || true)
        if [[ -n "$last_run" ]]; then
            echo "Last update: $last_run"
        else
            echo "Last update: no runs recorded"
        fi
    else
        echo "Last update: no log file found"
    fi

    echo ""
    if launchctl list com.pyang.update-agent > /dev/null 2>&1; then
        echo "LaunchAgent: loaded (scheduled at ${SCHEDULE_HOUR}:$(printf '%02d' "$SCHEDULE_MINUTE"))"
    else
        echo "LaunchAgent: not loaded"
    fi
}
```

- [ ] **Step 2: Test status command**

```bash
bash update-agent.sh status
```

Expected: Prints version, tool versions, last update time (from previous `run` test), and LaunchAgent status (not loaded yet).

- [ ] **Step 3: Commit**

```bash
git add update-agent.sh
git commit -m "feat: add cmd_status showing versions, last run, and agent state"
```

---

### Task 7: `cmd_config` — print current configuration

**Files:**
- Modify: `update-agent.sh`

- [ ] **Step 1: Add `cmd_config` function**

```bash
cmd_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "Config file: $CONFIG_FILE"
        echo "---"
        cat "$CONFIG_FILE"
    else
        echo "No config file found at $CONFIG_FILE"
        echo "Using defaults:"
        echo "  SCHEDULE_HOUR=$SCHEDULE_HOUR"
        echo "  SCHEDULE_MINUTE=$SCHEDULE_MINUTE"
        echo "  TOOLS=\"$TOOLS\""
        echo "  LOG_FILE=$LOG_FILE"
        echo "  LOG_MAX_KB=$LOG_MAX_KB"
        echo "  LOG_KEEP=$LOG_KEEP"
    fi
}
```

- [ ] **Step 2: Test config command**

```bash
bash update-agent.sh config
```

Expected: Prints "No config file found" with defaults (since we haven't installed yet).

- [ ] **Step 3: Commit**

```bash
git add update-agent.sh
git commit -m "feat: add cmd_config to display current configuration"
```

---

### Task 8: `cmd_uninstall` — self-removal

**Files:**
- Modify: `update-agent.sh`

- [ ] **Step 1: Add `cmd_uninstall` function**

```bash
cmd_uninstall() {
    echo "Uninstalling update-agent..."

    # Unload LaunchAgent
    if launchctl list com.pyang.update-agent > /dev/null 2>&1; then
        echo "Unloading LaunchAgent..."
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
    fi

    # Remove plist
    if [[ -f "$PLIST_PATH" ]]; then
        rm -f "$PLIST_PATH"
        echo "Removed $PLIST_PATH"
    fi

    # Ask about config and logs
    local remove_data="n"
    if [[ -t 0 ]]; then
        printf "Remove config (%s) and logs (%s)? [y/N] " "$CONFIG_FILE" "$(dirname "$LOG_FILE")"
        read -r remove_data
    fi

    if [[ "$remove_data" =~ ^[Yy]$ ]]; then
        rm -f "$CONFIG_FILE"
        rm -rf "$(dirname "$LOG_FILE")"
        echo "Removed config and logs"
    else
        echo "Kept config and logs"
    fi

    # Remove the script itself (must be last)
    if [[ -f "$SCRIPT_PATH" ]]; then
        rm -f "$SCRIPT_PATH"
        echo "Removed $SCRIPT_PATH"
    fi

    echo "update-agent uninstalled."
}
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n update-agent.sh
```

Expected: No output (clean parse). We won't test uninstall destructively now — that happens after install.

- [ ] **Step 3: Commit**

```bash
git add update-agent.sh
git commit -m "feat: add cmd_uninstall for self-removal with optional data cleanup"
```

---

### Task 9: install.sh — the installer

**Files:**
- Create: `install.sh`

Self-contained script that works both from a repo clone and piped via curl.

- [ ] **Step 1: Create `install.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

readonly REPO_URL="https://raw.githubusercontent.com/pyang/update-agent/main"
readonly INSTALL_DIR="$HOME/.local/bin"
readonly INSTALL_PATH="$INSTALL_DIR/update-agent"
readonly CONFIG_FILE="$HOME/.update-agent.conf"
readonly PLIST_LABEL="com.pyang.update-agent"
readonly PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
readonly LOG_DIR="$HOME/.local/share/update-agent"

# Defaults for config
DEFAULT_SCHEDULE_HOUR=6
DEFAULT_SCHEDULE_MINUTE=0

main() {
    echo "Installing update-agent..."

    # Step 1: Find or download update-agent.sh
    local script_src=""
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ -f "${script_dir}/update-agent.sh" ]]; then
        script_src="${script_dir}/update-agent.sh"
        echo "Using local update-agent.sh"
    else
        echo "Downloading update-agent.sh..."
        script_src="$(mktemp)"
        curl -fsSL "${REPO_URL}/update-agent.sh" -o "$script_src"
        trap "rm -f '$script_src'" EXIT
    fi

    # Step 2: Install script to ~/.local/bin/
    mkdir -p "$INSTALL_DIR"
    cp "$script_src" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    echo "Installed script to $INSTALL_PATH"

    # Step 3: Write default config (only if not already present)
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" <<'CONF'
# update-agent configuration
# Changes to SCHEDULE_HOUR/SCHEDULE_MINUTE require re-running install.sh

# Time to run daily (24h format)
SCHEDULE_HOUR=6
SCHEDULE_MINUTE=0

# Which tools to update (space-separated)
TOOLS="claude codex gemini"

# Log file location
LOG_FILE="$HOME/.local/share/update-agent/update.log"

# Max log size in KB before rotation
LOG_MAX_KB=512

# Number of rotated logs to keep
LOG_KEEP=3
CONF
        echo "Created config at $CONFIG_FILE"
    else
        echo "Config already exists at $CONFIG_FILE (preserved)"
    fi

    # Step 4: Read schedule from config
    local schedule_hour=$DEFAULT_SCHEDULE_HOUR
    local schedule_minute=$DEFAULT_SCHEDULE_MINUTE
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    schedule_hour="${SCHEDULE_HOUR:-$DEFAULT_SCHEDULE_HOUR}"
    schedule_minute="${SCHEDULE_MINUTE:-$DEFAULT_SCHEDULE_MINUTE}"

    # Step 5: Generate LaunchAgent plist
    mkdir -p "$(dirname "$PLIST_PATH")"
    cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_PATH}</string>
        <string>run</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>${schedule_hour}</integer>
        <key>Minute</key>
        <integer>${schedule_minute}</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/launchd-stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:${HOME}/.local/bin</string>
    </dict>
</dict>
</plist>
PLIST
    echo "Generated LaunchAgent plist at $PLIST_PATH"

    # Step 6: Load LaunchAgent
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl load "$PLIST_PATH"
    echo "LaunchAgent loaded"

    # Step 7: Create log directory
    mkdir -p "$LOG_DIR"

    # Step 8: Summary
    echo ""
    echo "=== update-agent installed ==="
    echo "  Script:    $INSTALL_PATH"
    echo "  Config:    $CONFIG_FILE"
    echo "  Schedule:  daily at $(printf '%02d:%02d' "$schedule_hour" "$schedule_minute")"
    echo "  Logs:      $LOG_DIR/"
    echo ""
    echo "Commands:"
    echo "  update-agent run         # Run updates now"
    echo "  update-agent status      # Show versions and last update"
    echo "  update-agent config      # Show configuration"
    echo "  update-agent uninstall   # Remove update-agent"

    # Check if ~/.local/bin is in PATH
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        echo ""
        echo "WARNING: $INSTALL_DIR is not in your PATH."
        echo "Add this to your shell profile (~/.zshrc or ~/.bashrc):"
        echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
}

main "$@"
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n install.sh
```

Expected: No output (clean parse).

- [ ] **Step 3: Commit**

```bash
git add install.sh
git commit -m "feat: add self-contained installer with curl-pipe support"
```

---

### Task 10: End-to-end test — install, run, status, uninstall

**Files:** None (manual testing of existing scripts)

- [ ] **Step 1: Run the installer**

```bash
bash install.sh
```

Expected: Script installed to `~/.local/bin/update-agent`, config written to `~/.update-agent.conf`, plist loaded, summary printed.

- [ ] **Step 2: Test `update-agent run`**

```bash
~/.local/bin/update-agent run
```

Expected: Each tool is updated (or reported up to date), a notification appears, and the log file has entries.

- [ ] **Step 3: Test `update-agent status`**

```bash
~/.local/bin/update-agent status
```

Expected: Shows tool versions, last update time, and "LaunchAgent: loaded".

- [ ] **Step 4: Test `update-agent config`**

```bash
~/.local/bin/update-agent config
```

Expected: Displays contents of `~/.update-agent.conf`.

- [ ] **Step 5: Test re-install (idempotent)**

```bash
bash install.sh
```

Expected: Script updated, config preserved ("Config already exists ... preserved"), plist reloaded.

- [ ] **Step 6: Test `update-agent uninstall`**

```bash
~/.local/bin/update-agent uninstall
```

Expected: Prompts about config/logs, removes plist and script, prints confirmation. Answer `n` to keep config/logs for now.

- [ ] **Step 7: Verify uninstall was clean**

```bash
ls -la ~/.local/bin/update-agent 2>&1    # should not exist
launchctl list com.pyang.update-agent 2>&1  # should fail
ls ~/.update-agent.conf                    # should still exist (kept)
```

- [ ] **Step 8: Re-install for ongoing use**

```bash
bash install.sh
```

---

### Task 11: README.md

**Files:**
- Create: `README.md`

- [ ] **Step 1: Create README.md**

```markdown
# update-agent

Auto-update Claude Code, Codex, and Gemini CLI daily on macOS.

## Install

From a clone:

    git clone https://github.com/pyang/update-agent.git
    cd update-agent
    bash install.sh

Or one-liner:

    curl -fsSL https://raw.githubusercontent.com/pyang/update-agent/main/install.sh | sh

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
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with install, usage, and configuration"
```

---

### Task 12: LICENSE file

**Files:**
- Create: `LICENSE`

- [ ] **Step 1: Create MIT LICENSE**

```
MIT License

Copyright (c) 2026 pyang

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Commit**

```bash
git add LICENSE
git commit -m "docs: add MIT license"
```
