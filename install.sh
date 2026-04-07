#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# install.sh — self-contained installer for update-agent
# Works both from a repo clone and piped via curl:
#   curl -fsSL https://raw.githubusercontent.com/pyang/update-agent/main/install.sh | bash
# ---------------------------------------------------------------------------

readonly REPO_URL="https://raw.githubusercontent.com/pyang/update-agent/main"
readonly INSTALL_DIR="$HOME/.local/bin"
readonly INSTALL_PATH="$INSTALL_DIR/update-agent"
readonly CONFIG_FILE="$HOME/.update-agent.conf"
readonly PLIST_LABEL="com.pyang.update-agent"
readonly PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
readonly LOG_DIR="$HOME/.local/share/update-agent"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()  { printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
warn()  { printf '  \033[1;33m⚠\033[0m %s\n' "$1"; }
error() { printf '  \033[1;31m✗\033[0m %s\n' "$1" >&2; }
step()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. Obtain update-agent.sh
# ---------------------------------------------------------------------------

TMPDIR_CLEANUP=""

cleanup() {
    if [[ -n "$TMPDIR_CLEANUP" && -d "$TMPDIR_CLEANUP" ]]; then
        rm -rf "$TMPDIR_CLEANUP"
    fi
}
trap cleanup EXIT

step "Locating update-agent.sh..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd 2>/dev/null || true)"
SOURCE_SCRIPT=""

if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/update-agent.sh" ]]; then
    SOURCE_SCRIPT="$SCRIPT_DIR/update-agent.sh"
    info "Found in repo directory: $SOURCE_SCRIPT"
else
    info "Not running from repo — downloading from GitHub..."
    TMPDIR_CLEANUP="$(mktemp -d)"
    if curl -fsSL "${REPO_URL}/update-agent.sh" -o "$TMPDIR_CLEANUP/update-agent.sh"; then
        SOURCE_SCRIPT="$TMPDIR_CLEANUP/update-agent.sh"
        info "Downloaded to $SOURCE_SCRIPT"
    else
        error "Failed to download update-agent.sh from ${REPO_URL}/update-agent.sh"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 2. Install to ~/.local/bin/update-agent
# ---------------------------------------------------------------------------

step "Installing update-agent..."

mkdir -p "$INSTALL_DIR"
cp "$SOURCE_SCRIPT" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"
info "Installed to $INSTALL_PATH"

# ---------------------------------------------------------------------------
# 3. Write default config (only if it doesn't already exist)
# ---------------------------------------------------------------------------

step "Configuring..."

if [[ -f "$CONFIG_FILE" ]]; then
    info "Config already exists at $CONFIG_FILE (preserved)"
else
    cat > "$CONFIG_FILE" << 'CONF'
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
    info "Created default config at $CONFIG_FILE"
fi

# ---------------------------------------------------------------------------
# 4. Source config for schedule values
# ---------------------------------------------------------------------------

SCHEDULE_HOUR=6
SCHEDULE_MINUTE=0
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# ---------------------------------------------------------------------------
# 5. Generate LaunchAgent plist
# ---------------------------------------------------------------------------

step "Setting up LaunchAgent..."

mkdir -p "$(dirname "$PLIST_PATH")"

cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
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
        <integer>${SCHEDULE_HOUR}</integer>
        <key>Minute</key>
        <integer>${SCHEDULE_MINUTE}</integer>
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
EOF

info "Generated $PLIST_PATH"

# ---------------------------------------------------------------------------
# 6. Load LaunchAgent
# ---------------------------------------------------------------------------

launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"
info "LaunchAgent loaded"

# ---------------------------------------------------------------------------
# 7. Create log directory
# ---------------------------------------------------------------------------

mkdir -p "$LOG_DIR"
info "Log directory ready: $LOG_DIR"

# ---------------------------------------------------------------------------
# 8. Summary
# ---------------------------------------------------------------------------

step "Installation complete!"

printf '\n'
printf '  %-20s %s\n' "Installed to:" "$INSTALL_PATH"
printf '  %-20s %s\n' "Config:" "$CONFIG_FILE"
printf '  %-20s %s\n' "Plist:" "$PLIST_PATH"
printf '  %-20s %s\n' "Log directory:" "$LOG_DIR"
printf '  %-20s %02d:%02d daily\n' "Scheduled:" "$SCHEDULE_HOUR" "$SCHEDULE_MINUTE"
printf '\n'
printf '  Available commands:\n'
printf '    update-agent run         Run all updates immediately\n'
printf '    update-agent status      Show installed versions and last update\n'
printf '    update-agent config      Print current configuration\n'
printf '    update-agent uninstall   Remove update-agent completely\n'
printf '\n'

# ---------------------------------------------------------------------------
# 9. Check if ~/.local/bin is in PATH
# ---------------------------------------------------------------------------

if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    warn "WARNING: $INSTALL_DIR is not in your PATH"
    printf '\n'
    printf '  Add it to your shell profile:\n'
    printf '\n'
    if [[ -n "${ZSH_VERSION:-}" ]] || [[ "$SHELL" == */zsh ]]; then
        printf '    echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.zshrc\n'
        printf '    source ~/.zshrc\n'
    else
        printf '    echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.bashrc\n'
        printf '    source ~/.bashrc\n'
    fi
    printf '\n'
fi
