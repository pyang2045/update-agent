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

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0

    local perms
    perms=$(stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -n "$perms" ]] && (( 8#$perms & 8#022 )); then
        echo "WARNING: $CONFIG_FILE is writable by group/others (mode $perms). Skipping." >&2
        return 0
    fi

    # Single-pass parse: read all keys in one loop instead of forking per key
    local key val
    while IFS='=' read -r key val; do
        val="${val%\"}"
        val="${val#\"}"
        val="${val%\'}"
        val="${val#\'}"
        case "$key" in
            SCHEDULE_HOUR)   SCHEDULE_HOUR="$val" ;;
            SCHEDULE_MINUTE) SCHEDULE_MINUTE="$val" ;;
            TOOLS)           TOOLS="$val" ;;
            LOG_FILE)        LOG_FILE="${val/\$HOME/$HOME}" ;;
            LOG_MAX_KB)      LOG_MAX_KB="$val" ;;
            LOG_KEEP)        LOG_KEEP="$val" ;;
        esac
    done < <(grep -E '^[A-Z_]+=' "$CONFIG_FILE" 2>/dev/null || true)
}

# ---------------------------------------------------------------------------
# Log rotation
# ---------------------------------------------------------------------------

rotate_log() {
    [[ -f "$LOG_FILE" ]] || return 0

    local size_kb
    size_kb=$(du -k "$LOG_FILE" | cut -f1)

    if (( size_kb > LOG_MAX_KB )); then
        rm -f "${LOG_FILE}.${LOG_KEEP}"

        local i
        for (( i = LOG_KEEP - 1; i >= 1; i-- )); do
            if [[ -f "${LOG_FILE}.${i}" ]]; then
                mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
            fi
        done

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

get_version() {
    "$1" --version 2>/dev/null | head -1 || echo "not installed"
}

update_claude() {
    claude update 2>&1
}

update_codex() {
    command -v brew > /dev/null 2>&1 || { echo "brew not found"; return 1; }
    brew upgrade codex 2>&1
}

update_gemini() {
    command -v brew > /dev/null 2>&1 || { echo "brew not found"; return 1; }
    brew upgrade gemini-cli 2>&1
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_msg() {
    local line
    printf -v line '[%(%Y-%m-%d %H:%M:%S)T] %s' -1 "$1"
    echo "$line" >> "$LOG_FILE"
    if [[ -t 1 ]]; then echo "$line"; fi
}

# ---------------------------------------------------------------------------
# cmd_run
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
        local update_fn="update_${tool}"

        if ! declare -f "$update_fn" > /dev/null 2>&1; then
            log_msg "WARN: unknown tool '$tool', skipping"
            continue
        fi

        if ! command -v "$tool" > /dev/null 2>&1; then
            log_msg "WARN: '$tool' not found on PATH, skipping"
            continue
        fi

        local old_version new_version output
        old_version=$(get_version "$tool")

        log_msg "Updating $tool (current: $old_version)..."

        if output=$("$update_fn" 2>&1); then
            new_version=$(get_version "$tool")
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

    summary="${summary%, }"
    failures="${failures%, }"

    log_msg "=== update-agent run finished ==="

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
        echo "  $tool: $(get_version "$tool")"
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

    if launchctl list com.pyang.update-agent > /dev/null 2>&1; then
        echo "Unloading LaunchAgent..."
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
    fi

    rm -f "$PLIST_PATH" && echo "Removed $PLIST_PATH"

    local remove_data="n"
    if [[ -t 0 ]]; then
        printf "Remove config (%s) and logs? [y/N] " "$CONFIG_FILE"
        read -r remove_data
    fi

    if [[ "$remove_data" =~ ^[Yy]$ ]]; then
        rm -f "$CONFIG_FILE"
        local log_dir="$HOME/.local/share/update-agent"
        if [[ -d "$log_dir" ]]; then
            rm -rf "$log_dir"
        fi
        echo "Removed config and logs"
    else
        echo "Kept config and logs"
    fi

    # Must be last — the running script deletes itself
    rm -f "$SCRIPT_PATH" && echo "Removed $SCRIPT_PATH"

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
