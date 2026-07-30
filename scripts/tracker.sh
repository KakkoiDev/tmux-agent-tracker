#!/usr/bin/env bash
set -euo pipefail

# ── source helpers ───────────────────────────────────────────────────

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/helpers.sh"

# Config loaded lazily — only when render or sound is needed
_tracker_dir_was_set=0; [[ -n "${TRACKER_DIR:-}" ]] && _tracker_dir_was_set=1
TRACKER_DIR="${TRACKER_DIR:-$HOME/.tmux-agent-tracker}"
DB="${DB:-$TRACKER_DIR/tracker.db}"
CACHE="${CACHE:-$TRACKER_DIR/status_cache}"

# One-time migration: project renamed tmux-claude-agent-tracker -> tmux-agent-tracker.
# Move the legacy default data dir to the new one, once, on defaults only.
_migrate_legacy_dir() {
    [[ "$_tracker_dir_was_set" -eq 1 ]] && return 0            # explicit override -> never migrate
    [[ "$TRACKER_DIR" == "$HOME/.tmux-agent-tracker" ]] || return 0
    local old="$HOME/.tmux-claude-agent-tracker"
    [[ -d "$old" ]] || return 0                                # nothing to migrate / already done
    [[ -e "$TRACKER_DIR" ]] && return 0                        # never clobber an existing new dir
    mv "$old" "$TRACKER_DIR" 2>/dev/null || return 0           # best-effort; never fail init
}
_migrate_legacy_dir

# -- sandbox fallback ------------------------------------------------
# If TRACKER_DIR is not writable (e.g., deer/deerbox SRT sandbox),
# fall back to /tmp. The host-side tracker keeps the real DB; sandbox
# sessions write to a temp DB that the host merges on refresh.
#
# Detection: attempt a real write probe. Bash's -w only checks
# permission bits, which are unchanged inside macOS sandbox-exec.
# The sandbox intercepts at the syscall level, so -w returns true
# but actual writes fail. A probe write is the only reliable test.
# Overridable so a test suite can use a private path. Previously this was
# hardcoded in three places, including inside cmd_merge_sandbox, which meant a
# test writing fixtures here had them merged into the user's real database by the
# next status-bar refresh. See the note on cmd_merge_sandbox.
SANDBOX_DB="${TRACKER_SANDBOX_DB:-/tmp/tmux-agent-tracker-sandbox.db}"
SANDBOX_CACHE="${TRACKER_SANDBOX_CACHE:-/tmp/tmux-agent-tracker-sandbox-cache}"

_SANDBOX=0
if [[ -d "$TRACKER_DIR" ]]; then
    _probe="$TRACKER_DIR/.sandbox-probe.$$"
    if ! touch "$_probe" 2>/dev/null; then
        _SANDBOX=1
        DB="$SANDBOX_DB"
        CACHE="$SANDBOX_CACHE"
    else
        rm -f "$_probe" 2>/dev/null
    fi
    unset _probe
fi

# TK_DIR is resolved here rather than deferred to load_config the way helpers.sh
# has to: TRACKER_DIR is known by this point, and tk_log keys off TK_DIR, so it
# must not wait for the first config load to find its file.
#
# TK_TMUX_DISABLED is the library's no-op mode, and it is what _tmux was
# hand-rolling. Wiring it once here rather than at each call site means anything
# reaching tmux through the library, including tk_opt, is inert in the sandbox,
# which the old per-call check in _tmux did not cover: it guarded 5 call sites
# while 38 bare `tmux` calls in this file bypassed it entirely.
#
# It is a function purely so a test can drive it; _SANDBOX is decided once, from a
# write probe, and never changes at runtime.
# shellcheck disable=SC2034  # read by tk_tmux in the vendored lib/tmux.sh
_tracker_sandbox_wire() {
    [[ "$_SANDBOX" -eq 1 ]] && TK_TMUX_DISABLED=1
    return 0
}
_tracker_tk_init
_tracker_sandbox_wire

sql() { tk_sql "$DB" "$@"; }
sql_sep() { local s="$1"; shift; tk_sql_sep "$DB" "$s" "$@"; }
sql_esc() { tk_sql_esc "$1"; }
# NOT tk_json_esc: this one folds a newline to a space so a prompt summary stays
# on one line in the status bar, where tk_json_esc emits a literal \n escape.
json_esc() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    printf '%s' "$s"
}

# ── debug logging ────────────────────────────────────────────────────

# tk_log's target is $TK_DIR/debug.log, which is the same path this wrote to.
# Two differences, neither of which anything parses: the line gains a `[debug]`
# level field, and the trim is sampled at ~1 write in 100 instead of running
# `wc -l` on the log for every single line - a fork per log call, on a path that
# fires around 12 times per turn.
_debug_log() {
    [[ "${DEBUG_LOG:-0}" == "1" ]] || return 0
    TK_LOG_LEVEL=debug tk_log debug "$*"
}

# Fast JSON value extraction, in place of jq for simple key lookups.
#
# NOT replaced by lib/json.sh's tk_json, for two reasons measured here. First,
# cmd_hook_generic reads its payload with `read -r payload`, which takes only the
# FIRST LINE, so a pretty-printed payload arrives as `{` and no extractor of any
# kind can recover it; swapping in jq would turn a wrong-but-quiet result into a
# parse failure without fixing anything. Second, the identical-looking function in
# tmux-agent-resumer turned out to depend on this being depth-blind: a substring
# slice finds a nested key, and `.text` does not. Fixing the payload read is
# D-15's job, and the swap belongs with it.
_json_val() {
    local _t="${1#*\"$2\":\"}"
    [[ "$_t" == "$1" ]] && return
    printf '%s' "${_t%%\"*}"
}

# Render SQL fragment — used by combined hook+render and standalone _render_cache
_RENDER_SQL="SELECT
    COALESCE(SUM(CASE WHEN status='working' THEN 1 ELSE 0 END),0) || '|' ||
    COALESCE(SUM(CASE WHEN status='blocked' THEN 1 ELSE 0 END),0) || '|' ||
    COALESCE(SUM(CASE WHEN status='idle' THEN 1 ELSE 0 END),0) || '|' ||
    COALESCE(SUM(CASE WHEN status='completed' AND task_count > 0 THEN task_count WHEN status='completed' THEN 1 ELSE 0 END),0) || '|' ||
    COALESCE((SELECT (unixepoch()-MIN(updated_at))/60 FROM sessions
              WHERE status='blocked' AND COALESCE(agent_type,'')='' AND parent_session_id IS NULL),0)
    FROM sessions WHERE COALESCE(agent_type,'')='' AND parent_session_id IS NULL"

_tmux() { tk_tmux "$@"; }

_fire_transition_hook() {
    local from="$1" to="$2" sid="$3" project="$4" summary="${5:-}"
    [[ "${_HAS_HOOKS:-0}" == "0" ]] && return 0
    local hook_var="HOOK_ON_$(printf '%s' "$to" | tr '[:lower:]' '[:upper:]')"
    local cmd="${!hook_var:-}"
    [[ -n "$cmd" ]] && (eval "$cmd" "$from" "$to" "$sid" "$project" "$summary" &) 2>/dev/null
    [[ -n "${HOOK_ON_TRANSITION:-}" ]] && (eval "$HOOK_ON_TRANSITION" "$from" "$to" "$sid" "$project" "$summary" &) 2>/dev/null
    return 0
}

# Additive migrations, each behind a marker file so it runs once.
#
# ADDING A COLUMN: add a `.schema_vN` block below with ALTER TABLE ... ADD COLUMN.
#
# CHANGING A CHECK CONSTRAINT: sqlite cannot alter one in place, and this is what
# `DROP TABLE IF EXISTS sessions` in cmd_init used to be for. Do NOT bring that
# back; use the standard sqlite table rebuild, which preserves the rows:
#
#   ALTER TABLE sessions RENAME TO sessions_old;
#   CREATE TABLE sessions ( ... new constraint ... );
#   INSERT INTO sessions SELECT <columns> FROM sessions_old;
#   DROP TABLE sessions_old;
#
# all inside one sqlite3 invocation behind a `.schema_vN` marker. No such rebuild
# is shipped today because none is needed: the constraint in cmd_init's CREATE is
# byte-identical to the one in every existing database, verified against a live
# one. Shipping an unused ladder would be code that has never run.
_ensure_schema() {
    [[ -f "$DB" ]] || return 0
    if [[ ! -f "$TRACKER_DIR/.schema_v2" ]]; then
        sql "ALTER TABLE sessions ADD COLUMN subagent_count INTEGER NOT NULL DEFAULT 0;" 2>/dev/null || true
        touch "$TRACKER_DIR/.schema_v2"
    fi
    if [[ ! -f "$TRACKER_DIR/.schema_v3" ]]; then
        # parent_session_id links subagent sessions to their parent agent session
        # Used to exclude subagents from status bar counts
        sql "ALTER TABLE sessions ADD COLUMN parent_session_id TEXT;" 2>/dev/null || true
        touch "$TRACKER_DIR/.schema_v3"
    fi
    if [[ ! -f "$TRACKER_DIR/.schema_v4" ]]; then
        sql "ALTER TABLE sessions ADD COLUMN agent_client TEXT NOT NULL DEFAULT 'claude';" 2>/dev/null || true
        touch "$TRACKER_DIR/.schema_v4"
    fi
}

_session_client() {
    local sid="$1"
    local client
    client=$(sql "SELECT COALESCE(agent_client,'claude') FROM sessions WHERE session_id='$(sql_esc "$sid")';" 2>/dev/null || true)
    printf '%s' "${client:-claude}"
}

_map_codex_event() {
    local ntype="$1"
    case "$ntype" in
        *permission*|*approval*|*consent*) echo "PermissionRequest" ;;
        *complete*|*completed*|*finish*|*finished*|*done*) echo "Stop" ;;
        *start*|*started*|*begin*|*began*|*resume*|*resumed*) echo "PostToolUse" ;;
        *fail*|*failed*|*error*|*reject*|*denied*) echo "PostToolUseFailure" ;;
        *) echo "PostToolUse" ;;
    esac
}

# ── init ──────────────────────────────────────────────────────────────

cmd_init() {
    if [[ "$_SANDBOX" -eq 1 ]]; then
        # Init sandbox DB in /tmp (writable in SRT sandbox)
        # IF NOT EXISTS: multiple deerbox instances share this DB
        sqlite3 "$DB" <<'SQL'
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
        echo "Initialized sandbox DB: $DB"
        return
    fi
    mkdir -p "$TRACKER_DIR"

    # CREATE IF NOT EXISTS, never DROP.
    #
    # This used to be `DROP TABLE IF EXISTS sessions; CREATE TABLE ...`, on the
    # grounds that "sessions are ephemeral, re-init is safe". That was true when
    # the table only held recomputable state. It is not true now: prompt_summary
    # and task_count are written once by a hook and never resent.
    #
    # agent-tracker.tmux runs `tracker.sh init` on every tmux server start, and
    # ~/.tmux.conf binds prefix+r to `source-file ~/.tmux.conf`. So every config
    # reload silently wiped every live agent's row mid-session, and the status
    # badge reset to zeros with agents still working.
    #
    # The DROP did provide one real protection, and it is preserved rather than
    # lost: pane ids are meaningless across a server restart, because tmux
    # renumbers panes from %0. _invalidate_stale_panes handles that without
    # destroying anything else.
    #
    # The DROP also served CHECK-constraint upgrades. No rebuild ships today
    # because none is needed: the constraint below is byte-identical to the one
    # in every existing database. _ensure_schema documents the rebuild procedure
    # for when that changes.
    sqlite3 "$DB" <<'SQL'
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
    _ensure_schema
    _invalidate_stale_panes
    echo "Initialized: $DB"
}

# A pane id is only meaningful for the tmux server that issued it: a restarted
# server hands out %0 again, so a stored %7 can resolve to an unrelated pane and
# `goto` would jump somewhere arbitrary. Blank the pane columns when the server
# pid changes, and keep everything a hook cannot resend.
#
# This is the protection the old DROP TABLE gave, without the data loss.
_invalidate_stale_panes() {
    local marker="$TRACKER_DIR/.tmux_server_pid" now prev
    now=$(tmux display-message -p '#{pid}' 2>/dev/null || true)
    [[ -n "$now" ]] || return 0
    prev=$(cat "$marker" 2>/dev/null || true)
    if [[ "$prev" != "$now" ]]; then
        if [[ -n "$prev" ]]; then
            sql "UPDATE sessions SET tmux_pane='', tmux_target='';" 2>/dev/null || true
            _debug_log "tmux server changed ($prev -> $now); cleared stale pane ids"
        fi
        printf '%s' "$now" > "$marker" 2>/dev/null || true
    fi
    return 0
}

# ── hook ──────────────────────────────────────────────────────────────

cmd_hook() {
    # Auto-init sandbox DB on first hook
    if [[ "$_SANDBOX" -eq 1 ]] && [[ ! -f "$DB" ]]; then
        cmd_init
    fi
    [[ -f "$DB" ]] || return 0
    [[ "$_SANDBOX" -eq 0 ]] && _ensure_schema
    _load_config_fast
    local event="$1"
    local json
    read -r json || true
    [[ -z "$json" ]] && json='{}'

    local sid raw_sid
    raw_sid=$(_json_val "$json" "session_id")
    [[ -z "$raw_sid" ]] && raw_sid=$(_json_val "$json" "conversationId")
    [[ -z "$raw_sid" ]] && raw_sid=$(_json_val "$json" "conversation_id")
    [[ -z "$raw_sid" ]] && return 0
    sid=$(sql_esc "$raw_sid")

    _debug_log "HOOK $event sid=$raw_sid client=$(_session_client "$raw_sid")"

    # _ensure_session only for session-creating hooks.
    # Hot-path hooks (PostToolUse, PostToolUseFailure, Notification, PermissionRequest, Stop, StopFailure, Elicitation, ElicitationResult, TeammateIdle) skip this
    # - their UPDATEs are no-ops if session doesn't exist yet.
    # SessionStart creates as idle; UserPromptSubmit creates as working.
    case "$event" in
        SessionStart|UserPromptSubmit)
            local _client
            _client=$(_detect_agent_client "$raw_sid")
            local _init_status="working"
            [[ "$event" == "SessionStart" ]] && _init_status="idle"
            _ensure_session "$sid" "$json" "$_init_status" "$_client" ;;
    esac

    local __changed=1 __render="" __json="$json" __old_status="" __teammate_sid=""
    case "$event" in
        SessionStart)     ;; # _ensure_session already created as idle
        UserPromptSubmit) _hook_prompt "$sid" "$json" ;;
        PostToolUse)      _hook_post_tool "$sid" ;;
        PostToolUseFailure) _hook_post_tool "$sid" ;;
        Stop)             _hook_stop "$sid" ;;
        StopFailure)      _hook_stop "$sid" ;;
        Notification)     _hook_notification "$sid" ;;
        PermissionRequest) _hook_permission_request "$sid" ;;
        Elicitation)      _hook_permission_request "$sid" ;;
        ElicitationResult) _hook_post_tool "$sid" ;;
        TaskCompleted)    _hook_task_completed "$sid" ;;
        SessionEnd)       sql "DELETE FROM sessions WHERE session_id='$sid';" ;;
        TeammateIdle)     _hook_teammate_idle "$json" ;;
        SubagentStart)
            local _agent_id _agent_type
            _agent_id=$(_json_val "$json" "agent_id")
            _agent_type=$(_json_val "$json" "agent_type")
            sql "UPDATE sessions SET subagent_count = subagent_count + 1
                 WHERE session_id='$sid';"
            # Mark the subagent's session as child of this parent
            if [[ -n "$_agent_id" ]]; then
                sql "INSERT OR IGNORE INTO sessions (session_id, parent_session_id, status, updated_at)
                     VALUES ('$(sql_esc "$_agent_id")', '$(sql_esc "$sid")', 'idle', unixepoch());"
            fi
            __changed=0 ;;
        SubagentStop)
            local _agent_id _agent_type
            _agent_id=$(_json_val "$json" "agent_id")
            _agent_type=$(_json_val "$json" "agent_type")
            _hook_subagent_stop "$sid"
            # Clear parent link so subagent row is counted independently
            if [[ -n "$_agent_id" ]]; then
                sql "UPDATE sessions SET parent_session_id=NULL
                     WHERE session_id='$(sql_esc "$_agent_id")';"
            fi
            _debug_log "subagent_stop parent=$sid agent_id=$_agent_id agent_type=$_agent_type" ;;
        *) return 0 ;;
    esac

    # Reap stale sessions on events that create/wake sessions
    # Skip in sandbox - no tmux pane list to cross-reference
    #
    # Note the ordering, which reads as a bug the first time: _ensure_session has
    # already inserted this session's row a few lines above, and _reap_dead can
    # delete it again within the same invocation. That is intended for a pane with
    # no agent running in it, and it is why firing `SessionStart` by hand from a
    # plain shell appears to create no row at all.
    #
    # It is not why real agents went missing. That was _has_agent_child matching
    # only child processes, so a pane whose own process is the harness - which is
    # what tmux-agent-mesh's `dispatch` creates - looked agentless and was reaped
    # ten seconds after starting.
    case "$event" in
        SessionStart|UserPromptSubmit)
            [[ "$_SANDBOX" -eq 0 ]] && _reap_dead 2>/dev/null || true ;;
    esac

    if [[ -n "$__render" ]]; then
        # Fast path: render data already fetched in same sqlite3 call
        _load_config_fast
        _write_cache "$__render" 2>/dev/null || _render_cache 2>/dev/null || true
        _tmux refresh-client -S 2>/dev/null || true
    elif [[ "$__changed" -eq 1 ]]; then
        _render_cache 2>/dev/null || true
        _tmux refresh-client -S 2>/dev/null || true
    fi

    # Fire transition hooks
    if [[ -n "$__old_status" ]]; then
        local _hook_new_status _hook_sid _hook_project
        case "$event" in
            TeammateIdle)
                _hook_new_status="idle"
                _hook_sid="${__teammate_sid:-$sid}"
                ;;
            UserPromptSubmit)
                _hook_new_status="working"
                _hook_sid="$sid"
                ;;
            PostToolUse|PostToolUseFailure|ElicitationResult)
                _hook_new_status="working"
                _hook_sid="$sid"
                ;;
            Stop|StopFailure)
                _hook_new_status="completed"
                _hook_sid="$sid"
                ;;
            Notification|PermissionRequest|Elicitation)
                _hook_new_status="blocked"
                _hook_sid="$sid"
                ;;
            TaskCompleted) _hook_new_status="" ;;
            *) _hook_new_status="" ;;
        esac
        if [[ -n "$_hook_new_status" && "$__old_status" != "$_hook_new_status" ]]; then
            local _hook_project _hook_summary
            _hook_project=$(sql "SELECT project_name FROM sessions WHERE session_id='$(sql_esc "$_hook_sid")';")
            _hook_summary=$(sql "SELECT prompt_summary FROM sessions WHERE session_id='$(sql_esc "$_hook_sid")';")
            _fire_transition_hook "$__old_status" "$_hook_new_status" "$_hook_sid" "$_hook_project" "$_hook_summary"
        fi
    fi
}

# Detect agent client from session_id pattern or process tree.
# pi-hooks sends file paths as session_id (e.g. /Users/user/.pi/sessions/session-abc.jsonl).
# Claude Code uses UUIDs. Fall back to process inspection for pi child detection.
_detect_agent_client() {
    local raw_sid="$1"
    # pi-hooks session_id always contains /.pi/sessions/
    if [[ "$raw_sid" == *"/.pi/sessions/"* ]]; then
        echo "pi"
        return
    fi
    # Sandbox deer detection
    if [[ "$_SANDBOX" -eq 1 ]]; then
        echo "deer"
        return
    fi
    # Process-based detection via current pane
    if [[ -n "${TMUX_PANE:-}" ]]; then
        local _shell_pid
        _shell_pid=$(tmux display-message -t "$TMUX_PANE" -p '#{pane_pid}' 2>/dev/null) || true
        if [[ -n "$_shell_pid" ]]; then
            _agent_client_type "$_shell_pid"
            return
        fi
    fi
    echo "claude"
}

_ensure_session() {
    local sid="$1" json="${2:-}" init_status="${3:-working}" client="${4:-claude}"

    # Fast path: session already registered with pane info — skip git/tmux overhead
    local existing
    existing=$(sql "SELECT 1 FROM sessions WHERE session_id='$sid' AND tmux_pane != '' LIMIT 1;")
    [[ -n "$existing" ]] && return 0

    local cwd project branch pane target atype
    cwd=$(_json_val "$json" "cwd")
    [[ -z "$cwd" ]] && cwd="${PWD}"
    project=$(basename "$cwd")
    branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    pane="${TMUX_PANE:-}"
    target=""
    if [[ -n "$pane" ]]; then
        target=$(_tmux display-message -t "$pane" \
            -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)
    fi

    # Detect worktree sessions via cwd pattern
    atype=""
    if [[ "$cwd" == *"/.claude/worktrees/"* ]]; then
        atype="worktree"
    fi

    # One Claude per pane — evict stale sessions on the same pane.
    # Atomic: DELETE + INSERT in one sqlite3 process to prevent render seeing N-1 sessions.
    if [[ -n "$pane" ]]; then
        sql "DELETE FROM sessions WHERE tmux_pane='$(sql_esc "$pane")' AND session_id!='$sid';
             INSERT OR IGNORE INTO sessions
             (session_id, status, cwd, project_name, git_branch, agent_type, agent_client, tmux_pane, tmux_target)
             VALUES ('$sid', '$init_status',
                     '$(sql_esc "$cwd")', '$(sql_esc "$project")',
                     '$(sql_esc "$branch")', '$(sql_esc "$atype")', '$(sql_esc "$client")',
                     '$(sql_esc "$pane")', '$(sql_esc "$target")');"
    else
        sql "INSERT OR IGNORE INTO sessions
             (session_id, status, cwd, project_name, git_branch, agent_type, agent_client, tmux_pane, tmux_target)
             VALUES ('$sid', '$init_status',
                     '$(sql_esc "$cwd")', '$(sql_esc "$project")',
                     '$(sql_esc "$branch")', '$(sql_esc "$atype")', '$(sql_esc "$client")', '', '');"
    fi

    # Backfill tmux info if missing (session existed but lacked pane data)
    if [[ -n "$pane" ]]; then
        sql "UPDATE sessions SET tmux_pane='$(sql_esc "$pane")',
             tmux_target='$(sql_esc "$target")',
             agent_client='$(sql_esc "$client")'
             WHERE session_id='$sid' AND (tmux_pane IS NULL OR tmux_pane='');"
    fi
    _debug_log "session_ensure sid=$sid path=[$client] $cwd pane=${pane:-none}"
}

cmd_codex_notify() {
    if [[ "$_SANDBOX" -eq 1 ]] && [[ ! -f "$DB" ]]; then
        cmd_init
    fi
    [[ -f "$DB" ]] || return 0
    [[ "$_SANDBOX" -eq 0 ]] && _ensure_schema

    local payload="${2:-}"
    if [[ -z "$payload" ]]; then
        read -r payload || true
    fi
    [[ -z "$payload" ]] && payload='{}'

    local sid ntype cwd event sid_esc synth init_status
    sid=$(_json_val "$payload" "session_id")
    [[ -z "$sid" ]] && sid=$(_json_val "$payload" "conversation_id")
    [[ -z "$sid" ]] && sid=$(_json_val "$payload" "thread_id")
    [[ -z "$sid" ]] && sid=$(_json_val "$payload" "turn_id")
    if [[ -z "$sid" && -n "${TMUX_PANE:-}" ]]; then
        sid="codex-pane-${TMUX_PANE#%}"
    fi
    [[ -z "$sid" ]] && return 0
    sid_esc=$(sql_esc "$sid")

    ntype=$(_json_val "$payload" "type")
    [[ -z "$ntype" ]] && ntype=$(_json_val "$payload" "event")
    cwd=$(_json_val "$payload" "cwd")
    [[ -z "$cwd" ]] && cwd="$PWD"

    event=$(_map_codex_event "$ntype")
    case "$event" in
        Stop|Notification|PermissionRequest) init_status="working" ;;
        *) init_status="idle" ;;
    esac

    # Ensure session exists before dispatching the mapped synthetic hook event.
    synth="{\"session_id\":\"$(json_esc "$sid")\",\"cwd\":\"$(json_esc "$cwd")\"}"
    _ensure_session "$sid_esc" "$synth" "$init_status" "codex"

    if [[ "$event" == "PermissionRequest" ]]; then
        synth="{\"session_id\":\"$(json_esc "$sid")\",\"cwd\":\"$(json_esc "$cwd")\",\"notification_type\":\"permission_prompt\"}"
    fi

    printf '%s' "$synth" | cmd_hook "$event"
    sql "UPDATE sessions SET agent_client='codex', updated_at=unixepoch() WHERE session_id='$sid_esc';"
    _debug_log "codex_notify type=${ntype:-unknown} sid=$sid event=$event path=[codex] $cwd"
}

_hook_prompt() {
    local sid="$1" json="${2:-}"
    __old_status=$(sql "SELECT status FROM sessions WHERE session_id='$sid';")
    _debug_log "prompt sid=$sid old=$__old_status"
    local _prompt
    _prompt=$(_json_val "$json" "prompt")
    if [[ -n "$_prompt" ]]; then
        _prompt="${_prompt:0:80}"
        sql "UPDATE sessions SET status='working', task_count=0, updated_at=unixepoch(),
             prompt_summary='$(sql_esc "$_prompt")'
             WHERE session_id='$sid';"
    else
        sql "UPDATE sessions SET status='working', task_count=0, updated_at=unixepoch()
             WHERE session_id='$sid';"
    fi
}

# Hot path: SELECT old status + UPDATE + render in one sqlite3 call
_hook_post_tool() {
    local sid="$1"
    local _result
    _result=$(sql "SELECT status FROM sessions WHERE session_id='$sid';
         UPDATE sessions SET status='working', updated_at=unixepoch()
         WHERE session_id='$sid' AND status!='working';
         SELECT CASE WHEN changes() = 0 THEN '' ELSE ($_RENDER_SQL) END;")
    # Two output lines when changed: old_status\nrender_data
    # One line when no-op: old_status (empty CASE produces no output)
    if [[ "$_result" == *$'\n'* ]]; then
        __old_status="${_result%%$'\n'*}"
        __render="${_result#*$'\n'}"
    else
        __old_status="$_result"
        __render=""
    fi
    _debug_log "post_tool sid=$sid old=$__old_status changed=$([ -n "$__render" ] && echo y || echo n)"
    if [[ -z "$__render" ]]; then __changed=0; fi
}

_hook_stop() {
    local sid="$1"
    local _info
    _info=$(sql_sep '|' "SELECT status, subagent_count FROM sessions WHERE session_id='$sid';")
    __old_status="${_info%%|*}"
    local _subs="${_info#*|}"
    _subs="${_subs:-0}"
    _debug_log "stop sid=$sid old=$__old_status subagents=$_subs"
    # Don't mark completed while subagents are still running
    if [[ "$_subs" -gt 0 ]]; then
        return 0
    fi
    sql "UPDATE sessions SET status='completed', updated_at=unixepoch()
         WHERE session_id='$sid' AND status IN ('working', 'blocked');"
    # Deferred clear: clear completed only if user is focused on this pane.
    # Avoids the 15-60s wait for cmd_refresh when already watching the agent.
    _load_config_fast
    local delay="${COMPLETED_DELAY:-3}"
    if [[ -n "${TMUX_PANE:-}" && "$delay" -gt 0 ]] 2>/dev/null; then
        _tmux run-shell -b "sleep $delay && $SCRIPTS_DIR/tracker.sh pane-focus-if-active $TMUX_PANE" 2>/dev/null || true
    fi
}

_hook_subagent_stop() {
    local sid="$1"
    local _result
    _result=$(sql_sep '|' "UPDATE sessions SET subagent_count = MAX(0, subagent_count - 1)
         WHERE session_id='$sid';
         SELECT status, subagent_count FROM sessions WHERE session_id='$sid';")
    __old_status="${_result%%|*}"
    local _subs="${_result#*|}"
    _subs="${_subs:-0}"
    # When last subagent finishes and parent is blocked, clear to working
    if [[ "$__old_status" == "blocked" ]]; then
        sql "UPDATE sessions SET status='working', updated_at=unixepoch()
             WHERE session_id='$sid' AND status='blocked';"
    fi
}

# Hot path: SELECT old status + UPDATE + render in one sqlite3 call
# Only permission_prompt and elicitation_dialog should set blocked.
# Other notification types (idle_prompt, auth_success) are not permission waits.
# The hook config matcher should filter to these, but we guard here too.
_hook_notification() {
    local sid="$1"
    local ntype
    ntype=$(_json_val "$__json" "notification_type")
    if [[ -n "$ntype" && "$ntype" != "permission_prompt" && "$ntype" != "elicitation_dialog" && "$ntype" != "ToolPermission" ]]; then
        __changed=0; return 0
    fi
    # Notification has 4-41s upstream delay. PermissionRequest handles
    # immediate blocking for tool permissions. Guard against the race where
    # a late Notification re-blocks a session that PostToolUse already
    # cleared (user approved the permission, agent resumed working/thinking).
    # 45s covers the max Notification delay with margin.
    local _result
    _result=$(sql "SELECT status FROM sessions WHERE session_id='$sid';
         UPDATE sessions SET status='blocked', updated_at=unixepoch()
         WHERE session_id='$sid' AND status = 'working'
         AND updated_at <= unixepoch() - 45;
         SELECT CASE WHEN changes() = 0 THEN '' ELSE ($_RENDER_SQL) END;")
    if [[ "$_result" == *$'\n'* ]]; then
        __old_status="${_result%%$'\n'*}"
        __render="${_result#*$'\n'}"
    else
        __old_status="$_result"
        __render=""
    fi
    _debug_log "notification sid=$sid type=$ntype old=$__old_status changed=$([ -n "$__render" ] && echo y || echo n)"
    if [[ -z "$__render" ]]; then __changed=0; fi
}

# PermissionRequest fires immediately when a permission dialog appears.
# More reliable than Notification (which has 4-41s upstream delay).
_hook_permission_request() {
    local sid="$1"
    local _result
    _result=$(sql "SELECT status FROM sessions WHERE session_id='$sid';
         UPDATE sessions SET status='blocked', updated_at=unixepoch()
         WHERE session_id='$sid' AND status = 'working';
         SELECT CASE WHEN changes() = 0 THEN '' ELSE ($_RENDER_SQL) END;")
    if [[ "$_result" == *$'\n'* ]]; then
        __old_status="${_result%%$'\n'*}"
        __render="${_result#*$'\n'}"
    else
        __old_status="$_result"
        __render=""
    fi
    _debug_log "permission_request sid=$sid old=$__old_status changed=$([ -n "$__render" ] && echo y || echo n)"
    if [[ -z "$__render" ]]; then __changed=0; fi
}

_hook_task_completed() {
    local sid="$1"
    sql "UPDATE sessions SET task_count = task_count + 1, updated_at=unixepoch()
         WHERE session_id='$sid';"
    _debug_log "task_completed sid=$sid"
}

_hook_teammate_idle() {
    local json="$1"
    local tid
    tid=$(_json_val "$json" "teammate_id")
    [[ -z "$tid" ]] && tid=$(_json_val "$json" "session_id")
    [[ -z "$tid" ]] && return 0
    local raw_tid="$tid"
    tid=$(sql_esc "$tid")
    __old_status=$(sql "SELECT status FROM sessions WHERE session_id='$tid';")
    _debug_log "teammate_idle tid=$raw_tid old=$__old_status"
    sql "UPDATE sessions SET status='idle', agent_type='teammate', updated_at=unixepoch()
         WHERE session_id='$tid';"
    __teammate_sid="$raw_tid"
}

# ── render cache ──────────────────────────────────────────────────────

# Fast config: source cache file directly, skip date+stat freshness check.
# Full load_config (with freshness) runs on status-bar/menu paths.
# NG-3. This used to source $TRACKER_DIR/config_cache with no staleness check at
# all, and call load_config only when the file did not exist. So the first hook
# after install wrote the cache and every later read took it verbatim, forever:
# `tmux set -g @agent-tracker-color-idle red` never took effect, and neither did
# any other @agent-tracker-* option, on any machine, ever. The first external
# consumer of the toolkit reported it, and it is the reason tk_config_load exists
# in the shape it does.
#
# load_config is now tk_config_load, which honours the 60s TTL on the fast path,
# validates the cache's provenance before sourcing it, and rebuilds rather than
# reports when it will not parse. So this is just load_config with the
# already-loaded short circuit kept.
#
# The sandbox branch no longer hardcodes a second copy of the defaults. TRACKER_DIR
# is unwritable there and tmux is unreachable, so TK_TMUX_DISABLED makes every
# option read return its spec default with zero forks, which is what the hardcoded
# list was approximating by hand. It had already drifted from the specs once by
# omitting KEYBINDING, ITEMS_PER_PAGE, the three key bindings and SHOW_PROJECT.
_load_config_fast() {
    [[ -n "${COLOR_WORKING:-}" ]] && return 0
    load_config 2>/dev/null || true
}

# Write formatted cache from pre-fetched "w|b|i|c|dur" data
_write_cache() {
    local w b i c dur
    IFS='|' read -r w b i c dur <<< "$1"
    w="${w:-0}"; b="${b:-0}"; i="${i:-0}"; c="${c:-0}"; dur="${dur:-0}"
    local result=""
    result+="#[fg=${COLOR_IDLE}]${i}${ICON_IDLE:-.}#[default] "
    result+="#[fg=${COLOR_WORKING}]${w}${ICON_WORKING:-*}#[default] "
    result+="#[fg=${COLOR_COMPLETED}]${c}${ICON_COMPLETED:-+}#[default] "

    if [[ "$b" -gt 0 ]]; then
        local suffix=""
        if [[ "$dur" -ge 60 ]]; then
            suffix="$((dur / 60))h"
        elif [[ "$dur" -gt 0 ]]; then
            suffix="${dur}m"
        fi
        result+="#[fg=${COLOR_BLOCKED}]${b}${ICON_BLOCKED:-!}${suffix}#[default]"
    else
        result+="#[fg=${COLOR_BLOCKED}]${b}${ICON_BLOCKED:-!}#[default]"
    fi

    if [[ -n "${2:-}" ]]; then
        result+=" @${2}"
    fi

    local final="${result% }"
    printf '%s' "$final" > "$CACHE.tmp"
    mv -f "$CACHE.tmp" "$CACHE"
    # Push to tmux option for instant display via #{@agent-tracker-status}
    # (#{@option} is re-evaluated on refresh-client -S, unlike #() which is cached)
    _tmux set -gq @agent-tracker-status "$final" 2>/dev/null || true
}

_render_cache() {
    [[ -z "${COLOR_WORKING:-}" ]] && { load_config 2>/dev/null || true; }

    local counts
    counts=$(sql_sep '|' "SELECT
        COALESCE(SUM(CASE WHEN status='working' THEN 1 ELSE 0 END),0),
        COALESCE(SUM(CASE WHEN status='blocked' THEN 1 ELSE 0 END),0),
        COALESCE(SUM(CASE WHEN status='idle' THEN 1 ELSE 0 END),0),
        COALESCE(SUM(CASE WHEN status='completed' AND task_count > 0 THEN task_count WHEN status='completed' THEN 1 ELSE 0 END),0),
        COALESCE((SELECT (unixepoch()-MIN(updated_at))/60 FROM sessions
                  WHERE status='blocked' AND COALESCE(agent_type,'')='' AND parent_session_id IS NULL),0)
        FROM sessions WHERE COALESCE(agent_type,'')='' AND parent_session_id IS NULL;") || return 0
    [[ -z "$counts" ]] && counts="0|0|0|0|0"
    _debug_log "render counts=$counts"

    local project=""
    if [[ "${SHOW_PROJECT:-0}" == "1" ]]; then
        project=$(sql "SELECT project_name FROM sessions
                       WHERE COALESCE(agent_type,'')='' AND parent_session_id IS NULL
                       ORDER BY CASE WHEN status='blocked' THEN 0 ELSE 1 END,
                                updated_at DESC LIMIT 1;" 2>/dev/null || true)
    fi
    _write_cache "$counts" "$project"
}

# ── status-bar ────────────────────────────────────────────────────────

cmd_status_bar() {
    [[ -f "$CACHE" ]] && cat "$CACHE"
}

# ── merge sandbox ────────────────────────────────────────────────────

# Import sessions recorded by a sandboxed agent, which cannot write $TRACKER_DIR.
#
# This runs from cmd_refresh, which runs from `#(tracker.sh refresh)` in
# status-right, i.e. every status-interval on a live server. It ATTACHes a file
# under /tmp and copies rows straight into the real database, so the source file
# is a write path into that database for anything that can create it.
#
# Two guards, both learned the hard way. This project's own test suite wrote
# fixtures to the hardcoded path, and a live refresh merged six `deer` test rows
# into the developer's database within fifteen seconds:
#
#   1. The path is overridable (TRACKER_SANDBOX_DB), so tests use a private one.
#   2. Ownership is checked. /tmp is world-writable and shared between users, so
#      an unowned file there must never be trusted enough to ATTACH. `-O` tests
#      ownership by effective UID.
cmd_merge_sandbox() {
    local sandbox_db="$SANDBOX_DB"
    [[ -f "$sandbox_db" ]] || return 0
    if [[ ! -O "$sandbox_db" ]]; then
        _debug_log "merge-sandbox: refusing $sandbox_db, not owned by this user"
        return 0
    fi

    # Import sandbox sessions into host DB.
    # - INSERT OR IGNORE: new sessions from sandbox
    # - UPDATE only when sandbox has newer data (updated_at comparison)
    #   Prevents flicker: host clears completed->idle (advancing updated_at),
    #   merge must not overwrite with stale sandbox completed status.
    local _changed
    _changed=$(sqlite3 "$DB" <<SQL
ATTACH '$sandbox_db' AS sandbox;
INSERT OR IGNORE INTO sessions
    SELECT * FROM sandbox.sessions;
UPDATE sessions SET
    status = s.status,
    cwd = s.cwd,
    project_name = s.project_name,
    git_branch = s.git_branch,
    prompt_summary = s.prompt_summary,
    agent_type = s.agent_type,
    task_count = s.task_count,
    subagent_count = s.subagent_count,
    agent_client = s.agent_client,
    tmux_pane = CASE WHEN s.tmux_pane != '' THEN s.tmux_pane ELSE sessions.tmux_pane END,
    tmux_target = CASE WHEN s.tmux_target != '' THEN s.tmux_target ELSE sessions.tmux_target END,
    updated_at = s.updated_at
FROM sandbox.sessions AS s
WHERE sessions.session_id = s.session_id
  AND s.updated_at > sessions.updated_at;
-- Evict scan-detected duplicates when a real session owns the same pane
DELETE FROM sessions WHERE session_id LIKE 'scan-%'
  AND tmux_pane IN (
    SELECT tmux_pane FROM sessions
    WHERE session_id NOT LIKE 'scan-%' AND tmux_pane IS NOT NULL AND tmux_pane != ''
  );
SELECT total_changes();
DETACH sandbox;
SQL
    )

    # Backfill tmux_target for sessions that have pane but no target
    # (sandbox can't resolve target because tmux socket is inaccessible)
    local _panes
    _panes=$(sql "SELECT session_id, tmux_pane FROM sessions
        WHERE tmux_pane != '' AND (tmux_target IS NULL OR tmux_target='');") || true
    while IFS='|' read -r _msid _mpane; do
        [[ -z "$_msid" ]] && continue
        local _mtarget
        _mtarget=$(tmux display-message -t "$_mpane" \
            -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)
        if [[ -n "$_mtarget" ]]; then
            sql "UPDATE sessions SET tmux_target='$(sql_esc "$_mtarget")'
                 WHERE session_id='$(sql_esc "$_msid")';"
        fi
    done <<< "$_panes"

    if [[ "${_changed:-0}" -gt 0 ]]; then
        _render_cache 2>/dev/null || true
        tmux refresh-client -S 2>/dev/null || true
    fi
}

# ── refresh (periodic, called by #() for blocked timer) ──────────────

cmd_refresh() {
    [[ -f "$DB" ]] || return 0
    _render_cache 2>/dev/null || true
    # Auto-clear completed on focused pane, but only after a grace period
    # so the completed indicator is visible for at least one full refresh cycle.
    # tmux resolves #{pane_id} at run-shell call time, not subprocess context.
    local grace
    grace=$(tmux show-option -gqv status-interval 2>/dev/null) || grace=15
    grace="${grace:-15}"
    local has_stale_completed
    has_stale_completed=$(sql "SELECT 1 FROM sessions WHERE status='completed'
         AND COALESCE(agent_type,'')=''
         AND updated_at <= unixepoch() - $grace LIMIT 1;")
    if [[ -n "$has_stale_completed" ]]; then
        tmux run-shell -b "$SCRIPTS_DIR/tracker.sh pane-focus #{pane_id}" 2>/dev/null || true
    fi
    # Reap exited agents (deerbox sessions, Ctrl+C'd sessions)
    _reap_dead 2>/dev/null || true
    # Detect unregistered agent panes (deerbox hooks can't fire in sandbox)
    cmd_scan 2>/dev/null || true
    # Merge sandbox sessions if any
    cmd_merge_sandbox 2>/dev/null || true
    # No stdout; display comes from #{@agent-tracker-status}
}

# ── menu ──────────────────────────────────────────────────────────────

cmd_menu() {
    [[ -f "$DB" ]] || return 0
    _ensure_schema
    [[ -z "${ITEMS_PER_PAGE:-}" ]] && { load_config 2>/dev/null || true; }

    local page="${1:-1}"
    local items_per_page="${ITEMS_PER_PAGE:-10}"

    # Total count
    local total
    total=$(sql "SELECT COUNT(*) FROM sessions WHERE COALESCE(agent_type,'')='';") || total=0
    [[ "$total" -eq 0 ]] && { tmux display-message "No active AI agents"; return; }

    # Pagination math
    local total_pages=$(( (total + items_per_page - 1) / items_per_page ))
    [[ "$page" -lt 1 ]] && page=1
    [[ "$page" -gt "$total_pages" ]] && page="$total_pages"
    local offset=$(( (page - 1) * items_per_page ))

    local rows
    rows=$(sql_sep '|' "SELECT session_id, status, project_name,
               COALESCE(git_branch,''), COALESCE(tmux_pane,''), COALESCE(agent_client,'claude')
        FROM sessions
        WHERE COALESCE(agent_type,'')=''
        ORDER BY CASE status
            WHEN 'blocked' THEN 0 WHEN 'completed' THEN 1 WHEN 'working' THEN 2 ELSE 3
        END, updated_at DESC
        LIMIT $items_per_page OFFSET $offset;") || true

    local title="AI Agents"
    [[ "$total_pages" -gt 1 ]] && title="AI Agents ($page/$total_pages)"

    local args=(-T "$title")
    while IFS='|' read -r _sid status project branch pane client; do
        [[ -z "$_sid" ]] && continue
        local icon label
        case "$status" in
            blocked)   icon="${ICON_BLOCKED:-!}" ;;
            completed) icon="${ICON_COMPLETED:-+}" ;;
            working)   icon="${ICON_WORKING:-*}" ;;
            *)         icon="${ICON_IDLE:-.}" ;;
        esac

        local name="${project}"
        [[ -n "$branch" ]] && name+="/${branch}"
        local max="${MAX_NAME_LENGTH:-40}"
        if [[ "$max" -gt 0 && "${#name}" -gt "$max" ]]; then
            name="${name:0:$((max - 1))}…"
        fi
        label="${icon} [${client}] ${name}"

        if [[ -n "$pane" ]]; then
            args+=("$label" "" "run-shell '$SCRIPTS_DIR/tracker.sh goto-pane ${pane}'")
        else
            args+=("$label" "" "")
        fi
    done <<< "$rows"

    # Navigation separator and items
    if [[ "$total_pages" -gt 1 ]] || true; then
        args+=("" "" "")  # separator

        if [[ "$page" -gt 1 ]]; then
            args+=("Previous" "${KEY_PREV:-o}" "run-shell '$SCRIPTS_DIR/tracker.sh menu $(( page - 1 ))'")
        fi

        if [[ "$page" -lt "$total_pages" ]]; then
            args+=("Next" "${KEY_NEXT:-i}" "run-shell '$SCRIPTS_DIR/tracker.sh menu $(( page + 1 ))'")
        fi

        args+=("Quit" "${KEY_QUIT:-q}" "")
    fi

    tmux display-menu "${args[@]}"
}

# ── reap dead ─────────────────────────────────────────────────────────

_reap_dead() {
    [[ -f "$DB" ]] || return 0

    local stamp="$TRACKER_DIR/.last_reap"
    if [[ -f "$stamp" ]]; then
        local now age
        now=$(date +%s)
        age=$(( now - $(_file_mtime "$stamp" 2>/dev/null || echo 0) ))
        [[ "$age" -lt 10 ]] && return 0
    fi
    touch "$stamp"

    local pane_info
    pane_info=$(tmux list-panes -a -F '#{pane_id} #{pane_pid}' 2>/dev/null) || return 0

    local alive_panes="" claude_panes=""
    while read -r pane shell_pid; do
        [[ -z "$pane" ]] && continue
        alive_panes+="$pane"$'\n'
        _has_agent_child "$shell_pid" && claude_panes+="$pane"$'\n'
    done <<< "$pane_info"

    local rows changed=0
    rows=$(sql "SELECT session_id, tmux_pane, status FROM sessions
                WHERE tmux_pane IS NOT NULL AND tmux_pane != '';") || return 0
    while IFS='|' read -r sid pane st; do
        [[ -z "$sid" ]] && continue
        # Dead pane → always delete
        if ! printf '%s' "$alive_panes" | grep -qx "$pane"; then
            _debug_log "reap sid=$sid reason=dead_pane"
            sql "DELETE FROM sessions WHERE session_id='$sid';"
            changed=1
        # Live pane, no agent process, not completed -> delete
        # Covers: working/blocked (Ctrl+C), idle (deerbox exited, /exit)
        # Completed excluded: brief display window before auto-clear
        elif [[ "$st" != "completed" ]] \
          && ! printf '%s' "$claude_panes" | grep -qx "$pane"; then
            _debug_log "reap sid=$sid reason=no_agent"
            sql "DELETE FROM sessions WHERE session_id='$sid';"
            changed=1
        fi
    done <<< "$rows"

    # Reap paneless sessions stale for >10 minutes (e.g. leaked test data)
    local paneless_del
    paneless_del=$(sql "DELETE FROM sessions WHERE (tmux_pane IS NULL OR tmux_pane='')
         AND updated_at < unixepoch() - 600; SELECT changes();")
    [[ "${paneless_del:-0}" -gt 0 ]] && changed=1

    if [[ "$changed" -eq 1 ]]; then _render_cache; fi
}

# ── cleanup ───────────────────────────────────────────────────────────

cmd_cleanup() {
    [[ -f "$DB" ]] || return 0

    sql "DELETE FROM sessions WHERE updated_at < unixepoch() - 86400;"

    local alive
    alive=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null || true)

    if [[ -n "$alive" ]]; then
        local rows
        rows=$(sql "SELECT session_id, tmux_pane FROM sessions
                    WHERE tmux_pane IS NOT NULL AND tmux_pane != '';") || true
        while IFS='|' read -r sid pane; do
            [[ -z "$sid" ]] && continue
            if ! printf '%s\n' "$alive" | grep -qx "$pane"; then
                sql "DELETE FROM sessions WHERE session_id='$sid';"
            fi
        done <<< "$rows"
    fi

    _render_cache
    echo "Cleanup complete"
}

# ── scan ──────────────────────────────────────────────────────────────

cmd_scan() {
    [[ -f "$DB" ]] || return 0
    _ensure_schema

    # Throttle: scan at most once every 30 seconds
    local stamp="$TRACKER_DIR/.last_scan"
    if [[ -f "$stamp" ]]; then
        local now age
        now=$(date +%s)
        age=$(( now - $(_file_mtime "$stamp" 2>/dev/null || echo 0) ))
        [[ "$age" -lt 10 ]] && return 0
    fi
    touch "$stamp"

    local changed=0

    # Find tmux panes whose shell has a claude child process
    local pane_ids
    pane_ids=$(tmux list-panes -a -F '#{pane_id} #{pane_pid}' 2>/dev/null) || return 0

    while read -r pane shell_pid; do
        [[ -z "$pane" ]] && continue

        # Check if this shell has a claude child process
        _has_agent_child "$shell_pid" || continue

        # Get pane context
        local cwd project branch target
        cwd=$(tmux display-message -t "$pane" -p '#{pane_current_path}' 2>/dev/null) || continue
        [[ -z "$cwd" ]] && continue
        project=$(basename "$cwd")
        branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
        target=$(tmux display-message -t "$pane" \
            -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)

        # Detect agent client type (claude, codex, gemini, deer)
        local client
        client=$(_agent_client_type "$shell_pid")

        # Atomic conditional insert - avoids TOCTOU race with hook-based registration.
        # If any session already owns this pane, the INSERT is skipped entirely.
        local sid="scan-${pane}"
        sql "INSERT INTO sessions
             (session_id, status, cwd, project_name, git_branch, agent_client, tmux_pane, tmux_target)
             SELECT '$(sql_esc "$sid")', 'idle',
                    '$(sql_esc "$cwd")', '$(sql_esc "$project")',
                    '$(sql_esc "$branch")', '$(sql_esc "$client")', '$(sql_esc "$pane")',
                    '$(sql_esc "$target")'
             WHERE NOT EXISTS (SELECT 1 FROM sessions WHERE tmux_pane='$(sql_esc "$pane")');"
        changed=1
        _debug_log "scan_detect sid=$sid path=[$client] $cwd pane=$pane"
    done <<< "$pane_ids"

    [[ "$changed" -eq 1 ]] && _render_cache
}

# ── goto ──────────────────────────────────────────────────────────────

cmd_goto() {
    local target="$1"
    local sess="${target%%:*}"
    local win="${target%.*}"
    tmux switch-client -t "$sess" 2>/dev/null || true
    tmux select-window -t "$win" 2>/dev/null || true
    tmux select-pane -t "$target" 2>/dev/null || true
    local _goto_sid _goto_project
    _goto_sid=$(sql "SELECT session_id FROM sessions
         WHERE tmux_target='$(sql_esc "$target")' AND status='completed' LIMIT 1;") || true
    if [[ -n "$_goto_sid" ]]; then
        _load_config_fast
        _debug_log "goto target=$target sid=$_goto_sid via=menu"
        sql "UPDATE sessions SET status='idle', updated_at=unixepoch()
             WHERE session_id='$(sql_esc "$_goto_sid")' AND status='completed';" 2>/dev/null || true
        _goto_project=$(sql "SELECT project_name FROM sessions WHERE session_id='$(sql_esc "$_goto_sid")';") || true
        local _goto_summary
        _goto_summary=$(sql "SELECT prompt_summary FROM sessions WHERE session_id='$(sql_esc "$_goto_sid")';") || true
        _fire_transition_hook "completed" "idle" "$_goto_sid" "$_goto_project" "$_goto_summary"
    fi
    _render_cache 2>/dev/null || true
    tmux refresh-client -S 2>/dev/null || true
}

# ── goto-pane (rename-safe: resolve target from stable pane id) ─────────

cmd_goto_pane() {
    local pane="$1"
    [[ -z "$pane" ]] && return 0
    # Resolve the current target from the stable pane id at click time, so a
    # session rename between registration and now cannot send us to a dead name.
    local target
    target=$(tmux display-message -t "$pane" \
        -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)
    if [[ -z "$target" ]]; then
        tmux display-message "Agent pane no longer exists" 2>/dev/null || true
        return 0
    fi
    local sess="${target%%:*}" win="${target%.*}"
    tmux switch-client -t "$sess" 2>/dev/null || true
    tmux select-window -t "$win" 2>/dev/null || true
    tmux select-pane -t "$target" 2>/dev/null || true
    # Clear completed→idle keyed on the stable pane id (mirrors cmd_pane_focus).
    local _gp_sids
    _gp_sids=$(sql "SELECT session_id FROM sessions
         WHERE tmux_pane='$(sql_esc "$pane")' AND status='completed';") || true
    if [[ -n "$_gp_sids" ]]; then
        _load_config_fast
        _debug_log "goto_pane pane=$pane target=$target via=menu"
        sql "UPDATE sessions SET status='idle', updated_at=unixepoch()
             WHERE tmux_pane='$(sql_esc "$pane")' AND status='completed';" 2>/dev/null || true
        while IFS= read -r _gpsid; do
            [[ -z "$_gpsid" ]] && continue
            local _gpproj _gpsum
            _gpproj=$(sql "SELECT project_name FROM sessions WHERE session_id='$(sql_esc "$_gpsid")';") || true
            _gpsum=$(sql "SELECT prompt_summary FROM sessions WHERE session_id='$(sql_esc "$_gpsid")';") || true
            _fire_transition_hook "completed" "idle" "$_gpsid" "$_gpproj" "$_gpsum"
        done <<< "$_gp_sids"
    fi
    _render_cache 2>/dev/null || true
    tmux refresh-client -S 2>/dev/null || true
}

# ── pane-focus ────────────────────────────────────────────────────────

cmd_pane_focus() {
    [[ -f "$DB" ]] || return 0
    local pane_id="$1"
    local _focus_sids
    _focus_sids=$(sql "SELECT session_id FROM sessions
         WHERE tmux_pane='$(sql_esc "$pane_id")' AND status='completed';") || true
    [[ -z "$_focus_sids" ]] && return 0
    _load_config_fast
    _debug_log "pane_focus pane=$pane_id via=focus"
    sql "UPDATE sessions SET status='idle', updated_at=unixepoch()
         WHERE tmux_pane='$(sql_esc "$pane_id")' AND status='completed';"
    while IFS= read -r _fsid; do
        [[ -z "$_fsid" ]] && continue
        _debug_log "pane_focus_clear sid=$_fsid completed->idle"
        local _fproject _fsummary
        _fproject=$(sql "SELECT project_name FROM sessions WHERE session_id='$(sql_esc "$_fsid")';") || true
        _fsummary=$(sql "SELECT prompt_summary FROM sessions WHERE session_id='$(sql_esc "$_fsid")';") || true
        _fire_transition_hook "completed" "idle" "$_fsid" "$_fproject" "$_fsummary"
    done <<< "$_focus_sids"
    _render_cache 2>/dev/null || true
    tmux refresh-client -S 2>/dev/null || true
}

# Like pane-focus, but only clears if the user is actually on this pane.
# Called from deferred Stop hook to avoid clearing completed when user is elsewhere.
cmd_pane_focus_if_active() {
    [[ -f "$DB" ]] || return 0
    local pane_id="$1"
    local active_pane
    active_pane=$(tmux display-message -p '#{pane_id}' 2>/dev/null) || return 0
    if [[ "$active_pane" != "$pane_id" ]]; then
        _load_config_fast
        _debug_log "pane_focus_if_active pane=$pane_id active=$active_pane skip=not_focused"
        return 0
    fi
    _load_config_fast
    _debug_log "pane_focus_if_active pane=$pane_id active=$active_pane via=deferred_timer"
    cmd_pane_focus "$pane_id"
}

# ── main ──────────────────────────────────────────────────────────────

case "${1:-}" in
    init)       cmd_init ;;
    hook)       cmd_hook "${2:?Usage: tracker.sh hook <event>}" ;;
    codex-notify) cmd_codex_notify "${@}" ;;
    status-bar) cmd_status_bar ;;
    refresh)    cmd_refresh ;;
    menu)       tmux display-message "Opening..." 2>/dev/null || true; _reap_dead 2>/dev/null || true; cmd_scan 2>/dev/null || true; cmd_menu "${2:-1}" ;;
    goto)       cmd_goto "${2:?Usage: tracker.sh goto <target>}" ;;
    goto-pane)  cmd_goto_pane "${2:?Usage: tracker.sh goto-pane <pane_id>}" ;;
    pane-focus) cmd_pane_focus "${2:?Usage: tracker.sh pane-focus <pane_id>}" ;;
    pane-focus-if-active) cmd_pane_focus_if_active "${2:?Usage: tracker.sh pane-focus-if-active <pane_id>}" ;;
    scan)       cmd_scan ;;
    cleanup)    cmd_cleanup ;;
    merge-sandbox) cmd_merge_sandbox ;;
    *)          echo "Usage: tracker.sh {init|hook|codex-notify|status-bar|refresh|menu|scan|cleanup|merge-sandbox|goto|goto-pane|pane-focus}" >&2
                exit 1 ;;
esac
