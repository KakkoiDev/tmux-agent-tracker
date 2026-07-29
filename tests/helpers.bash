#!/usr/bin/env bash
# Test helpers — fresh DB + mocked externals for each test

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"

# Per-test temp directory
setup_test_env() {
    # A private sandbox path per run. The production default is a hardcoded
    # /tmp file that cmd_refresh merges into the real database every
    # status-interval, so fixtures written there leak straight into it.
    export TRACKER_SANDBOX_DB="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/sandbox-$$.db"
    export TRACKER_SANDBOX_CACHE="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/sandbox-$$-cache"
    TEST_TMPDIR=$(mktemp -d)
    export TRACKER_DIR="$TEST_TMPDIR"
    export DB="$TRACKER_DIR/tracker.db"
    export CACHE="$TRACKER_DIR/status_cache"

    # Color defaults (normally loaded from tmux options)
    export COLOR_WORKING="black"
    export COLOR_BLOCKED="black"
    export COLOR_IDLE="black"
    export COLOR_COMPLETED="black"
    export TMUX_PANE=""

    # Icon defaults
    export ICON_IDLE="."
    export ICON_WORKING="*"
    export ICON_COMPLETED="+"
    export ICON_BLOCKED="!"

    # Hook defaults (none configured)
    export HOOK_ON_WORKING=""
    export HOOK_ON_COMPLETED=""
    export HOOK_ON_BLOCKED=""
    export HOOK_ON_IDLE=""
    export HOOK_ON_TRANSITION=""
    export _HAS_HOOKS="0"

    # Initialize DB schema (suppress PRAGMA output)
    mkdir -p "$TRACKER_DIR"
    sqlite3 "$DB" <<'SQL' >/dev/null 2>&1
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=100;
CREATE TABLE IF NOT EXISTS sessions (
    session_id    TEXT PRIMARY KEY,
    status        TEXT NOT NULL DEFAULT 'working'
        CHECK(status IN ('working', 'blocked', 'idle', 'completed')),
    cwd           TEXT NOT NULL,
    project_name  TEXT NOT NULL,
    git_branch    TEXT,
    prompt_summary TEXT,
    agent_type    TEXT,
    task_count    INTEGER NOT NULL DEFAULT 0,
    subagent_count INTEGER NOT NULL DEFAULT 0,
    parent_session_id TEXT,
    agent_client  TEXT NOT NULL DEFAULT 'claude',
    tmux_pane     TEXT,
    tmux_target   TEXT,
    started_at    INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at    INTEGER NOT NULL DEFAULT (unixepoch())
);
SQL
}

teardown_test_env() {
    [[ -d "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
    [[ -d "${SANDBOX_DB_DIR:-}" ]] && rm -rf "$SANDBOX_DB_DIR"
    # Clean shared sandbox DB to avoid leftover merge data
    rm -f "$TRACKER_SANDBOX_DB" \
          "$TRACKER_SANDBOX_DB-wal" \
          "$TRACKER_SANDBOX_DB-shm" \
          "$TRACKER_SANDBOX_CACHE" \
          "$TRACKER_SANDBOX_CACHE.tmp"
}

# Direct SQL helper
sql() { printf '.timeout 100\n%s\n' "$*" | sqlite3 "$DB"; }

# Insert a session row directly
insert_session() {
    local sid="$1" status="${2:-working}" pane="${3:-}"
    local updated="${4:-}"
    sql "INSERT INTO sessions (session_id, status, cwd, project_name, tmux_pane)
         VALUES ('$sid', '$status', '/tmp/test', 'test', '$pane');"
    if [[ -n "$updated" ]]; then
        sql "UPDATE sessions SET updated_at=$updated WHERE session_id='$sid';"
    fi
}

# Source tracker functions without executing main
source_tracker_functions() {
    # Override externals before sourcing
    load_config() { true; }
    get_tmux_option() { echo "${2:-}"; }
    tmux() { true; }
    git() { true; }
    # Agent-detection helpers live in helpers.sh, which is not sourced here.
    # Tests asserting a specific client/process state override these locally.
    _has_agent_child() { return 0; }
    _agent_client_type() { echo "claude"; }
    # Platform helper needed by throttle logic
    _file_mtime() {
        case "$(uname)" in
            Darwin) stat -f %m "$1" ;;
            *)      stat -c %Y "$1" ;;
        esac
    }

    # Use awk to strip shebang, set -euo, source line, load_config, and case block
    # Then sed to override path variables with test paths
    eval "$(awk '
        /^#!\/usr\/bin\/env bash/ { next }
        /^set -euo pipefail/ { next }
        /^source / { next }
        /^load_config/ { next }
        /^case "\$\{1:-\}"/, /^esac$/ { next }
        { print }
    ' "$SCRIPTS_DIR/tracker.sh" | \
    sed "s|^TRACKER_DIR=.*|TRACKER_DIR=\"$TRACKER_DIR\"|" | \
    sed "s|^DB=.*|DB=\"$DB\"|" | \
    sed "s|^CACHE=.*|CACHE=\"$CACHE\"|" | \
    sed "s|^SCRIPTS_DIR=.*|SCRIPTS_DIR=\"$SCRIPTS_DIR\"|")"
}

# Enable sandbox mode for testing (call after source_tracker_functions)
enable_sandbox_mode() {
    _SANDBOX=1
    SANDBOX_DB_DIR=$(mktemp -d)
    DB="$SANDBOX_DB_DIR/sandbox-test.db"
    CACHE="$SANDBOX_DB_DIR/sandbox-test-cache"
    # Init sandbox DB
    sqlite3 "$DB" <<'SQL' >/dev/null 2>&1
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=100;
CREATE TABLE IF NOT EXISTS sessions (
    session_id    TEXT PRIMARY KEY,
    status        TEXT NOT NULL DEFAULT 'working'
        CHECK(status IN ('working', 'blocked', 'idle', 'completed')),
    cwd           TEXT NOT NULL,
    project_name  TEXT NOT NULL,
    git_branch    TEXT,
    prompt_summary TEXT,
    agent_type    TEXT,
    task_count    INTEGER NOT NULL DEFAULT 0,
    subagent_count INTEGER NOT NULL DEFAULT 0,
    parent_session_id TEXT,
    agent_client  TEXT NOT NULL DEFAULT 'claude',
    tmux_pane     TEXT,
    tmux_target   TEXT,
    started_at    INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at    INTEGER NOT NULL DEFAULT (unixepoch())
);
SQL
}

# Create a sandbox DB at a given path with sessions
create_sandbox_db() {
    local path="$1"
    sqlite3 "$path" <<'SQL' >/dev/null 2>&1
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=100;
CREATE TABLE IF NOT EXISTS sessions (
    session_id    TEXT PRIMARY KEY,
    status        TEXT NOT NULL DEFAULT 'working'
        CHECK(status IN ('working', 'blocked', 'idle', 'completed')),
    cwd           TEXT NOT NULL,
    project_name  TEXT NOT NULL,
    git_branch    TEXT,
    prompt_summary TEXT,
    agent_type    TEXT,
    task_count    INTEGER NOT NULL DEFAULT 0,
    subagent_count INTEGER NOT NULL DEFAULT 0,
    parent_session_id TEXT,
    agent_client  TEXT NOT NULL DEFAULT 'claude',
    tmux_pane     TEXT,
    tmux_target   TEXT,
    started_at    INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at    INTEGER NOT NULL DEFAULT (unixepoch())
);
SQL
}

# Insert a session into a specific DB
insert_session_into() {
    local db="$1" sid="$2" status="${3:-working}" client="${4:-claude}" pane="${5:-}" updated="${6:-}"
    printf '.timeout 100\n%s\n' \
        "INSERT INTO sessions (session_id, status, cwd, project_name, agent_client, tmux_pane)
         VALUES ('$sid', '$status', '/tmp/test', 'test', '$client', '$pane');" | sqlite3 "$db"
    if [[ -n "$updated" ]]; then
        printf '.timeout 100\n%s\n' \
            "UPDATE sessions SET updated_at=$updated WHERE session_id='$sid';" | sqlite3 "$db"
    fi
}

# Wait for a file to appear (polling, max 2s)
wait_for_file() {
    local f="$1" i=0
    while [[ ! -f "$f" && "$i" -lt 20 ]]; do
        sleep 0.1
        i=$((i + 1))
    done
    [[ -f "$f" ]]
}

# Count sessions by status
count_status() {
    sql "SELECT COUNT(*) FROM sessions WHERE status='$1';"
}

# Get session status
get_status() {
    sql "SELECT status FROM sessions WHERE session_id='$1';"
}

# Total session count
count_sessions() {
    sql "SELECT COUNT(*) FROM sessions;"
}

# Get subagent count for a session
get_subagent_count() {
    sql "SELECT subagent_count FROM sessions WHERE session_id='$1';"
}
