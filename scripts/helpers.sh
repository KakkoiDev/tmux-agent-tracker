#!/usr/bin/env bash
# helpers.sh - a shim over the vendored tmux-toolkit.
#
# _file_mtime, get_tmux_option and check_tmux_version here were byte-identical to
# the copies in tmux-agent-resumer and tmux-agent-mesh (the resumer's file was
# lifted from this one), and load_config was the same cache architecture written
# four times. They now delegate to lib/, so a fix lands once.
#
# The old names are kept: tracker.sh, agent-tracker.tmux and install.sh call them
# at ~90 sites, and renaming those is a separate change from extracting them.
# Every signature and return value is unchanged.
#
# _has_agent_child and _agent_client_type stay local: they belong together in a
# future lib/identity.sh, which is not built yet.

# ── Plugin directory resolution ──────────────────────────────────────

if [[ -z "${AGENT_TRACKER_PLUGIN_DIR:-}" ]]; then
    AGENT_TRACKER_PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
# shellcheck disable=SC2034  # read by tracker.sh and agent-tracker.tmux, which source this file
SCRIPTS_DIR="$AGENT_TRACKER_PLUGIN_DIR/scripts"

# shellcheck source=../lib/toolkit.sh
source "$AGENT_TRACKER_PLUGIN_DIR/lib/toolkit.sh"
tk_require_version 0.2.0

# tk_init is deferred to load_config: tracker.sh sources this file before it
# resolves TRACKER_DIR, so the data dir is not knowable yet at source time.
_tracker_tk_init() { tk_init agent-tracker "${TRACKER_DIR:-$HOME/.tmux-agent-tracker}"; }

# ── platform helpers ──────────────────────────────────────────────────

_file_mtime() { tk_mtime "$1"; }

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

get_tmux_option() { tk_opt "$1" "${2:-}"; }

# ── config loading ───────────────────────────────────────────────────

# Declared so tracker.sh, agent-tracker.tmux and install.sh can read them under
# `set -u` before load_config has run. One `declare` rather than 23 assignments,
# so a single SC2034 directive covers all of them: the writes are invisible to
# the linter because tk_config_load assigns through tk_opt_into, which has to be
# an eval since bash 3.2 has no namerefs.
#
# MAX_NAME_LENGTH was missing from the list this replaces even though
# load_config assigned it, so `set -u` could bite any caller that read it before
# the first load.
# shellcheck disable=SC2034
declare KEYBINDING="" ITEMS_PER_PAGE="" KEY_NEXT="" KEY_PREV="" KEY_QUIT="" \
        COLOR_WORKING="" COLOR_BLOCKED="" COLOR_IDLE="" COLOR_COMPLETED="" \
        SHOW_PROJECT="" MAX_NAME_LENGTH="" ICON_IDLE="" ICON_WORKING="" \
        ICON_COMPLETED="" ICON_BLOCKED="" COMPLETED_DELAY="" DEBUG_LOG="" \
        HOOK_ON_WORKING="" HOOK_ON_COMPLETED="" HOOK_ON_BLOCKED="" \
        HOOK_ON_IDLE="" HOOK_ON_TRANSITION="" _HAS_HOOKS=""

_TRACKER_CONFIG_SPECS=(
    'KEYBINDING:@agent-tracker-keybinding:a'
    'ITEMS_PER_PAGE:@agent-tracker-items-per-page:10'
    'KEY_NEXT:@agent-tracker-key-next:i'
    'KEY_PREV:@agent-tracker-key-prev:o'
    'KEY_QUIT:@agent-tracker-key-quit:q'
    'COLOR_WORKING:@agent-tracker-color-working:black'
    'COLOR_BLOCKED:@agent-tracker-color-blocked:black'
    'COLOR_IDLE:@agent-tracker-color-idle:black'
    'COLOR_COMPLETED:@agent-tracker-color-completed:black'
    'SHOW_PROJECT:@agent-tracker-show-project:0'
    'MAX_NAME_LENGTH:@agent-tracker-max-name-length:40'
    'ICON_IDLE:@agent-tracker-icon-idle:.'
    'ICON_WORKING:@agent-tracker-icon-working:*'
    'ICON_COMPLETED:@agent-tracker-icon-completed:+'
    'ICON_BLOCKED:@agent-tracker-icon-blocked:!'
    'COMPLETED_DELAY:@agent-tracker-completed-delay:3'
    'DEBUG_LOG:@agent-tracker-debug-log:0'
    'HOOK_ON_WORKING:@agent-tracker-on-working:'
    'HOOK_ON_COMPLETED:@agent-tracker-on-completed:'
    'HOOK_ON_BLOCKED:@agent-tracker-on-blocked:'
    'HOOK_ON_IDLE:@agent-tracker-on-idle:'
    'HOOK_ON_TRANSITION:@agent-tracker-on-transition:'
)

load_config() {
    _tracker_tk_init
    tk_config_load agent-tracker 60 "${_TRACKER_CONFIG_SPECS[@]}"
    # Derived, not an option, so it is recomputed on every call instead of being
    # written into the cache. tk_config_load only round-trips the specs, so a
    # cache hit would otherwise leave this empty and _fire_transition_hook would
    # read `${_HAS_HOOKS:-0}` as 0 and silently stop firing user hooks.
    if [[ -n "$HOOK_ON_WORKING$HOOK_ON_COMPLETED$HOOK_ON_BLOCKED$HOOK_ON_IDLE$HOOK_ON_TRANSITION" ]]; then
        _HAS_HOOKS=1
    else
        _HAS_HOOKS=0
    fi
}

# ── version check ────────────────────────────────────────────────────

check_tmux_version() { tk_vers_ge "${1:-3.0}"; }

ensure_tmux_version() { tk_vers_require 3.0 tmux-agent-tracker; }
