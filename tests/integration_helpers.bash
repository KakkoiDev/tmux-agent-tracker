#!/usr/bin/env bash
# Integration test helpers — real subprocess invocation against isolated tmux server

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRACKER_SH="$PROJECT_ROOT/scripts/tracker.sh"
source "$PROJECT_ROOT/scripts/helpers.sh"
# shellcheck source=./assert.bash
source "$PROJECT_ROOT/tests/assert.bash"

# ── Per-test isolation ───────────────────────────────────────────────

setup_integration() {
    TEST_TMPDIR=$(mktemp -d)
    export TRACKER_DIR="$TEST_TMPDIR/data"
    export DB="$TRACKER_DIR/tracker.db"
    export CACHE="$TRACKER_DIR/status_cache"

    # Config bypass — prevents tmux option queries
    export COLOR_WORKING="black"
    export COLOR_BLOCKED="black"
    export COLOR_IDLE="black"
    export COLOR_COMPLETED="black"
    # No pane by default — avoids eviction logic
    export TMUX_PANE=""

    # Wrapper bin dir — prepended to PATH
    mkdir -p "$TEST_TMPDIR/bin"

    # tmux wrapper — routes all tmux calls to isolated server
    # Use BASHPID for unique socket per bats subshell ($$ is parent PID)
    TMUX_SOCK="test_tracker_${BASHPID:-$$}"
    cat > "$TEST_TMPDIR/bin/tmux" <<WRAPPER
#!/usr/bin/env bash
exec $(command -v tmux) -L "$TMUX_SOCK" "\$@"
WRAPPER
    chmod +x "$TEST_TMPDIR/bin/tmux"

    # pgrep wrapper — always succeeds, prevents _reap_dead from killing test sessions
    cat > "$TEST_TMPDIR/bin/pgrep" <<'WRAPPER'
#!/usr/bin/env bash
exit 0
WRAPPER
    chmod +x "$TEST_TMPDIR/bin/pgrep"

    # git wrapper — returns a fake branch
    cat > "$TEST_TMPDIR/bin/git" <<'WRAPPER'
#!/usr/bin/env bash
if [[ "${1:-}" == "-C" && "${3:-}" == "rev-parse" ]]; then
    echo "test-branch"
    exit 0
fi
exec $(command -v git) "$@"
WRAPPER
    chmod +x "$TEST_TMPDIR/bin/git"

    # Start isolated tmux server with a single session/pane
    $(command -v tmux) -L "$TMUX_SOCK" new-session -d -s test -x 80 -y 24 2>/dev/null || true
    TEST_PANE=$($(command -v tmux) -L "$TMUX_SOCK" display-message -p '#{pane_id}' 2>/dev/null || echo "%0")

    # Initialize DB via tracker.sh subprocess
    env TRACKER_DIR="$TRACKER_DIR" DB="$DB" CACHE="$CACHE" \
        PATH="$TEST_TMPDIR/bin:$PATH" \
        bash "$TRACKER_SH" init >/dev/null 2>&1

    # Leak guard: snapshot production DB session count
    local prod_db="$HOME/.tmux-agent-tracker/tracker.db"
    if [[ -f "$prod_db" ]]; then
        PROD_SESSION_COUNT=$(sqlite3 "$prod_db" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo "-1")
    else
        PROD_SESSION_COUNT="-1"
    fi
    export PROD_SESSION_COUNT
}

teardown_integration() {
    # Leak guard: assert production DB wasn't modified
    local prod_db="$HOME/.tmux-agent-tracker/tracker.db"
    if [[ "${PROD_SESSION_COUNT:-}" != "-1" && -f "$prod_db" ]]; then
        local after
        after=$(sqlite3 "$prod_db" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo "-1")
        if [[ "$after" != "-1" && "$after" -gt "$PROD_SESSION_COUNT" ]]; then
            echo "LEAK GUARD: production DB session count increased from $PROD_SESSION_COUNT to $after" >&2
            return 1
        fi
    fi

    # Kill isolated tmux server and remove its socket file
    if [[ -n "${TMUX_SOCK:-}" ]]; then
        $(command -v tmux) -L "$TMUX_SOCK" kill-server 2>/dev/null || true
        rm -f "/tmp/tmux-$(id -u)/$TMUX_SOCK" 2>/dev/null || true
    fi
    [[ -d "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
}

# ── Hook invocation ──────────────────────────────────────────────────

# fire_hook EVENT JSON — invokes tracker.sh as a real subprocess
fire_hook() {
    local event="$1" json="${2:-{\}}"
    printf '%s' "$json" | env \
        TRACKER_DIR="$TRACKER_DIR" DB="$DB" CACHE="$CACHE" \
        COLOR_WORKING="$COLOR_WORKING" COLOR_BLOCKED="$COLOR_BLOCKED" \
        COLOR_IDLE="$COLOR_IDLE" COLOR_COMPLETED="$COLOR_COMPLETED" \
        TMUX_PANE="" \
        PATH="$TEST_TMPDIR/bin:$PATH" \
        bash "$TRACKER_SH" hook "$event"
}

# fire_hook_with_pane EVENT JSON — sets TMUX_PANE for subagent/pane tests
fire_hook_with_pane() {
    local event="$1" json="${2:-{\}}"
    printf '%s' "$json" | env \
        TRACKER_DIR="$TRACKER_DIR" DB="$DB" CACHE="$CACHE" \
        COLOR_WORKING="$COLOR_WORKING" COLOR_BLOCKED="$COLOR_BLOCKED" \
        COLOR_IDLE="$COLOR_IDLE" COLOR_COMPLETED="$COLOR_COMPLETED" \
        TMUX_PANE="$TEST_PANE" \
        PATH="$TEST_TMPDIR/bin:$PATH" \
        bash "$TRACKER_SH" hook "$event"
}

# run_status_bar — reads status-bar output
run_status_bar() {
    env TRACKER_DIR="$TRACKER_DIR" DB="$DB" CACHE="$CACHE" \
        PATH="$TEST_TMPDIR/bin:$PATH" \
        bash "$TRACKER_SH" status-bar
}

# ── DB helpers ───────────────────────────────────────────────────────

sql() { printf '.timeout 100\n%s\n' "$*" | sqlite3 "$DB"; }

get_status() {
    sql "SELECT status FROM sessions WHERE session_id='$1';"
}

count_sessions() {
    sql "SELECT COUNT(*) FROM sessions;"
}

count_status() {
    sql "SELECT COUNT(*) FROM sessions WHERE status='$1';"
}

read_cache() {
    [[ -f "$CACHE" ]] && cat "$CACHE" || true
}

cache_mtime() {
    [[ -f "$CACHE" ]] && _file_mtime "$CACHE" 2>/dev/null || echo "0"
}

get_subagent_count() {
    sql "SELECT subagent_count FROM sessions WHERE session_id='$1';"
}

# age_session <sid> <seconds> - backdate a session's updated_at.
#
# Required before firing Notification. _hook_notification only blocks a session
# whose updated_at is at least 45s old:
#
#   UPDATE sessions SET status='blocked' ... AND updated_at <= unixepoch() - 45
#
# That guard is deliberate (Notification has a 4-41s upstream delay, and a late
# one must not re-block a session PostToolUse already cleared). A test that fires
# UserPromptSubmit and then Notification back to back therefore matches zero
# rows and the session stays 'working'. Four integration tests backdated only
# *after* the Notification and so silently never reached 'blocked' at all.
age_session() {
    sql "UPDATE sessions SET updated_at = unixepoch() - ${2:-60} WHERE session_id='$1';"
}

# run_init - `tracker.sh init` in the same environment the hooks get.
#
# PATH matters: without the wrapper bin dir, tmux resolves to the real binary and
# _invalidate_stale_panes reads the developer's live server pid instead of the
# test server's, so it sees a pid change on every call and blanks pane ids that
# should have survived.
run_init() {
    env TRACKER_DIR="$TRACKER_DIR" DB="$DB" CACHE="$CACHE" \
        PATH="$TEST_TMPDIR/bin:$PATH" \
        bash "$TRACKER_SH" init >/dev/null 2>&1
}
