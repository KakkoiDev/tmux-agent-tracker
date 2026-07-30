#!/usr/bin/env bash
# helpers.sh - Config loading and tmux helpers for tmux-agent-tracker

# ── Plugin directory resolution ──────────────────────────────────────

if [[ -z "${AGENT_TRACKER_PLUGIN_DIR:-}" ]]; then
    AGENT_TRACKER_PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
SCRIPTS_DIR="$AGENT_TRACKER_PLUGIN_DIR/scripts"

# ── platform helpers ──────────────────────────────────────────────────

_file_mtime() {
    case "$(uname)" in
        Darwin) stat -f %m "$1" ;;
        *)      stat -c %Y "$1" ;;
    esac
}

# Check if a shell process has a Claude/Codex/Gemini/Deerbox/Pi child.
# macOS pgrep -P silently fails for processes that rename argv[0],
# so fall back to ps-based lookup on Darwin.
# Uses comm (display name) not ucomm (binary name) to match agent
# names specifically, avoiding false positives from generic node
# processes. Includes "deer" and "deerbox" since deerbox runs claude
# inside a sandbox where hooks cannot fire, so host-side scan is
# the only detection path.
# Every process name that counts as an agent harness. One list, so adding a
# harness is one edit rather than one per platform branch.
#
# Keep this list identical to tmux-agent-resumer/scripts/helpers.sh. It drifted
# once already: this file listed eight names and the resumer's Linux branch
# listed five, dropping deer, deerbox and agy, so on Linux the resumer's
# give-up check could not see an agent the tracker's reaper could. Both are
# destined for the shared lib/identity.sh.
_AGENT_COMMS="claude codex gemini deer deerbox pi agy antigravity"

# _has_agent_child <pane_pid> - is an agent harness this pid, or a direct child?
#
# One `ps | awk` for both platforms, not a Darwin/Linux fork.
#
# `comm`, never `pane_current_command`: Claude Code rewrites argv[0] to its own
# version string, so tmux reports the pane's command as e.g. "2.1.220".
#
# Two things the ppid-only, exact-match version got wrong. Both measured here:
#
#   * It matched `$1 == p` where $1 is ppid, so it could only ever find a CHILD.
#     A pane whose OWN process is the harness has no agent child, and that is
#     exactly the shape `tmux-agent-mesh dispatch` creates - its own test is
#     "dispatch runs the harness as the pane's own process". Every dispatched
#     agent was therefore invisible: the tracker's _reap_dead deleted its row
#     with reason=no_agent, and the resumer marked it "gaveup: no live agent".
#   * `ps -eo comm` prints the executable *as invoked*, not its basename. A bare
#     PATH invocation gives `claude`, but an absolute one gives
#     `/opt/homebrew/bin/claude`, which never equalled "claude". The old comment
#     asserted a bare name was verified on this platform; that only held for the
#     PATH case.
#
# The command is taken as the rest of the line rather than as field 3, because a
# comm can contain spaces: this machine has
# `/Applications/Claude.app/.../Claude Helper (Renderer)` running right now.
#
# Named _has_agent_child rather than _pane_has_agent because ~20 test bodies stub
# it by that name; renaming it in production without them would leave those stubs
# silently inert. Rename when it moves into lib/identity.sh, stubs and all.
_has_agent_child() {
    local pid="$1"
    [[ -n "$pid" ]] || return 1
    ps -eo pid,ppid,comm 2>/dev/null | awk -v p="$pid" -v names="$_AGENT_COMMS" '
        BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
        NR == 1 { next }
        {
            cmd = $0
            sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", cmd)
            sub(/.*\//, "", cmd)
            if (($1 == p || $2 == p) && (cmd in want)) { found = 1; exit }
        }
        END { exit !found }
    '
}

# Identify which agent client a shell's child process is.
# Returns: claude, codex, gemini, deer, or pi.
_agent_client_type() {
    local shell_pid="$1"
    local child_comm
    case "$(uname)" in
        Darwin)
            child_comm=$(ps -eo ppid,comm | awk -v p="$shell_pid" \
                '$1 == p && ($2 == "claude" || $2 == "codex" || $2 == "gemini" || $2 == "deer" || $2 == "deerbox" || $2 == "pi" || $2 == "agy" || $2 == "antigravity") { print $2; exit }') ;;
        *)
            child_comm=$(ps -eo ppid,comm | awk -v p="$shell_pid" \
                '$1 == p && ($2 == "claude" || $2 == "codex" || $2 == "gemini" || $2 == "deer" || $2 == "deerbox" || $2 == "pi" || $2 == "agy" || $2 == "antigravity") { print $2; exit }') ;;
    esac
    case "$child_comm" in
        deer|deerbox) echo "deer" ;;
        codex) echo "codex" ;;
        gemini) echo "gemini" ;;
        pi) echo "pi" ;;
        agy|antigravity) echo "antigravity" ;;
        *) echo "claude" ;;
    esac
}

# ── tmux option helpers ──────────────────────────────────────────────

get_tmux_option() {
    local option="$1" default="${2:-}"
    local value
    value=$(tmux show-option -gqv "$option" 2>/dev/null) || true
    printf '%s' "${value:-$default}"
}

# ── config loading ───────────────────────────────────────────────────

KEYBINDING=""
ITEMS_PER_PAGE=""
KEY_NEXT=""
KEY_PREV=""
KEY_QUIT=""
COLOR_WORKING=""
COLOR_BLOCKED=""
COLOR_IDLE=""
COLOR_COMPLETED=""
SHOW_PROJECT=""
ICON_IDLE=""
ICON_WORKING=""
ICON_COMPLETED=""
ICON_BLOCKED=""
COMPLETED_DELAY=""
DEBUG_LOG=""
HOOK_ON_WORKING=""
HOOK_ON_COMPLETED=""
HOOK_ON_BLOCKED=""
HOOK_ON_IDLE=""
HOOK_ON_TRANSITION=""
_HAS_HOOKS=""

load_config() {
    local cache="${TRACKER_DIR:-$HOME/.tmux-agent-tracker}/config_cache"

    # Use cache if fresh (< 60s) — shared across all hook invocations
    if [[ -f "$cache" ]]; then
        local age now
        now=$(date +%s)
        age=$(( now - $(_file_mtime "$cache" 2>/dev/null || echo 0) ))
        if [[ "$age" -lt 60 ]]; then
            source "$cache"
            return
        fi
    fi

    KEYBINDING=$(get_tmux_option "@agent-tracker-keybinding" "a")
    ITEMS_PER_PAGE=$(get_tmux_option "@agent-tracker-items-per-page" "10")
    KEY_NEXT=$(get_tmux_option "@agent-tracker-key-next" "i")
    KEY_PREV=$(get_tmux_option "@agent-tracker-key-prev" "o")
    KEY_QUIT=$(get_tmux_option "@agent-tracker-key-quit" "q")
    COLOR_WORKING=$(get_tmux_option "@agent-tracker-color-working" "black")
    COLOR_BLOCKED=$(get_tmux_option "@agent-tracker-color-blocked" "black")
    COLOR_IDLE=$(get_tmux_option "@agent-tracker-color-idle" "black")
    COLOR_COMPLETED=$(get_tmux_option "@agent-tracker-color-completed" "black")
    SHOW_PROJECT=$(get_tmux_option "@agent-tracker-show-project" "0")
    MAX_NAME_LENGTH=$(get_tmux_option "@agent-tracker-max-name-length" "40")
    ICON_IDLE=$(get_tmux_option "@agent-tracker-icon-idle" ".")
    ICON_WORKING=$(get_tmux_option "@agent-tracker-icon-working" "*")
    ICON_COMPLETED=$(get_tmux_option "@agent-tracker-icon-completed" "+")
    ICON_BLOCKED=$(get_tmux_option "@agent-tracker-icon-blocked" "!")
    COMPLETED_DELAY=$(get_tmux_option "@agent-tracker-completed-delay" "3")
    DEBUG_LOG=$(get_tmux_option "@agent-tracker-debug-log" "0")
    HOOK_ON_WORKING=$(get_tmux_option "@agent-tracker-on-working" "")
    HOOK_ON_COMPLETED=$(get_tmux_option "@agent-tracker-on-completed" "")
    HOOK_ON_BLOCKED=$(get_tmux_option "@agent-tracker-on-blocked" "")
    HOOK_ON_IDLE=$(get_tmux_option "@agent-tracker-on-idle" "")
    HOOK_ON_TRANSITION=$(get_tmux_option "@agent-tracker-on-transition" "")
    if [[ -n "$HOOK_ON_WORKING" || -n "$HOOK_ON_COMPLETED" || -n "$HOOK_ON_BLOCKED" || -n "$HOOK_ON_IDLE" || -n "$HOOK_ON_TRANSITION" ]]; then
        _HAS_HOOKS=1
    else
        _HAS_HOOKS=0
    fi

    # Atomic write — safe for concurrent hook invocations
    cat > "${cache}.tmp" <<EOF
KEYBINDING='$KEYBINDING'
ITEMS_PER_PAGE='$ITEMS_PER_PAGE'
KEY_NEXT='$KEY_NEXT'
KEY_PREV='$KEY_PREV'
KEY_QUIT='$KEY_QUIT'
COLOR_WORKING='$COLOR_WORKING'
COLOR_BLOCKED='$COLOR_BLOCKED'
COLOR_IDLE='$COLOR_IDLE'
COLOR_COMPLETED='$COLOR_COMPLETED'
SHOW_PROJECT='$SHOW_PROJECT'
MAX_NAME_LENGTH='$MAX_NAME_LENGTH'
ICON_IDLE='$ICON_IDLE'
ICON_WORKING='$ICON_WORKING'
ICON_COMPLETED='$ICON_COMPLETED'
ICON_BLOCKED='$ICON_BLOCKED'
COMPLETED_DELAY='$COMPLETED_DELAY'
DEBUG_LOG='$DEBUG_LOG'
HOOK_ON_WORKING='$HOOK_ON_WORKING'
HOOK_ON_COMPLETED='$HOOK_ON_COMPLETED'
HOOK_ON_BLOCKED='$HOOK_ON_BLOCKED'
HOOK_ON_IDLE='$HOOK_ON_IDLE'
HOOK_ON_TRANSITION='$HOOK_ON_TRANSITION'
_HAS_HOOKS='$_HAS_HOOKS'
EOF
    mv -f "${cache}.tmp" "$cache"
}

# ── version check ────────────────────────────────────────────────────

check_tmux_version() {
    local required="${1:-3.0}"
    local current
    current=$(tmux -V 2>/dev/null | sed 's/[^0-9.]//g') || return 1
    [[ -z "$current" ]] && return 1

    local cur_major cur_minor req_major req_minor
    cur_major="${current%%.*}"
    cur_minor="${current#*.}"; cur_minor="${cur_minor%%.*}"
    req_major="${required%%.*}"
    req_minor="${required#*.}"; req_minor="${req_minor%%.*}"

    if [[ "$cur_major" -gt "$req_major" ]]; then return 0; fi
    if [[ "$cur_major" -eq "$req_major" && "$cur_minor" -ge "$req_minor" ]]; then return 0; fi
    return 1
}

ensure_tmux_version() {
    if ! check_tmux_version "3.0"; then
        echo "tmux-agent-tracker requires tmux 3.0+" >&2
        return 1
    fi
}
