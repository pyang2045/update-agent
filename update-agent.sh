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

# ---------------------------------------------------------------------------
# Config — safe key=value parser (never source untrusted files)
# ---------------------------------------------------------------------------

_parse_config_val() {
    grep -E "^${1}=" "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'" || true
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0

    # Refuse to load config writable by group/others
    local perms
    perms=$(stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null || stat -c '%a' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -n "$perms" ]] && (( 8#$perms & 8#022 )); then
        echo "WARNING: $CONFIG_FILE is writable by group/others (mode $perms). Skipping." >&2
        return 0
    fi

    local val
    val=$(_parse_config_val SCHEDULE_HOUR);   [[ -n "$val" ]] && SCHEDULE_HOUR="$val"
    val=$(_parse_config_val SCHEDULE_MINUTE); [[ -n "$val" ]] && SCHEDULE_MINUTE="$val"
    val=$(_parse_config_val TOOLS);           [[ -n "$val" ]] && TOOLS="$val"
    val=$(_parse_config_val LOG_FILE);        [[ -n "$val" ]] && LOG_FILE="${val/\$HOME/$HOME}"
    val=$(_parse_config_val LOG_MAX_KB);      [[ -n "$val" ]] && LOG_MAX_KB="$val"
    val=$(_parse_config_val LOG_KEEP);        [[ -n "$val" ]] && LOG_KEEP="$val"
}

# ---------------------------------------------------------------------------
# Log rotation
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Notification helper
# ---------------------------------------------------------------------------

notify() {
    local message="${1//\"/\'}"
    osascript -e "display notification \"$message\" with title \"update-agent\"" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Per-tool version and update functions
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_msg() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local line="[$timestamp] $1"
    echo "$line" >> "$LOG_FILE"
    # Print to console when run interactively
    if [[ -t 1 ]]; then echo "$line"; fi
}

# ---------------------------------------------------------------------------
# cmd_run — main update loop
# ---------------------------------------------------------------------------

cmd_run() {
    mkdir -p "$(dirname "$LOG_FILE")"
    rotate_log
    log_msg "=== update-agent run started ==="

    local summary=""
    local failures=""

    local -a tool_list
    read -ra tool_list <<< "$TOOLS"

    for tool in "${tool_list[@]}"; do
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
                summary="${summary}${tool} ${old_version} (up to date), "
            fi
        else
            log_msg "FAIL: $tool update failed"
            echo "$output" >> "$LOG_FILE"
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

# ---------------------------------------------------------------------------
# cmd_status
# ---------------------------------------------------------------------------

cmd_status() {
    echo "update-agent $VERSION"
    echo ""
    echo "Installed tool versions:"
    local -a tool_list
    read -ra tool_list <<< "$TOOLS"
    for tool in "${tool_list[@]}"; do
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

# ---------------------------------------------------------------------------
# cmd_config
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# cmd_uninstall
# ---------------------------------------------------------------------------

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
        # Only remove the known app-owned log directory, never a config-derived path
        local log_dir="$HOME/.local/share/update-agent"
        if [[ -d "$log_dir" ]]; then
            rm -rf "$log_dir"
        fi
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

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

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
