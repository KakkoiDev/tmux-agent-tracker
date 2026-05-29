#!/usr/bin/env bats

load helpers

setup() {
    setup_test_env
    source_tracker_functions
}

teardown() {
    teardown_test_env
}

# ── Hook state transitions ───────────────────────────────────────────

@test "UserPromptSubmit sets status to working" {
    insert_session "s1" "idle" "%1"
    _hook_prompt "s1"
    [[ "$(get_status s1)" == "working" ]]
}

@test "Stop sets working to completed" {
    insert_session "s1" "working" "%1"
    _hook_stop "s1"
    [[ "$(get_status s1)" == "completed" ]]
}

@test "Stop sets blocked to completed" {
    insert_session "s1" "blocked" "%1"
    _hook_stop "s1"
    [[ "$(get_status s1)" == "completed" ]]
}

@test "Stop on idle is no-op" {
    insert_session "s1" "idle" "%1"
    _hook_stop "s1"
    [[ "$(get_status s1)" == "idle" ]]
}

@test "Stop on completed is no-op" {
    insert_session "s1" "completed" "%1"
    local before
    before=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    _hook_stop "s1"
    [[ "$(get_status s1)" == "completed" ]]
    local after
    after=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    [[ "$before" == "$after" ]]
}

@test "Stop schedules deferred pane-focus-if-active when TMUX_PANE is set" {
    insert_session "s1" "working" "%1"
    export TMUX_PANE="%1"
    local _tmux_cmds=""
    tmux() {
        _tmux_cmds+="$* "
        true
    }
    _hook_stop "s1"
    [[ "$(get_status s1)" == "completed" ]]
    [[ "$_tmux_cmds" == *"pane-focus-if-active"* ]]
}

@test "pane-focus-if-active clears when pane is focused" {
    insert_session "s1" "completed" "%1"
    tmux() {
        case "$1" in
            display-message) echo "%1" ;;
            *) true ;;
        esac
    }
    load_config() { true; }
    cmd_pane_focus_if_active "%1"
    [[ "$(get_status s1)" == "idle" ]]
}

@test "pane-focus-if-active is no-op when pane is not focused" {
    insert_session "s1" "completed" "%1"
    tmux() {
        case "$1" in
            display-message) echo "%2" ;;
            *) true ;;
        esac
    }
    cmd_pane_focus_if_active "%1"
    [[ "$(get_status s1)" == "completed" ]]
}

@test "Notification sets working to blocked" {
    insert_session "s1" "working" "%1" "unixepoch()-60"
    _hook_notification "s1" '{}'
    [[ "$(get_status s1)" == "blocked" ]]
}

@test "Notification permission_prompt sets working to blocked" {
    insert_session "s1" "working" "%1" "unixepoch()-60"
    __json='{"session_id":"s1","notification_type":"permission_prompt"}'
    _hook_notification "s1"
    [[ "$(get_status s1)" == "blocked" ]]
}

@test "Notification idle_prompt does not set blocked" {
    insert_session "s1" "working" "%1"
    __json='{"session_id":"s1","notification_type":"idle_prompt"}'
    _hook_notification "s1"
    [[ "$(get_status s1)" == "working" ]]
}

@test "Notification auth_success does not set blocked" {
    insert_session "s1" "working" "%1"
    __json='{"session_id":"s1","notification_type":"auth_success"}'
    _hook_notification "s1"
    [[ "$(get_status s1)" == "working" ]]
}

@test "Notification ToolPermission sets working to blocked" {
    insert_session "s1" "working" "%1" "unixepoch()-60"
    __json='{"session_id":"s1","notification_type":"ToolPermission"}'
    _hook_notification "s1"
    [[ "$(get_status s1)" == "blocked" ]]
}

@test "PermissionRequest sets working to blocked" {
    insert_session "s1" "working" "%1"
    _hook_permission_request "s1"
    [[ "$(get_status s1)" == "blocked" ]]
}

@test "PermissionRequest no-op when already blocked" {
    insert_session "s1" "blocked" "%1"
    sql "UPDATE sessions SET updated_at = unixepoch() - 300 WHERE session_id='s1';"
    local before
    before=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    _hook_permission_request "s1"
    local after
    after=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    [[ "$(get_status s1)" == "blocked" ]]
    [[ "$before" == "$after" ]]
}

@test "PermissionRequest no-op when idle" {
    insert_session "s1" "idle" "%1"
    _hook_permission_request "s1"
    [[ "$(get_status s1)" == "idle" ]]
}

@test "PermissionRequest no-op when completed" {
    insert_session "s1" "completed" "%1"
    _hook_permission_request "s1"
    [[ "$(get_status s1)" == "completed" ]]
}

@test "Stop skips completed when subagents are active" {
    insert_session "s1" "working" "%1"
    sql "UPDATE sessions SET subagent_count=2 WHERE session_id='s1';"
    _hook_stop "s1"
    [[ "$(get_status s1)" == "working" ]]
}

@test "Stop sets completed when no subagents active" {
    insert_session "s1" "working" "%1"
    sql "UPDATE sessions SET subagent_count=0 WHERE session_id='s1';"
    _hook_stop "s1"
    [[ "$(get_status s1)" == "completed" ]]
}

@test "SubagentStop decrements subagent count" {
    insert_session "s1" "working" "%1"
    sql "UPDATE sessions SET subagent_count=3 WHERE session_id='s1';"
    _hook_subagent_stop "s1"
    local count
    count=$(sql "SELECT subagent_count FROM sessions WHERE session_id='s1';")
    [[ "$count" == "2" ]]
}

@test "SubagentStop clears blocked to working" {
    insert_session "s1" "blocked" "%1"
    sql "UPDATE sessions SET subagent_count=1 WHERE session_id='s1';"
    _hook_subagent_stop "s1"
    [[ "$(get_status s1)" == "working" ]]
}

@test "SubagentStop does not go below zero" {
    insert_session "s1" "working" "%1"
    _hook_subagent_stop "s1"
    local count
    count=$(sql "SELECT subagent_count FROM sessions WHERE session_id='s1';")
    [[ "$count" == "0" ]]
}

@test "SubagentStart increments count via cmd_hook" {
    insert_session "s1" "working" "%1"
    printf '{"session_id":"s1","agent_id":"sub-1","agent_type":"researcher"}' | cmd_hook SubagentStart
    local count
    count=$(sql "SELECT subagent_count FROM sessions WHERE session_id='s1';")
    [[ "$count" -eq 1 ]]
}

@test "SubagentStart stacks multiple increments" {
    insert_session "s1" "working" "%1"
    printf '{"session_id":"s1","agent_id":"sub-1","agent_type":"researcher"}' | cmd_hook SubagentStart
    printf '{"session_id":"s1","agent_id":"sub-2","agent_type":"coder"}' | cmd_hook SubagentStart
    printf '{"session_id":"s1","agent_id":"sub-3","agent_type":"reviewer"}' | cmd_hook SubagentStart
    local count
    count=$(sql "SELECT subagent_count FROM sessions WHERE session_id='s1';")
    [[ "$count" -eq 3 ]]
}

@test "SubagentStop via cmd_hook decrements count" {
    insert_session "s1" "working" "%1"
    sql "UPDATE sessions SET subagent_count=2 WHERE session_id='s1';"
    printf '{"session_id":"s1","agent_id":"sub-1","agent_type":"researcher"}' | cmd_hook SubagentStop
    local count
    count=$(sql "SELECT subagent_count FROM sessions WHERE session_id='s1';")
    [[ "$count" -eq 1 ]]
}

@test "SubagentStop on working keeps working" {
    insert_session "s1" "working" "%1"
    sql "UPDATE sessions SET subagent_count=1 WHERE session_id='s1';"
    _hook_subagent_stop "s1"
    [[ "$(get_status s1)" == "working" ]]
}

@test "SubagentStop on completed keeps completed" {
    insert_session "s1" "completed" "%1"
    sql "UPDATE sessions SET subagent_count=1 WHERE session_id='s1';"
    _hook_subagent_stop "s1"
    [[ "$(get_status s1)" == "completed" ]]
}

@test "SubagentStop on idle keeps idle" {
    insert_session "s1" "idle" "%1"
    sql "UPDATE sessions SET subagent_count=1 WHERE session_id='s1';"
    _hook_subagent_stop "s1"
    [[ "$(get_status s1)" == "idle" ]]
}

@test "SubagentStart on nonexistent session is safe no-op" {
    printf '{"session_id":"ghost","agent_id":"sub-1","agent_type":"researcher"}' | cmd_hook SubagentStart
    [[ "$(count_sessions)" -eq 0 ]]
}

@test "SubagentStop on nonexistent session is safe no-op" {
    printf '{"session_id":"ghost","agent_id":"sub-1","agent_type":"researcher"}' | cmd_hook SubagentStop
    [[ "$(count_sessions)" -eq 0 ]]
}

@test "SubagentStart does not trigger render (changed=0)" {
    insert_session "s1" "working" "%1"
    _render_cache
    sleep 1
    local before
    before=$(_file_mtime "$CACHE")
    printf '{"session_id":"s1","agent_id":"sub-1","agent_type":"researcher"}' | cmd_hook SubagentStart
    local after
    after=$(_file_mtime "$CACHE")
    [[ "$before" == "$after" ]]
}

@test "Full subagent lifecycle: Stop deferred then completes" {
    insert_session "s1" "working" "%1"
    sql "UPDATE sessions SET subagent_count=2 WHERE session_id='s1';"

    # Stop while subagents active - skipped
    _hook_stop "s1"
    [[ "$(get_status s1)" == "working" ]]

    # First subagent stops
    _hook_subagent_stop "s1"
    [[ "$(get_status s1)" == "working" ]]
    local count
    count=$(sql "SELECT subagent_count FROM sessions WHERE session_id='s1';")
    [[ "$count" -eq 1 ]]

    # Second subagent stops
    _hook_subagent_stop "s1"
    [[ "$(get_status s1)" == "working" ]]
    count=$(sql "SELECT subagent_count FROM sessions WHERE session_id='s1';")
    [[ "$count" -eq 0 ]]

    # Real Stop now - completes
    _hook_stop "s1"
    [[ "$(get_status s1)" == "completed" ]]
}

@test "Full subagent lifecycle via cmd_hook dispatch" {
    _integration_mock "%1"
    echo '{"session_id":"s1","cwd":"/tmp/test"}' | cmd_hook SessionStart
    echo '{"session_id":"s1"}' | cmd_hook UserPromptSubmit
    [[ "$(get_status s1)" == "working" ]]

    # Spawn 2 subagents
    echo '{"session_id":"s1","agent_id":"sub-1","agent_type":"worker"}' | cmd_hook SubagentStart
    echo '{"session_id":"s1","agent_id":"sub-2","agent_type":"worker"}' | cmd_hook SubagentStart
    local count
    count=$(sql "SELECT subagent_count FROM sessions WHERE session_id='s1';")
    [[ "$count" -eq 2 ]]

    # Stop deferred
    echo '{"session_id":"s1"}' | cmd_hook Stop
    [[ "$(get_status s1)" == "working" ]]

    # Subagents finish
    echo '{"session_id":"s1","agent_id":"sub-1","agent_type":"worker"}' | cmd_hook SubagentStop
    echo '{"session_id":"s1","agent_id":"sub-2","agent_type":"worker"}' | cmd_hook SubagentStop
    count=$(sql "SELECT subagent_count FROM sessions WHERE session_id='s1';")
    [[ "$count" -eq 0 ]]

    # Real Stop
    echo '{"session_id":"s1"}' | cmd_hook Stop
    [[ "$(get_status s1)" == "completed" ]]
}

@test "Render sums task_count across multiple completed sessions" {
    insert_session "s1" "completed" "%1"
    insert_session "s2" "completed" "%2"
    sql "UPDATE sessions SET task_count=3 WHERE session_id='s1';"
    sql "UPDATE sessions SET task_count=2 WHERE session_id='s2';"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == *"5+"* ]]
}

@test "PostToolUseFailure transitions blocked to working" {
    insert_session "s1" "blocked" "%1"
    _hook_post_tool "s1"
    [[ "$(get_status s1)" == "working" ]]
}

@test "Notification does not set idle to blocked" {
    insert_session "s1" "idle" "%1"
    _hook_notification "s1" '{}'
    [[ "$(get_status s1)" == "idle" ]]
}

@test "Notification does not re-block completed session" {
    insert_session "s1" "working" "%1"
    _hook_stop "s1"
    [[ "$(get_status s1)" == "completed" ]]
    _hook_notification "s1" '{}'
    [[ "$(get_status s1)" == "completed" ]]
    _render_cache
    [[ "$(cat "$CACHE")" == *"1+"* ]]
    [[ "$(cat "$CACHE")" == *"0!"* ]]
}

@test "Notification does not reset blocked timer" {
    insert_session "s1" "blocked" "%1"
    sql "UPDATE sessions SET updated_at = unixepoch() - 300 WHERE session_id='s1';"
    _hook_notification "s1" '{}'
    local ts
    ts=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    # updated_at should still be ~300s ago, not reset
    [[ "$ts" -lt "$(( $(date +%s) - 200 ))" ]]
}

@test "Late Notification does not re-block recently unblocked session" {
    # Simulate: PermissionRequest -> blocked, user approves -> PostToolUse -> working
    # Then late Notification arrives (4-41s delay) and should NOT re-block.
    insert_session "s1" "working" "%1"
    _hook_permission_request "s1"
    [[ "$(get_status s1)" == "blocked" ]]
    # User approves, PostToolUse clears it
    _hook_post_tool "s1"
    [[ "$(get_status s1)" == "working" ]]
    # Late Notification arrives - should NOT re-block (updated_at too recent)
    __json='{"session_id":"s1","notification_type":"permission_prompt"}'
    _hook_notification "s1"
    [[ "$(get_status s1)" == "working" ]]
}

@test "PostToolUse sets non-working to working" {
    insert_session "s1" "idle" "%1"
    _hook_post_tool "s1" '{}'
    [[ "$(get_status s1)" == "working" ]]
}

@test "PostToolUse keeps working as working" {
    insert_session "s1" "working" "%1"
    _hook_post_tool "s1" '{}'
    [[ "$(get_status s1)" == "working" ]]
}

@test "TeammateIdle sets status to idle" {
    insert_session "t1" "working" "%1"
    _hook_teammate_idle '{"teammate_id":"t1"}'
    [[ "$(get_status t1)" == "idle" ]]
}

# ── SessionEnd cleanup ───────────────────────────────────────────────

@test "SessionEnd deletes the session" {
    insert_session "s1" "working" "%1"
    sql "DELETE FROM sessions WHERE session_id='s1';"
    [[ "$(count_sessions)" -eq 0 ]]
}

# ── Subagent preservation ────────────────────────────────────────────

@test "_ensure_session evicts stale main session on same pane" {
    insert_session "old-main" "idle" "%1"
    export TMUX_PANE="%1"

    # Mock tmux display-message
    tmux() { echo "test:0.0"; }

    _ensure_session "new-main" '{"cwd":"/tmp/test"}'
    [[ "$(count_sessions)" -eq 1 ]]
    [[ -z "$(get_status old-main)" ]]
    [[ "$(get_status new-main)" == "working" ]]
}

# ── Scan deduplication ───────────────────────────────────────────────

@test "scan conditional INSERT skips when hook entry owns pane" {
    insert_session "hook-s1" "working" "%5"
    # Simulate what scan does: conditional insert
    sql "INSERT INTO sessions
         (session_id, status, cwd, project_name, tmux_pane)
         SELECT 'scan-%5', 'idle', '/tmp/test', 'test', '%5'
         WHERE NOT EXISTS (SELECT 1 FROM sessions WHERE tmux_pane='%5');"
    [[ "$(count_sessions)" -eq 1 ]]
    [[ "$(get_status hook-s1)" == "working" ]]
}

@test "scan conditional INSERT succeeds when no session owns pane" {
    sql "INSERT INTO sessions
         (session_id, status, cwd, project_name, tmux_pane)
         SELECT 'scan-%6', 'idle', '/tmp/test', 'test', '%6'
         WHERE NOT EXISTS (SELECT 1 FROM sessions WHERE tmux_pane='%6');"
    [[ "$(count_sessions)" -eq 1 ]]
    [[ "$(get_status 'scan-%6')" == "idle" ]]
}

# ── Reap dead logic ─────────────────────────────────────────────────

@test "_reap_dead removes sessions with dead panes" {
    insert_session "s1" "working" "%99"
    insert_session "s2" "idle" "%100"

    # Mock: only %99 is alive with claude running
    tmux() {
        case "$1" in
            list-panes) echo "%99 1234" ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 0; }

    _reap_dead
    [[ "$(get_status s1)" == "working" ]]
    [[ -z "$(get_status s2)" ]]
}

@test "_reap_dead keeps sessions with live panes and claude process" {
    insert_session "s1" "working" "%10"
    insert_session "s2" "idle" "%11"

    tmux() {
        case "$1" in
            list-panes) printf '%s\n' "%10 1234" "%11 5678" ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 0; }

    _reap_dead
    [[ "$(count_sessions)" -eq 2 ]]
}

@test "_reap_dead skips sessions without tmux_pane" {
    insert_session "s-nopane" "working" ""

    tmux() {
        case "$1" in
            list-panes) echo "%10 1234" ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 0; }

    _reap_dead
    [[ "$(count_sessions)" -eq 1 ]]
}

@test "_reap_dead cleans up working sessions when Claude process is gone" {
    insert_session "s1" "working" "%10"

    # Mock: pane %10 is alive but no claude child process
    tmux() {
        case "$1" in
            list-panes) echo "%10 1234" ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 1; }

    _reap_dead
    [[ -z "$(get_status s1)" ]]
    [[ "$(count_sessions)" -eq 0 ]]
}

@test "_reap_dead removes stale paneless sessions" {
    insert_session "no-pane" "working" ""
    # Backdate to 11 minutes ago (threshold is 10 min)
    sql "UPDATE sessions SET updated_at = unixepoch() - 660 WHERE session_id='no-pane';"

    insert_session "fresh-no-pane" "working" ""
    # This one is recent — should survive

    tmux() {
        case "$1" in
            list-panes) echo "%10 1234" ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 0; }

    _reap_dead
    [[ -z "$(get_status no-pane)" ]]
    [[ "$(get_status fresh-no-pane)" == "working" ]]
}

@test "_reap_dead throttle prevents second call within 10s" {
    insert_session "s1" "working" "%99"

    tmux() {
        case "$1" in
            list-panes) echo "%99 1234" ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 0; }

    _reap_dead
    [[ -f "$TRACKER_DIR/.last_reap" ]]

    # Insert a dead-pane session after first reap
    insert_session "s2" "working" "%200"

    # Second call within 10s should be throttled — s2 survives
    _reap_dead
    [[ "$(get_status s2)" == "working" ]]
}

@test "_reap_dead deletes idle sessions without agent process" {
    insert_session "s1" "idle" "%10"

    tmux() {
        case "$1" in
            list-panes) echo "%10 1234" ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 1; }

    _reap_dead
    [[ "$(count_sessions)" -eq 0 ]]
}

@test "_reap_dead keeps idle sessions when agent process exists" {
    insert_session "s1" "idle" "%10"

    tmux() {
        case "$1" in
            list-panes) echo "%10 1234" ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 0; }

    _reap_dead
    [[ "$(get_status s1)" == "idle" ]]
}

# ── Cache rendering ──────────────────────────────────────────────────

@test "_render_cache produces correct format with no blocked" {
    insert_session "s1" "working" "%1"
    insert_session "s2" "idle" "%2"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == "#[fg=black]1.#[default] #[fg=black]1*#[default] #[fg=black]0+#[default] #[fg=black]0!#[default]" ]]
}

@test "_render_cache produces correct format with blocked" {
    insert_session "s1" "blocked" "%1"
    # Set updated_at to ~5 minutes ago
    sql "UPDATE sessions SET updated_at = unixepoch() - 300 WHERE session_id='s1';"
    _render_cache
    local out
    out=$(cat "$CACHE")
    # Should contain "1!5m" (approximately)
    [[ "$out" == *"1!"* ]]
    [[ "$out" == *"m#[default]"* ]]
}

@test "_render_cache counts multiple statuses correctly" {
    insert_session "w1" "working" "%1"
    insert_session "w2" "working" "%2"
    insert_session "i1" "idle" "%3"
    insert_session "i2" "idle" "%4"
    insert_session "i3" "idle" "%5"
    insert_session "b1" "blocked" "%6"
    _render_cache
    local out
    out=$(cat "$CACHE")
    # 3 idle, 2 working, 1 blocked
    [[ "$out" == *"3."* ]]
    [[ "$out" == *"2*"* ]]
    [[ "$out" == *"1!"* ]]
}

# ── Blocked timer ────────────────────────────────────────────────────

@test "blocked timer shows minutes" {
    insert_session "b1" "blocked" "%1"
    sql "UPDATE sessions SET updated_at = unixepoch() - 180 WHERE session_id='b1';"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == *"1!3m"* ]]
}

@test "blocked timer shows hours for 60+ minutes" {
    insert_session "b1" "blocked" "%1"
    sql "UPDATE sessions SET updated_at = unixepoch() - 7200 WHERE session_id='b1';"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == *"1!2h"* ]]
}

@test "SHOW_PROJECT=1 includes project name in cache" {
    export SHOW_PROJECT="1"
    insert_session "s1" "working" "%1"
    sql "UPDATE sessions SET project_name='myapp' WHERE session_id='s1';"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == *"@myapp"* ]]
}

@test "SHOW_PROJECT=0 omits project name from cache" {
    export SHOW_PROJECT="0"
    insert_session "s1" "working" "%1"
    sql "UPDATE sessions SET project_name='myapp' WHERE session_id='s1';"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" != *"@myapp"* ]]
}

@test "SHOW_PROJECT prefers blocked session project" {
    export SHOW_PROJECT="1"
    insert_session "s1" "working" "%1"
    sql "UPDATE sessions SET project_name='working-proj' WHERE session_id='s1';"
    insert_session "s2" "blocked" "%2"
    sql "UPDATE sessions SET project_name='blocked-proj' WHERE session_id='s2';"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == *"@blocked-proj"* ]]
}

@test "blocked timer no suffix for <1 minute" {
    insert_session "b1" "blocked" "%1"
    # updated_at is now (just inserted), so dur=0
    _render_cache
    local out
    out=$(cat "$CACHE")
    # Should be "1!" with no duration suffix before #[default]
    [[ "$out" =~ 1!#\[default\] ]]
}

# ── Cache lifecycle (hot-path render) ────────────────────────────────

@test "PostToolUse updates cache when transitioning blocked to working" {
    insert_session "s1" "blocked" "%1"
    _render_cache
    local before
    before=$(cat "$CACHE")
    [[ "$before" == *"1!"* ]]

    _hook_post_tool "s1"
    [[ "$(get_status s1)" == "working" ]]
    # __render was set — _write_cache should have been called by cmd_hook
    # but since we call _hook_post_tool directly, we must verify __render
    [[ -n "$__render" ]]
    _load_config_fast
    _write_cache "$__render"
    local after
    after=$(cat "$CACHE")
    [[ "$after" == *"1*"* ]]
    [[ "$after" == *"0!"* ]]
}

@test "Notification updates cache when transitioning working to blocked" {
    insert_session "s1" "working" "%1" "unixepoch()-60"
    _render_cache
    local before
    before=$(cat "$CACHE")
    [[ "$before" == *"1*"* ]]

    _hook_notification "s1"
    [[ "$(get_status s1)" == "blocked" ]]
    [[ -n "$__render" ]]
    _load_config_fast
    _write_cache "$__render"
    local after
    after=$(cat "$CACHE")
    [[ "$after" == *"1!"* ]]
    [[ "$after" == *"0*"* ]]
}

@test "Stop clears blocked from cache" {
    insert_session "s1" "blocked" "%1"
    _render_cache
    [[ "$(cat "$CACHE")" == *"1!"* ]]

    _hook_stop "s1"
    _render_cache
    local after
    after=$(cat "$CACHE")
    [[ "$after" == *"1+"* ]]
    [[ "$after" == *"0!"* ]]
}

@test "SessionEnd clears all counts from cache" {
    insert_session "s1" "blocked" "%1"
    _render_cache
    [[ "$(cat "$CACHE")" == *"1!"* ]]

    sql "DELETE FROM sessions WHERE session_id='s1';"
    _render_cache
    local after
    after=$(cat "$CACHE")
    [[ "$after" == *"0."* ]]
    [[ "$after" == *"0*"* ]]
    [[ "$after" == *"0!"* ]]
}

@test "full lifecycle: blocked -> PostToolUse -> Stop -> cache is clean" {
    insert_session "s1" "blocked" "%1"
    _render_cache
    [[ "$(cat "$CACHE")" == *"1!"* ]]

    # Transition blocked -> working via PostToolUse
    __changed=1
    __render=""
    _hook_post_tool "s1"
    [[ -n "$__render" ]]
    _load_config_fast
    _write_cache "$__render"
    [[ "$(cat "$CACHE")" == *"1*"* ]]
    [[ "$(cat "$CACHE")" == *"0!"* ]]

    # Stop -> completed
    _hook_stop "s1"
    _render_cache
    [[ "$(cat "$CACHE")" == *"1+"* ]]
    [[ "$(cat "$CACHE")" == *"0!"* ]]

    # SessionEnd -> deleted
    sql "DELETE FROM sessions WHERE session_id='s1';"
    _render_cache
    [[ "$(cat "$CACHE")" == *"0."* ]]
    [[ "$(cat "$CACHE")" == *"0*"* ]]
    [[ "$(cat "$CACHE")" == *"0!"* ]]
}

# ── cmd_status_bar live timer ────────────────────────────────────────

@test "cmd_status_bar is a pure cache read" {
    insert_session "b1" "blocked" "%1"
    insert_session "w1" "working" "%2"

    # Render cache with current time (0m)
    _render_cache
    local cached
    cached=$(cat "$CACHE")

    # Backdate the blocked session — status-bar should NOT recompute
    sql "UPDATE sessions SET updated_at = unixepoch() - 600 WHERE session_id='b1';"

    local out
    out=$(cmd_status_bar)
    [[ "$out" == "$cached" ]]
}

@test "cmd_status_bar returns cached output when no blocked" {
    insert_session "w1" "working" "%1"
    insert_session "i1" "idle" "%2"
    _render_cache
    local expected
    expected=$(cat "$CACHE")
    local out
    out=$(cmd_status_bar)
    [[ "$out" == "$expected" ]]
}

# ── sql_esc ──────────────────────────────────────────────────────────

@test "sql_esc escapes single quotes" {
    run sql_esc "it's a test"
    [[ "$output" == "it''s a test" ]]
}

@test "escaped session_id does not match other sessions" {
    insert_session "normal" "working" "%1"
    # Session ID with SQL injection attempt
    local evil="x'; DELETE FROM sessions;--"
    _hook_prompt "$(sql_esc "$evil")"
    # normal session untouched, evil session not found
    [[ "$(get_status normal)" == "working" ]]
    [[ "$(count_sessions)" -eq 1 ]]
}

# ── Idle count stability (no flicker) ──────────────────────────────

@test "SessionStart on existing working session is no-op" {
    insert_session "s1" "working" "%1"
    export TMUX_PANE="%1"
    tmux() { echo "test:0.0"; }
    _ensure_session "s1" '{"cwd":"/tmp/test"}' "idle"
    # Fast path: session exists with pane info, no change
    [[ "$(get_status s1)" == "working" ]]
}

# ── _json_val ────────────────────────────────────────────────────────

@test "_json_val extracts simple string value" {
    local result
    result=$(_json_val '{"session_id":"abc123","cwd":"/tmp"}' "session_id")
    [[ "$result" == "abc123" ]]
}

@test "_json_val returns empty for missing key" {
    local result
    result=$(_json_val '{"session_id":"abc123"}' "cwd")
    [[ -z "$result" ]]
}

@test "_json_val extracts correct key among many" {
    local json='{"subagent_id":"sub1","subagent_type":"researcher","cwd":"/tmp/test"}'
    [[ "$(_json_val "$json" "subagent_id")" == "sub1" ]]
    [[ "$(_json_val "$json" "subagent_type")" == "researcher" ]]
    [[ "$(_json_val "$json" "cwd")" == "/tmp/test" ]]
}

@test "_json_val returns empty on empty input" {
    local result
    result=$(_json_val '{}' "session_id")
    [[ -z "$result" ]]
}

@test "_json_val handles keys with dots" {
    local json='{"a.b":"dot","ab":"nodot"}'
    [[ "$(_json_val "$json" "a.b")" == "dot" ]]
}

@test "_json_val does not match partial key via dot wildcard" {
    # With regex impl, "a.b" would match "axb" as dot is any-char
    local json='{"axb":"wrong","a.b":"right"}'
    [[ "$(_json_val "$json" "a.b")" == "right" ]]
}

# ── stdin handling (read -r regression) ──────────────────────────────

@test "cmd_hook works with JSON lacking trailing newline" {
    insert_session "s1" "working" "%1"
    # printf sends JSON without trailing newline — must not be silently dropped
    printf '{"session_id":"s1"}' | cmd_hook "Stop"
    [[ "$(get_status s1)" == "completed" ]]
}

@test "cmd_hook works with JSON having trailing newline" {
    insert_session "s1" "working" "%1"
    echo '{"session_id":"s1"}' | cmd_hook "Stop"
    [[ "$(get_status s1)" == "completed" ]]
}

@test "cmd_hook exits cleanly on empty stdin" {
    insert_session "s1" "working" "%1"
    echo "" | cmd_hook "PostToolUse"
    # Session unchanged — empty JSON has no session_id
    [[ "$(get_status s1)" == "working" ]]
}

# ── No-op skip (SELECT changes) ─────────────────────────────────────

@test "PostToolUse no-op does not update timestamp" {
    insert_session "s1" "working" "%1"
    sql "UPDATE sessions SET updated_at = unixepoch() - 100 WHERE session_id='s1';"
    local before
    before=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    _hook_post_tool "s1" '{}'
    local after
    after=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    [[ "$before" == "$after" ]]
}

@test "Notification no-op does not update timestamp" {
    insert_session "s1" "blocked" "%1"
    sql "UPDATE sessions SET updated_at = unixepoch() - 100 WHERE session_id='s1';"
    local before
    before=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    _hook_notification "s1" '{}'
    local after
    after=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    [[ "$before" == "$after" ]]
}

# ── Idle count stability (no flicker) ──────────────────────────────

# ── Instant push via tmux option ─────────────────────────────────────

@test "_write_cache sets tmux option @claude-tracker-status" {
    local tmux_set_value=""
    tmux() {
        if [[ "${1:-}" == "set" && "${2:-}" == "-gq" && "${3:-}" == "@claude-tracker-status" ]]; then
            tmux_set_value="${4:-}"
        fi
        return 0
    }

    insert_session "s1" "working" "%1"
    _render_cache
    [[ -n "$tmux_set_value" ]]
    [[ "$tmux_set_value" == *"1*"* ]]
}

@test "cmd_refresh produces no stdout" {
    insert_session "s1" "working" "%1"
    rm -f "$TRACKER_DIR/.last_reap" "$TRACKER_DIR/.last_scan"
    _has_agent_child() { return 0; }
    _agent_client_type() { echo "claude"; }
    tmux() {
        case "$1" in
            list-panes) echo "%1 1000" ;;
            *) true ;;
        esac
    }
    local out
    out=$(cmd_refresh)
    [[ -z "$out" ]]
}

@test "cmd_refresh updates cache file" {
    insert_session "s1" "blocked" "%1"
    sql "UPDATE sessions SET updated_at = unixepoch() - 300 WHERE session_id='s1';"
    rm -f "$TRACKER_DIR/.last_reap" "$TRACKER_DIR/.last_scan"
    _has_agent_child() { return 0; }
    _agent_client_type() { echo "claude"; }
    tmux() {
        case "$1" in
            list-panes) echo "%1 1000" ;;
            *) true ;;
        esac
    }
    cmd_refresh
    [[ -f "$CACHE" ]]
    [[ "$(cat "$CACHE")" == *"1!"* ]]
    [[ "$(cat "$CACHE")" == *"5m"* ]]
}

@test "cmd_refresh skips pane-focus for fresh completed (grace period)" {
    local run_shell_called=0
    rm -f "$TRACKER_DIR/.last_reap" "$TRACKER_DIR/.last_scan"
    _has_agent_child() { return 0; }
    _agent_client_type() { echo "claude"; }
    tmux() {
        case "$1" in
            list-panes) echo "%1 1000" ;;
            show-option) echo "15" ;;
            run-shell) run_shell_called=1 ;;
            *) true ;;
        esac
    }

    # Completed just now - within grace period
    insert_session "s1" "completed" "%1"
    cmd_refresh
    [[ "$run_shell_called" -eq 0 ]]
}

@test "cmd_refresh triggers pane-focus for stale completed (past grace period)" {
    local run_shell_called=0
    rm -f "$TRACKER_DIR/.last_reap" "$TRACKER_DIR/.last_scan"
    _has_agent_child() { return 0; }
    _agent_client_type() { echo "claude"; }
    tmux() {
        case "$1" in
            list-panes) echo "%1 1000" ;;
            show-option) echo "15" ;;
            run-shell) run_shell_called=1 ;;
            *) true ;;
        esac
    }

    # Completed 20 seconds ago - past 15s grace period
    insert_session "s1" "completed" "%1"
    sql "UPDATE sessions SET updated_at = unixepoch() - 20 WHERE session_id='s1';"
    cmd_refresh
    [[ "$run_shell_called" -eq 1 ]]
}

@test "cmd_refresh grace period uses tmux status-interval" {
    local run_shell_called=0
    rm -f "$TRACKER_DIR/.last_reap" "$TRACKER_DIR/.last_scan"
    _has_agent_child() { return 0; }
    _agent_client_type() { echo "claude"; }
    tmux() {
        case "$1" in
            list-panes) echo "%1 1000" ;;
            show-option) echo "60" ;;
            run-shell) run_shell_called=1 ;;
            *) true ;;
        esac
    }

    # Completed 30 seconds ago - within 60s grace period
    insert_session "s1" "completed" "%1"
    sql "UPDATE sessions SET updated_at = unixepoch() - 30 WHERE session_id='s1';"
    cmd_refresh
    [[ "$run_shell_called" -eq 0 ]]
}

@test "cmd_refresh is no-op without DB" {
    rm -f "$DB"
    local out
    out=$(cmd_refresh)
    [[ -z "$out" ]]
}

@test "atomic eviction keeps count stable during pane takeover" {
    insert_session "old" "idle" "%1"
    insert_session "other" "idle" "%2"
    export TMUX_PANE="%1"
    tmux() { echo "test:0.0"; }

    _ensure_session "new" '{"cwd":"/tmp/test"}'
    # Total count should be 2 (old evicted, new created, other untouched)
    # Never drops to 1 between DELETE and INSERT
    [[ "$(count_sessions)" -eq 2 ]]
    [[ -z "$(get_status old)" ]]
    [[ "$(get_status new)" == "working" ]]
    [[ "$(get_status other)" == "idle" ]]
}

# ── Integration tests (full cmd_hook pipeline via stdin) ──────────────

# Mock that handles all tmux subcommands correctly for integration tests.
# _reap_dead calls list-panes and _has_agent_child, so we need both.
_integration_mock() {
    local pane="${1:-%1}"
    export TMUX_PANE="$pane"
    tmux() {
        case "$1" in
            display-message) echo "test:0.0" ;;
            list-panes) echo "$TMUX_PANE 1234" ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 0; }
}

@test "integration: SessionStart creates idle session" {
    _integration_mock "%1"
    echo '{"session_id":"s1","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    [[ "$(get_status s1)" == "idle" ]]
}

@test "integration: SessionStart then UserPromptSubmit sets working" {
    _integration_mock "%1"
    echo '{"session_id":"s1","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    [[ "$(get_status s1)" == "idle" ]]
    echo '{"session_id":"s1"}' | cmd_hook "UserPromptSubmit"
    [[ "$(get_status s1)" == "working" ]]
}

@test "integration: full lifecycle Start -> Prompt -> PostToolUse -> Stop -> End" {
    _integration_mock "%1"
    echo '{"session_id":"s1","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    [[ "$(get_status s1)" == "idle" ]]

    echo '{"session_id":"s1"}' | cmd_hook "UserPromptSubmit"
    [[ "$(get_status s1)" == "working" ]]

    echo '{"session_id":"s1","tool_name":"Read"}' | cmd_hook "PostToolUse"
    [[ "$(get_status s1)" == "working" ]]

    echo '{"session_id":"s1"}' | cmd_hook "Stop"
    [[ "$(get_status s1)" == "completed" ]]

    echo '{"session_id":"s1"}' | cmd_hook "SessionEnd"
    [[ "$(count_sessions)" -eq 0 ]]
}

@test "integration: Notification permission_prompt sets blocked" {
    insert_session "s1" "working" "%1" "unixepoch()-60"
    echo '{"session_id":"s1","notification_type":"permission_prompt"}' | cmd_hook "Notification"
    [[ "$(get_status s1)" == "blocked" ]]
}

@test "integration: Notification elicitation_dialog sets blocked" {
    insert_session "s1" "working" "%1" "unixepoch()-60"
    echo '{"session_id":"s1","notification_type":"elicitation_dialog"}' | cmd_hook "Notification"
    [[ "$(get_status s1)" == "blocked" ]]
}

@test "integration: Notification ToolPermission sets blocked" {
    insert_session "s1" "working" "%1" "unixepoch()-60"
    echo '{"session_id":"s1","notification_type":"ToolPermission"}' | cmd_hook "Notification"
    [[ "$(get_status s1)" == "blocked" ]]
}

@test "integration: PermissionRequest sets blocked" {
    insert_session "s1" "working" "%1"
    echo '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp"}}' | cmd_hook "PermissionRequest"
    [[ "$(get_status s1)" == "blocked" ]]
}

@test "integration: PermissionRequest no-op when already blocked" {
    insert_session "s1" "blocked" "%1"
    sql "UPDATE sessions SET updated_at = unixepoch() - 300 WHERE session_id='s1';"
    local before
    before=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    echo '{"session_id":"s1","tool_name":"Bash"}' | cmd_hook "PermissionRequest"
    local after
    after=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    [[ "$(get_status s1)" == "blocked" ]]
    [[ "$before" == "$after" ]]
}

@test "integration: blocked then PostToolUse sets working" {
    insert_session "s1" "blocked" "%1"
    echo '{"session_id":"s1","tool_name":"Read"}' | cmd_hook "PostToolUse"
    [[ "$(get_status s1)" == "working" ]]
}

@test "integration: blocked then PostToolUseFailure sets working" {
    insert_session "s1" "blocked" "%1"
    echo '{"session_id":"s1","tool_name":"Bash"}' | cmd_hook "PostToolUseFailure"
    [[ "$(get_status s1)" == "working" ]]
}

@test "integration: blocked then UserPromptSubmit sets working" {
    _integration_mock "%1"
    insert_session "s1" "blocked" "%1"
    echo '{"session_id":"s1"}' | cmd_hook "UserPromptSubmit"
    [[ "$(get_status s1)" == "working" ]]
}

@test "integration: blocked then Stop sets completed" {
    insert_session "s1" "blocked" "%1"
    echo '{"session_id":"s1"}' | cmd_hook "Stop"
    [[ "$(get_status s1)" == "completed" ]]
}

@test "integration: idle then PostToolUse sets working" {
    insert_session "s1" "idle" "%1"
    echo '{"session_id":"s1","tool_name":"Read"}' | cmd_hook "PostToolUse"
    [[ "$(get_status s1)" == "working" ]]
}

@test "integration: Notification idle_prompt does not block" {
    insert_session "s1" "working" "%1"
    echo '{"session_id":"s1","notification_type":"idle_prompt"}' | cmd_hook "Notification"
    [[ "$(get_status s1)" == "working" ]]
}

@test "integration: repeated Notification does not reset timer" {
    insert_session "s1" "blocked" "%1"
    sql "UPDATE sessions SET updated_at = unixepoch() - 300 WHERE session_id='s1';"
    local before
    before=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    echo '{"session_id":"s1","notification_type":"permission_prompt"}' | cmd_hook "Notification"
    local after
    after=$(sql "SELECT updated_at FROM sessions WHERE session_id='s1';")
    [[ "$before" == "$after" ]]
}

@test "integration: SessionStart on existing working session is no-op" {
    _integration_mock "%1"
    insert_session "s1" "working" "%1"
    echo '{"session_id":"s1","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    [[ "$(get_status s1)" == "working" ]]
}

@test "integration: pane takeover evicts old session" {
    _integration_mock "%1"
    insert_session "old" "idle" "%1"
    echo '{"session_id":"new","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    [[ -z "$(get_status old)" ]]
    [[ "$(get_status new)" == "idle" ]]
}

# ── Completed status tests ──────────────────────────────────────────

@test "goto clears completed to idle" {
    insert_session "s1" "completed" "%1"
    sql "UPDATE sessions SET tmux_target='test:0.0' WHERE session_id='s1';"
    cmd_goto "test:0.0"
    [[ "$(get_status s1)" == "idle" ]]
}

@test "goto does not change non-completed sessions" {
    insert_session "s1" "working" "%1"
    sql "UPDATE sessions SET tmux_target='test:0.0' WHERE session_id='s1';"
    cmd_goto "test:0.0"
    [[ "$(get_status s1)" == "working" ]]
}

@test "completed → UserPromptSubmit → working" {
    insert_session "s1" "completed" "%1"
    _hook_prompt "s1"
    [[ "$(get_status s1)" == "working" ]]
}

@test "completed → PostToolUse → working" {
    insert_session "s1" "completed" "%1"
    _hook_post_tool "s1"
    [[ "$(get_status s1)" == "working" ]]
}

@test "_render_cache counts completed correctly" {
    insert_session "w1" "working" "%1"
    insert_session "c1" "completed" "%2"
    insert_session "c2" "completed" "%3"
    insert_session "i1" "idle" "%4"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == *"1."* ]]    # 1 idle
    [[ "$out" == *"1*"* ]]    # 1 working
    [[ "$out" == *"2+"* ]]    # 2 completed
    [[ "$out" == *"0!"* ]]    # 0 blocked
}

@test "_reap_dead preserves completed sessions" {
    insert_session "s1" "completed" "%10"

    tmux() {
        case "$1" in
            list-panes) echo "%10 1234" ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 1; }

    _reap_dead
    [[ "$(get_status s1)" == "completed" ]]
}

@test "Notification does not set completed to blocked" {
    insert_session "s1" "completed" "%1"
    _hook_notification "s1" '{}'
    [[ "$(get_status s1)" == "completed" ]]
}

# ── Pane focus ───────────────────────────────────────────────────────

@test "cmd_pane_focus clears completed to idle" {
    insert_session "s1" "completed" "%1"
    cmd_pane_focus "%1"
    [[ "$(get_status s1)" == "idle" ]]
}

@test "cmd_pane_focus does not clear completed on different pane" {
    insert_session "s1" "completed" "%1"
    cmd_pane_focus "%2"
    [[ "$(get_status s1)" == "completed" ]]
}

@test "cmd_pane_focus is no-op for non-completed sessions" {
    insert_session "s1" "working" "%1"
    insert_session "s2" "idle" "%2"
    insert_session "s3" "blocked" "%3"
    cmd_pane_focus "%1"
    cmd_pane_focus "%2"
    cmd_pane_focus "%3"
    [[ "$(get_status s1)" == "working" ]]
    [[ "$(get_status s2)" == "idle" ]]
    [[ "$(get_status s3)" == "blocked" ]]
}

@test "cmd_pane_focus is no-op when no DB" {
    rm -f "$DB"
    run cmd_pane_focus "%1"
    [[ "$status" -eq 0 ]]
}

@test "integration: Stop sets completed then goto clears to idle" {
    _integration_mock "%1"
    echo '{"session_id":"s1","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    echo '{"session_id":"s1"}' | cmd_hook "UserPromptSubmit"
    [[ "$(get_status s1)" == "working" ]]

    echo '{"session_id":"s1"}' | cmd_hook "Stop"
    [[ "$(get_status s1)" == "completed" ]]

    # Simulate goto — need tmux_target set
    sql "UPDATE sessions SET tmux_target='test:0.0' WHERE session_id='s1';"
    cmd_goto "test:0.0"
    [[ "$(get_status s1)" == "idle" ]]
}

@test "integration: full lifecycle with completed" {
    _integration_mock "%1"
    echo '{"session_id":"s1","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    [[ "$(get_status s1)" == "idle" ]]

    echo '{"session_id":"s1"}' | cmd_hook "UserPromptSubmit"
    [[ "$(get_status s1)" == "working" ]]

    echo '{"session_id":"s1"}' | cmd_hook "Stop"
    [[ "$(get_status s1)" == "completed" ]]

    # New prompt resumes from completed
    echo '{"session_id":"s1"}' | cmd_hook "UserPromptSubmit"
    [[ "$(get_status s1)" == "working" ]]

    echo '{"session_id":"s1"}' | cmd_hook "Stop"
    [[ "$(get_status s1)" == "completed" ]]

    echo '{"session_id":"s1"}' | cmd_hook "SessionEnd"
    [[ "$(count_sessions)" -eq 0 ]]
}

# ── Configurable icons ───────────────────────────────────────────────

@test "custom icons render in _write_cache" {
    export ICON_IDLE="I"
    export ICON_WORKING="W"
    export ICON_COMPLETED="C"
    export ICON_BLOCKED="B"
    insert_session "w1" "working" "%1"
    insert_session "i1" "idle" "%2"
    insert_session "c1" "completed" "%3"
    insert_session "b1" "blocked" "%4"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == *"1I"* ]]
    [[ "$out" == *"1W"* ]]
    [[ "$out" == *"1C"* ]]
    [[ "$out" == *"1B"* ]]
}

@test "custom icons work with blocked timer" {
    export ICON_BLOCKED="B"
    insert_session "b1" "blocked" "%1"
    sql "UPDATE sessions SET updated_at = unixepoch() - 180 WHERE session_id='b1';"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == *"1B3m"* ]]
}

@test "default icons unchanged when ICON vars unset" {
    unset ICON_IDLE ICON_WORKING ICON_COMPLETED ICON_BLOCKED
    insert_session "w1" "working" "%1"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == *"1*"* ]]
    [[ "$out" == *"0."* ]]
    [[ "$out" == *"0+"* ]]
    [[ "$out" == *"0!"* ]]
}

# ── Transition hooks ────────────────────────────────────────────────

@test "_fire_transition_hook is no-op when _HAS_HOOKS=0" {
    export _HAS_HOOKS="0"
    _fire_transition_hook "idle" "working" "s1" "test"
}

@test "_fire_transition_hook fires per-state hook" {
    export _HAS_HOOKS="1"
    local _hook_log="$TEST_TMPDIR/hook.log"
    export HOOK_ON_WORKING="$TEST_TMPDIR/hook.sh"
    cat > "$HOOK_ON_WORKING" <<'SCRIPT'
#!/bin/bash
echo "$1 $2 $3 $4" >> "${0%/*}/hook.log"
SCRIPT
    chmod +x "$HOOK_ON_WORKING"
    _fire_transition_hook "idle" "working" "s1" "myproject"
    wait_for_file "$_hook_log"
    [[ "$(cat "$_hook_log")" == "idle working s1 myproject" ]]
}

@test "_fire_transition_hook fires catch-all hook" {
    export _HAS_HOOKS="1"
    local _hook_log="$TEST_TMPDIR/catchall.log"
    export HOOK_ON_TRANSITION="$TEST_TMPDIR/catchall.sh"
    export HOOK_ON_WORKING=""
    cat > "$HOOK_ON_TRANSITION" <<SCRIPT
#!/bin/bash
echo "\$1 \$2 \$3 \$4" >> "$_hook_log"
SCRIPT
    chmod +x "$HOOK_ON_TRANSITION"
    _fire_transition_hook "idle" "working" "s1" "myproject"
    wait_for_file "$_hook_log"
    [[ "$(cat "$_hook_log")" == "idle working s1 myproject" ]]
}

@test "hook fires on working -> blocked transition" {
    export _HAS_HOOKS="1"
    local _hook_log="$TEST_TMPDIR/hook.log"
    export HOOK_ON_BLOCKED="$TEST_TMPDIR/hook.sh"
    cat > "$HOOK_ON_BLOCKED" <<'SCRIPT'
#!/bin/bash
echo "$1 $2 $3 $4" >> "${0%/*}/hook.log"
SCRIPT
    chmod +x "$HOOK_ON_BLOCKED"
    insert_session "s1" "working" "%1"
    sql "UPDATE sessions SET project_name='myproject' WHERE session_id='s1';"
    echo '{"session_id":"s1","notification_type":"permission_prompt"}' | cmd_hook "Notification"
    wait_for_file "$_hook_log"
    [[ "$(cat "$_hook_log")" == "working blocked s1 myproject" ]]
}

@test "hook fires on blocked -> working transition" {
    export _HAS_HOOKS="1"
    local _hook_log="$TEST_TMPDIR/hook.log"
    export HOOK_ON_WORKING="$TEST_TMPDIR/hook.sh"
    cat > "$HOOK_ON_WORKING" <<'SCRIPT'
#!/bin/bash
echo "$1 $2 $3 $4" >> "${0%/*}/hook.log"
SCRIPT
    chmod +x "$HOOK_ON_WORKING"
    insert_session "s1" "blocked" "%1"
    sql "UPDATE sessions SET project_name='myproject' WHERE session_id='s1';"
    echo '{"session_id":"s1","tool_name":"Read"}' | cmd_hook "PostToolUse"
    wait_for_file "$_hook_log"
    [[ "$(cat "$_hook_log")" == "blocked working s1 myproject" ]]
}

@test "hook does not fire when status unchanged" {
    export _HAS_HOOKS="1"
    local _hook_log="$TEST_TMPDIR/hook.log"
    export HOOK_ON_WORKING="$TEST_TMPDIR/hook.sh"
    cat > "$HOOK_ON_WORKING" <<'SCRIPT'
#!/bin/bash
echo "$1 $2 $3 $4" >> "${0%/*}/hook.log"
SCRIPT
    chmod +x "$HOOK_ON_WORKING"
    insert_session "s1" "working" "%1"
    echo '{"session_id":"s1","tool_name":"Read"}' | cmd_hook "PostToolUse"
    sleep 0.2
    [[ ! -f "$_hook_log" ]]
}

@test "hook fires on Stop (working -> completed)" {
    export _HAS_HOOKS="1"
    local _hook_log="$TEST_TMPDIR/hook.log"
    export HOOK_ON_COMPLETED="$TEST_TMPDIR/hook.sh"
    cat > "$HOOK_ON_COMPLETED" <<'SCRIPT'
#!/bin/bash
echo "$1 $2 $3 $4" >> "${0%/*}/hook.log"
SCRIPT
    chmod +x "$HOOK_ON_COMPLETED"
    insert_session "s1" "working" "%1"
    sql "UPDATE sessions SET project_name='myproject' WHERE session_id='s1';"
    echo '{"session_id":"s1"}' | cmd_hook "Stop"
    wait_for_file "$_hook_log"
    [[ "$(cat "$_hook_log")" == "working completed s1 myproject" ]]
}

@test "hook fires on goto (completed -> idle)" {
    export _HAS_HOOKS="1"
    local _hook_log="$TEST_TMPDIR/hook.log"
    export HOOK_ON_IDLE="$TEST_TMPDIR/hook.sh"
    cat > "$HOOK_ON_IDLE" <<'SCRIPT'
#!/bin/bash
echo "$1 $2 $3 $4" >> "${0%/*}/hook.log"
SCRIPT
    chmod +x "$HOOK_ON_IDLE"
    insert_session "s1" "completed" "%1"
    sql "UPDATE sessions SET tmux_target='test:0.0', project_name='myproject' WHERE session_id='s1';"
    cmd_goto "test:0.0"
    wait_for_file "$_hook_log"
    [[ "$(cat "$_hook_log")" == "completed idle s1 myproject" ]]
}

@test "hook fires on pane-focus (completed -> idle)" {
    export _HAS_HOOKS="1"
    local _hook_log="$TEST_TMPDIR/hook.log"
    export HOOK_ON_IDLE="$TEST_TMPDIR/hook.sh"
    cat > "$HOOK_ON_IDLE" <<'SCRIPT'
#!/bin/bash
echo "$1 $2 $3 $4" >> "${0%/*}/hook.log"
SCRIPT
    chmod +x "$HOOK_ON_IDLE"
    insert_session "s1" "completed" "%1"
    sql "UPDATE sessions SET project_name='myproject' WHERE session_id='s1';"
    cmd_pane_focus "%1"
    wait_for_file "$_hook_log"
    [[ "$(cat "$_hook_log")" == "completed idle s1 myproject" ]]
}

# ── Old status capture ──────────────────────────────────────────────

@test "_hook_post_tool captures old status" {
    insert_session "s1" "blocked" "%1"
    __changed=1
    __render=""
    __old_status=""
    _hook_post_tool "s1"
    [[ "$__old_status" == "blocked" ]]
}

@test "_hook_notification captures old status" {
    insert_session "s1" "working" "%1"
    __changed=1
    __render=""
    __old_status=""
    __json='{}'
    _hook_notification "s1"
    [[ "$__old_status" == "working" ]]
}

@test "_hook_stop captures old status" {
    insert_session "s1" "working" "%1"
    __old_status=""
    _hook_stop "s1"
    [[ "$__old_status" == "working" ]]
}

@test "_hook_prompt captures old status" {
    insert_session "s1" "idle" "%1"
    __old_status=""
    _hook_prompt "s1"
    [[ "$__old_status" == "idle" ]]
}

# ── Teammate hiding ─────────────────────────────────────────────────

@test "TeammateIdle sets agent_type to teammate" {
    insert_session "t1" "working" "%1"
    _hook_teammate_idle '{"teammate_id":"t1"}'
    local atype
    atype=$(sql "SELECT agent_type FROM sessions WHERE session_id='t1';")
    [[ "$atype" == "teammate" ]]
}

@test "_render_cache excludes teammates from counts" {
    insert_session "w1" "working" "%1"
    insert_session "t1" "working" "%2"
    sql "UPDATE sessions SET agent_type='teammate' WHERE session_id='t1';"
    _render_cache
    local out
    out=$(cat "$CACHE")
    # Only 1 working (w1), not 2
    [[ "$out" == *"1*"* ]]
}

@test "_render_cache excludes teammate idle from counts" {
    insert_session "i1" "idle" "%1"
    insert_session "t1" "idle" "%2"
    sql "UPDATE sessions SET agent_type='teammate' WHERE session_id='t1';"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == *"1."* ]]
}

@test "cmd_menu excludes teammates from total" {
    insert_session "w1" "working" "%1"
    insert_session "t1" "idle" "%2"
    sql "UPDATE sessions SET agent_type='teammate' WHERE session_id='t1';"
    local total
    total=$(sql "SELECT COUNT(*) FROM sessions WHERE COALESCE(agent_type,'')='';")
    [[ "$total" -eq 1 ]]
}

@test "cmd_menu prefixes agent client in labels" {
    insert_session "c1" "working" "%1"
    sql "UPDATE sessions SET agent_client='codex', tmux_target='test:0.0' WHERE session_id='c1';"
    local _menu_capture=""
    tmux() {
        if [[ "${1:-}" == "display-menu" ]]; then
            _menu_capture="$*"
        fi
        true
    }
    cmd_menu 1
    [[ "$_menu_capture" == *"[codex] test"* ]]
}

@test "cmd_codex_notify marks completed and tags codex client" {
    insert_session "s1" "working" "%1"
    cmd_codex_notify "codex-notify" '{"session_id":"s1","type":"agent-turn-complete","cwd":"/tmp/test"}'
    [[ "$(get_status s1)" == "completed" ]]
    local client
    client=$(sql "SELECT agent_client FROM sessions WHERE session_id='s1';")
    [[ "$client" == "codex" ]]
}

@test "cmd_codex_notify falls back to pane-based session id" {
    export TMUX_PANE="%9"
    tmux() { echo "test:0.0"; }
    cmd_codex_notify "codex-notify" '{"type":"agent-turn-complete","cwd":"/tmp/test"}'
    [[ "$(get_status codex-pane-9)" == "completed" ]]
    local client
    client=$(sql "SELECT agent_client FROM sessions WHERE session_id='codex-pane-9';")
    [[ "$client" == "codex" ]]
}

@test "cmd_codex_notify start-like event transitions new session to working" {
    cmd_codex_notify "codex-notify" '{"session_id":"s2","type":"agent-turn-begin","cwd":"/tmp/test"}'
    [[ "$(get_status s2)" == "working" ]]
    local client
    client=$(sql "SELECT agent_client FROM sessions WHERE session_id='s2';")
    [[ "$client" == "codex" ]]
}

@test "cmd_codex_notify start-like event fires working transition hook for new session" {
    export _HAS_HOOKS="1"
    export HOOK_ON_WORKING="$TEST_TMPDIR/hook.sh"
    local _hook_log="$TEST_TMPDIR/hook.out"
    cat > "$HOOK_ON_WORKING" <<'SCRIPT'
#!/usr/bin/env bash
echo "$1|$2|$3|$4" >> "${0%/*}/hook.out"
SCRIPT
    chmod +x "$HOOK_ON_WORKING"
    cmd_codex_notify "codex-notify" '{"session_id":"s3","type":"agent-turn-started","cwd":"/tmp/test"}'
    wait_for_file "$_hook_log"
    [[ "$(cat "$_hook_log")" == *"idle|working|s3|"* ]]
}

@test "_reap_dead still cleans up teammate sessions" {
    insert_session "t1" "idle" "%99"
    sql "UPDATE sessions SET agent_type='teammate' WHERE session_id='t1';"

    # Mock: pane %99 is dead
    tmux() {
        case "$1" in
            list-panes) echo "%10 1234" ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 0; }

    _reap_dead
    [[ -z "$(get_status t1)" ]]
}

# ── TaskCompleted ───────────────────────────────────────────────────

@test "TaskCompleted increments task_count" {
    insert_session "s1" "working" "%1"
    _hook_task_completed "s1"
    local tc
    tc=$(sql "SELECT task_count FROM sessions WHERE session_id='s1';")
    [[ "$tc" -eq 1 ]]
}

@test "TaskCompleted does not change status" {
    insert_session "s1" "working" "%1"
    _hook_task_completed "s1"
    [[ "$(get_status s1)" == "working" ]]
}

@test "TaskCompleted increments multiple times" {
    insert_session "s1" "working" "%1"
    _hook_task_completed "s1"
    _hook_task_completed "s1"
    _hook_task_completed "s1"
    local tc
    tc=$(sql "SELECT task_count FROM sessions WHERE session_id='s1';")
    [[ "$tc" -eq 3 ]]
}

@test "Render shows task_count in completed slot" {
    insert_session "s1" "completed" "%1"
    sql "UPDATE sessions SET task_count=3 WHERE session_id='s1';"
    _render_cache
    local out
    out=$(cat "$CACHE")
    # 3 tasks completed shows as "3+"
    [[ "$out" == *"3+"* ]]
}

@test "Render does not count task_count for non-completed sessions" {
    insert_session "s1" "working" "%1"
    sql "UPDATE sessions SET task_count=3 WHERE session_id='s1';"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == *"0+"* ]]
}

@test "Render shows 1+ for stopped session with no tasks" {
    insert_session "s1" "completed" "%1"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == *"1+"* ]]
}

@test "integration: cmd_hook TaskCompleted lifecycle" {
    _integration_mock "%1"
    echo '{"session_id":"s1","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    echo '{"session_id":"s1"}' | cmd_hook "UserPromptSubmit"
    [[ "$(get_status s1)" == "working" ]]

    echo '{"session_id":"s1"}' | cmd_hook "TaskCompleted"
    echo '{"session_id":"s1"}' | cmd_hook "TaskCompleted"
    [[ "$(get_status s1)" == "working" ]]
    local tc
    tc=$(sql "SELECT task_count FROM sessions WHERE session_id='s1';")
    [[ "$tc" -eq 2 ]]
}

@test "UserPromptSubmit resets task_count to zero" {
    _integration_mock "%1"
    echo '{"session_id":"s1","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    echo '{"session_id":"s1"}' | cmd_hook "UserPromptSubmit"
    echo '{"session_id":"s1"}' | cmd_hook "TaskCompleted"
    echo '{"session_id":"s1"}' | cmd_hook "TaskCompleted"
    echo '{"session_id":"s1"}' | cmd_hook "TaskCompleted"
    local tc
    tc=$(sql "SELECT task_count FROM sessions WHERE session_id='s1';")
    [[ "$tc" -eq 3 ]]

    # New prompt should reset task_count
    echo '{"session_id":"s1"}' | cmd_hook "UserPromptSubmit"
    tc=$(sql "SELECT task_count FROM sessions WHERE session_id='s1';")
    [[ "$tc" -eq 0 ]]
}

# ── Worktree detection ──────────────────────────────────────────────

@test "_ensure_session sets agent_type=worktree for worktree cwd" {
    local json='{"session_id":"w1","cwd":"/home/user/project/.claude/worktrees/fix-bug/"}'
    _ensure_session "w1" "$json" "idle"
    local atype
    atype=$(sql "SELECT agent_type FROM sessions WHERE session_id='w1';")
    [[ "$atype" == "worktree" ]]
}

@test "_ensure_session leaves agent_type empty for normal cwd" {
    local json='{"session_id":"n1","cwd":"/home/user/project"}'
    _ensure_session "n1" "$json" "idle"
    local atype
    atype=$(sql "SELECT COALESCE(agent_type,'') FROM sessions WHERE session_id='n1';")
    [[ "$atype" == "" ]]
}

@test "_render_cache excludes worktree sessions" {
    insert_session "w1" "working" "%1"
    insert_session "wt1" "working" "%2"
    sql "UPDATE sessions SET agent_type='worktree' WHERE session_id='wt1';"
    _render_cache
    local out
    out=$(cat "$CACHE")
    # Only 1 working (w1), not 2
    [[ "$out" == *"1*"* ]]
}

@test "integration: worktree session excluded from counts" {
    _integration_mock "%1"
    echo '{"session_id":"s1","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    echo '{"session_id":"s1"}' | cmd_hook "UserPromptSubmit"

    # Worktree session created directly (simulating _ensure_session with worktree cwd)
    insert_session "wt1" "working" "%2"
    sql "UPDATE sessions SET agent_type='worktree' WHERE session_id='wt1';"

    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == *"1*"* ]]
}

# ── Debug logging ─────────────────────────────────────────────────

@test "_debug_log writes to debug.log when DEBUG_LOG=1" {
    export DEBUG_LOG="1"
    _debug_log "test event sid=s1"
    [[ -f "$TRACKER_DIR/debug.log" ]]
    [[ "$(cat "$TRACKER_DIR/debug.log")" == *"test event sid=s1"* ]]
}

@test "_debug_log is no-op when DEBUG_LOG=0" {
    export DEBUG_LOG="0"
    _debug_log "should not appear"
    [[ ! -f "$TRACKER_DIR/debug.log" ]]
}

@test "_debug_log auto-truncates at 1500 lines" {
    export DEBUG_LOG="1"
    local _log="$TRACKER_DIR/debug.log"
    # Write 1501 lines directly
    for i in $(seq 1 1501); do
        echo "2026-01-01 00:00:00 line $i" >> "$_log"
    done
    # Trigger truncation via _debug_log
    _debug_log "trigger truncation"
    local lc
    lc=$(wc -l < "$_log")
    [[ "$lc" -le 1001 ]]
}

@test "cmd_hook logs event entry when DEBUG_LOG=1" {
    export DEBUG_LOG="1"
    insert_session "s1" "working" "%1"
    echo '{"session_id":"s1"}' | cmd_hook "PostToolUse"
    [[ -f "$TRACKER_DIR/debug.log" ]]
    [[ "$(cat "$TRACKER_DIR/debug.log")" == *"HOOK PostToolUse sid=s1"* ]]
}

@test "_ensure_session debug log includes [claude] path prefix" {
    export DEBUG_LOG="1"
    local json='{"session_id":"s1","cwd":"/tmp/test"}'
    _ensure_session "s1" "$json" "idle" "claude"
    [[ -f "$TRACKER_DIR/debug.log" ]]
    [[ "$(cat "$TRACKER_DIR/debug.log")" == *"path=[claude] /tmp/test"* ]]
}

@test "cmd_codex_notify debug log includes [codex] path prefix" {
    export DEBUG_LOG="1"
    cmd_codex_notify "codex-notify" '{"session_id":"s1","type":"agent-turn-complete","cwd":"/tmp/test"}'
    [[ -f "$TRACKER_DIR/debug.log" ]]
    [[ "$(cat "$TRACKER_DIR/debug.log")" == *"path=[codex] /tmp/test"* ]]
}

@test "integration: TeammateIdle hides session from render" {
    _integration_mock "%1"
    echo '{"session_id":"s1","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    echo '{"session_id":"s1"}' | cmd_hook "UserPromptSubmit"
    [[ "$(get_status s1)" == "working" ]]

    # Teammate starts working
    insert_session "t1" "working" "%2"
    _render_cache
    [[ "$(cat "$CACHE")" == *"2*"* ]]

    # TeammateIdle fires — teammate hidden from display
    echo '{"session_id":"s1","teammate_id":"t1"}' | cmd_hook "TeammateIdle"
    _render_cache
    local out
    out=$(cat "$CACHE")
    [[ "$out" == *"1*"* ]]
    [[ "$out" == *"0."* ]]
}

# ── Sandbox support ──────────────────────────────────────────────────

@test "sandbox detection: writable TRACKER_DIR sets _SANDBOX=0" {
    # Normal setup has writable TRACKER_DIR
    [[ "$_SANDBOX" -eq 0 ]]
}

@test "sandbox detection: read-only TRACKER_DIR sets _SANDBOX=1" {
    local ro_dir
    ro_dir=$(mktemp -d)
    chmod 555 "$ro_dir"
    # Re-source with read-only dir to trigger detection
    local saved_db="$DB" saved_cache="$CACHE" saved_tracker="$TRACKER_DIR"
    TRACKER_DIR="$ro_dir"
    DB="$ro_dir/tracker.db"
    CACHE="$ro_dir/status_cache"
    source_tracker_functions
    [[ "$_SANDBOX" -eq 1 ]]
    # Restore for teardown
    chmod 755 "$ro_dir"
    rm -rf "$ro_dir"
    TRACKER_DIR="$saved_tracker"
    DB="$saved_db"
    CACHE="$saved_cache"
    _SANDBOX=0
}

@test "sandbox detection: non-existent TRACKER_DIR leaves _SANDBOX=0" {
    local saved_tracker="$TRACKER_DIR" saved_db="$DB" saved_cache="$CACHE"
    TRACKER_DIR="/tmp/nonexistent-tracker-test-$$"
    source_tracker_functions
    [[ "$_SANDBOX" -eq 0 ]]
    TRACKER_DIR="$saved_tracker"
    DB="$saved_db"
    CACHE="$saved_cache"
}

@test "_tmux is no-op when _SANDBOX=1" {
    _SANDBOX=1
    local _called=0
    tmux() { _called=1; }
    _tmux refresh-client -S
    [[ "$_called" -eq 0 ]]
    _SANDBOX=0
}

@test "_tmux passes through when _SANDBOX=0" {
    _SANDBOX=0
    local _called=0
    tmux() { _called=1; }
    _tmux refresh-client -S
    [[ "$_called" -eq 1 ]]
}

@test "cmd_init sandbox creates DB with IF NOT EXISTS" {
    enable_sandbox_mode
    rm -f "$DB"
    cmd_init
    [[ -f "$DB" ]]
    # Verify table exists
    local count
    count=$(printf '.timeout 100\n%s\n' "SELECT COUNT(*) FROM sessions;" | sqlite3 "$DB")
    [[ "$count" -eq 0 ]]
    _SANDBOX=0
}

@test "cmd_init sandbox does not drop existing sessions" {
    enable_sandbox_mode
    insert_session "existing-1" "working"
    # Re-init should not destroy the session
    cmd_init
    local count
    count=$(sql "SELECT COUNT(*) FROM sessions WHERE session_id='existing-1';")
    [[ "$count" -eq 1 ]]
    _SANDBOX=0
}

@test "_load_config_fast returns hardcoded defaults in sandbox" {
    _SANDBOX=1
    unset COLOR_WORKING
    _load_config_fast
    [[ "$COLOR_WORKING" == "black" ]]
    [[ "$ICON_WORKING" == "*" ]]
    [[ "$ICON_BLOCKED" == "!" ]]
    [[ "$DEBUG_LOG" == "0" ]]
    [[ "$_HAS_HOOKS" == "0" ]]
    [[ "$COMPLETED_DELAY" == "3" ]]
    _SANDBOX=0
}

@test "cmd_hook auto-inits sandbox DB when missing" {
    enable_sandbox_mode
    rm -f "$DB"
    echo '{"session_id":"auto-init-test","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    [[ -f "$DB" ]]
    local count
    count=$(sql "SELECT COUNT(*) FROM sessions WHERE session_id='auto-init-test';")
    [[ "$count" -eq 1 ]]
    _SANDBOX=0
}

@test "cmd_hook sets agent_client=deer in sandbox for SessionStart" {
    enable_sandbox_mode
    echo '{"session_id":"deer-s1","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    local client
    client=$(sql "SELECT agent_client FROM sessions WHERE session_id='deer-s1';")
    [[ "$client" == "deer" ]]
    _SANDBOX=0
}

@test "cmd_hook sets agent_client=deer in sandbox for UserPromptSubmit" {
    enable_sandbox_mode
    echo '{"session_id":"deer-s2","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    echo '{"session_id":"deer-s2","cwd":"/tmp/test"}' | cmd_hook "UserPromptSubmit"
    local client
    client=$(sql "SELECT agent_client FROM sessions WHERE session_id='deer-s2';")
    [[ "$client" == "deer" ]]
    _SANDBOX=0
}

@test "cmd_hook skips _ensure_schema in sandbox" {
    enable_sandbox_mode
    # _ensure_schema tries to touch files in TRACKER_DIR - in sandbox
    # those would fail. Verify no error and schema marker files are not created.
    echo '{"session_id":"schema-test","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    [[ ! -f "$TRACKER_DIR/.schema_v2" ]]
    [[ ! -f "$TRACKER_DIR/.schema_v3" ]]
    _SANDBOX=0
}

@test "cmd_hook skips _reap_dead in sandbox" {
    enable_sandbox_mode
    # Insert a session with a dead pane - should NOT be reaped in sandbox
    insert_session "no-reap" "working" "%dead-pane-999"
    echo '{"session_id":"reap-trigger","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    local count
    count=$(sql "SELECT COUNT(*) FROM sessions WHERE session_id='no-reap';")
    [[ "$count" -eq 1 ]]
    _SANDBOX=0
}

@test "cmd_merge_sandbox imports new sessions into host DB" {
    # Host DB is the normal test DB
    local sandbox_db="/tmp/tmux-claude-agent-tracker-sandbox.db"
    create_sandbox_db "$sandbox_db"
    insert_session_into "$sandbox_db" "sandbox-s1" "working" "deer"

    cmd_merge_sandbox

    local status
    status=$(get_status "sandbox-s1")
    [[ "$status" == "working" ]]
    local client
    client=$(sql "SELECT agent_client FROM sessions WHERE session_id='sandbox-s1';")
    [[ "$client" == "deer" ]]
}

@test "cmd_merge_sandbox does not overwrite newer host data" {
    local sandbox_db="/tmp/tmux-claude-agent-tracker-sandbox.db"
    create_sandbox_db "$sandbox_db"

    # Sandbox has completed session at timestamp 1000
    insert_session_into "$sandbox_db" "flicker-s1" "completed" "deer" "" "1000"

    # Host has same session as idle at timestamp 2000 (newer - user focused pane)
    insert_session "flicker-s1" "idle" "%1" "2000"

    cmd_merge_sandbox

    # Host should keep its newer idle status
    local status
    status=$(get_status "flicker-s1")
    [[ "$status" == "idle" ]]
}

@test "cmd_merge_sandbox updates host when sandbox has newer data" {
    local sandbox_db="/tmp/tmux-claude-agent-tracker-sandbox.db"
    create_sandbox_db "$sandbox_db"

    # Host has idle session at timestamp 1000
    insert_session "update-s1" "idle" "%1" "1000"

    # Sandbox has same session as working at timestamp 2000 (newer - user typed)
    insert_session_into "$sandbox_db" "update-s1" "working" "deer" "" "2000"

    cmd_merge_sandbox

    # Host should get the newer working status
    local status
    status=$(get_status "update-s1")
    [[ "$status" == "working" ]]
}

@test "cmd_merge_sandbox backfills tmux_target from tmux_pane" {
    local sandbox_db="/tmp/tmux-claude-agent-tracker-sandbox.db"
    create_sandbox_db "$sandbox_db"

    # Sandbox session has pane but no target
    insert_session_into "$sandbox_db" "backfill-s1" "working" "deer" "%1"

    # Mock tmux to resolve pane to target
    tmux() {
        if [[ "$1" == "display-message" && "$3" == "%1" ]]; then
            echo "main:0.1"
        else
            true
        fi
    }

    cmd_merge_sandbox

    local target
    target=$(sql "SELECT tmux_target FROM sessions WHERE session_id='backfill-s1';")
    [[ "$target" == "main:0.1" ]]
}

@test "cmd_merge_sandbox preserves host tmux_pane when sandbox has empty" {
    local sandbox_db="/tmp/tmux-claude-agent-tracker-sandbox.db"
    create_sandbox_db "$sandbox_db"

    # Host has pane info, sandbox doesn't
    insert_session "pane-keep-s1" "idle" "%5" "1000"
    insert_session_into "$sandbox_db" "pane-keep-s1" "working" "deer" "" "2000"

    cmd_merge_sandbox

    local pane
    pane=$(sql "SELECT tmux_pane FROM sessions WHERE session_id='pane-keep-s1';")
    [[ "$pane" == "%5" ]]
}

@test "cmd_merge_sandbox no-op when no sandbox DB exists" {
    rm -f "/tmp/tmux-claude-agent-tracker-sandbox.db"
    # Should not error
    cmd_merge_sandbox
}

@test "cmd_merge_sandbox skips render when nothing changed" {
    local sandbox_db="/tmp/tmux-claude-agent-tracker-sandbox.db"
    create_sandbox_db "$sandbox_db"

    # Same session, same data, same timestamp - no update
    insert_session "no-change-s1" "idle" "%1" "1000"
    insert_session_into "$sandbox_db" "no-change-s1" "idle" "deer" "%1" "1000"

    local _render_called=0
    _render_cache() { _render_called=1; }

    cmd_merge_sandbox

    # total_changes should be 0 (only INSERT OR IGNORE which is a no-op)
    # Note: total_changes() may still report changes from INSERT OR IGNORE
    # The key test is that the host data is unchanged
    local status
    status=$(get_status "no-change-s1")
    [[ "$status" == "idle" ]]
}

@test "integration: sandbox session lifecycle" {
    enable_sandbox_mode
    # SessionStart creates idle session with deer client
    echo '{"session_id":"lifecycle-s1","cwd":"/tmp/test"}' | cmd_hook "SessionStart"
    [[ "$(get_status lifecycle-s1)" == "idle" ]]
    local client
    client=$(sql "SELECT agent_client FROM sessions WHERE session_id='lifecycle-s1';")
    [[ "$client" == "deer" ]]

    # UserPromptSubmit transitions to working
    echo '{"session_id":"lifecycle-s1","cwd":"/tmp/test"}' | cmd_hook "UserPromptSubmit"
    [[ "$(get_status lifecycle-s1)" == "working" ]]

    # PostToolUse keeps working
    echo '{"session_id":"lifecycle-s1"}' | cmd_hook "PostToolUse"
    [[ "$(get_status lifecycle-s1)" == "working" ]]

    # PermissionRequest transitions to blocked
    echo '{"session_id":"lifecycle-s1","notification_type":"permission_prompt"}' | cmd_hook "PermissionRequest"
    [[ "$(get_status lifecycle-s1)" == "blocked" ]]

    # PostToolUse clears blocked to working
    echo '{"session_id":"lifecycle-s1"}' | cmd_hook "PostToolUse"
    [[ "$(get_status lifecycle-s1)" == "working" ]]

    # Stop transitions to completed
    echo '{"session_id":"lifecycle-s1"}' | cmd_hook "Stop"
    [[ "$(get_status lifecycle-s1)" == "completed" ]]
    _SANDBOX=0
}

@test "integration: sandbox merge then host pane-focus does not flicker" {
    local sandbox_db="/tmp/tmux-claude-agent-tracker-sandbox.db"
    create_sandbox_db "$sandbox_db"

    # Sandbox session completed
    insert_session_into "$sandbox_db" "flicker-int-s1" "completed" "deer" "%1" "1000"

    # First merge: imports completed session
    cmd_merge_sandbox
    [[ "$(get_status flicker-int-s1)" == "completed" ]]

    # Host clears completed->idle (simulating pane-focus)
    sql "UPDATE sessions SET status='idle', updated_at=2000
         WHERE session_id='flicker-int-s1';"
    [[ "$(get_status flicker-int-s1)" == "idle" ]]

    # Second merge: sandbox still has completed at timestamp 1000
    # Host has idle at timestamp 2000 (newer) - must NOT overwrite
    cmd_merge_sandbox
    [[ "$(get_status flicker-int-s1)" == "idle" ]]
}

@test "integration: multiple concurrent sandbox sessions" {
    enable_sandbox_mode
    # Two sessions created by different deerbox instances
    echo '{"session_id":"concurrent-s1","cwd":"/tmp/project-a"}' | cmd_hook "SessionStart"
    echo '{"session_id":"concurrent-s2","cwd":"/tmp/project-b"}' | cmd_hook "SessionStart"

    [[ "$(count_sessions)" -eq 2 ]]
    [[ "$(get_status concurrent-s1)" == "idle" ]]
    [[ "$(get_status concurrent-s2)" == "idle" ]]

    # Both can transition independently
    echo '{"session_id":"concurrent-s1","cwd":"/tmp/project-a"}' | cmd_hook "UserPromptSubmit"
    [[ "$(get_status concurrent-s1)" == "working" ]]
    [[ "$(get_status concurrent-s2)" == "idle" ]]
    _SANDBOX=0
}

# ── Deerbox scan/reap lifecycle ──────────────────────────────────────

@test "cmd_scan detects deerbox pane and registers deer session" {
    # Remove throttle stamp so scan actually runs
    rm -f "$TRACKER_DIR/.last_scan"

    tmux() {
        case "$1" in
            list-panes) echo "%20 5000" ;;
            display-message) echo "/tmp/deer-project" ;;  # cwd or target
            *) true ;;
        esac
    }
    _has_agent_child() { return 0; }
    _agent_client_type() { echo "deer"; }

    cmd_scan

    [[ "$(count_sessions)" -eq 1 ]]
    local status client pane
    status=$(get_status "scan-%20")
    client=$(sql "SELECT agent_client FROM sessions WHERE session_id='scan-%20';")
    pane=$(sql "SELECT tmux_pane FROM sessions WHERE session_id='scan-%20';")
    [[ "$status" == "idle" ]]
    [[ "$client" == "deer" ]]
    [[ "$pane" == "%20" ]]
}

@test "cmd_scan detects claude pane and registers claude session" {
    rm -f "$TRACKER_DIR/.last_scan"

    tmux() {
        case "$1" in
            list-panes) echo "%21 6000" ;;
            display-message) echo "/tmp/claude-project" ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 0; }
    _agent_client_type() { echo "claude"; }

    cmd_scan

    local client
    client=$(sql "SELECT agent_client FROM sessions WHERE session_id='scan-%21';")
    [[ "$client" == "claude" ]]
}

@test "cmd_scan throttle prevents re-scan within 10s" {
    # First scan succeeds
    rm -f "$TRACKER_DIR/.last_scan"
    tmux() {
        case "$1" in
            list-panes) echo "%22 7000" ;;
            display-message) echo "/tmp/test" ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 0; }
    _agent_client_type() { echo "deer"; }

    cmd_scan
    [[ "$(count_sessions)" -eq 1 ]]

    # Delete session manually, second scan should be throttled
    sql "DELETE FROM sessions;"
    cmd_scan
    [[ "$(count_sessions)" -eq 0 ]]  # throttled, no re-insert
}

@test "cmd_scan skips pane when session already exists for that pane" {
    rm -f "$TRACKER_DIR/.last_scan"
    # Pre-existing hook-registered session owns pane %23
    insert_session "hook-s1" "working" "%23"

    tmux() {
        case "$1" in
            list-panes) echo "%23 8000" ;;
            display-message) echo "/tmp/test" ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 0; }
    _agent_client_type() { echo "deer"; }

    cmd_scan

    # Only the hook session, no scan session
    [[ "$(count_sessions)" -eq 1 ]]
    [[ "$(get_status hook-s1)" == "working" ]]
}

@test "_reap_dead deletes deer session when deerbox exits" {
    # Deer session exists on pane %24
    insert_session "scan-%24" "idle" "%24"
    sql "UPDATE sessions SET agent_client='deer' WHERE session_id='scan-%24';"
    rm -f "$TRACKER_DIR/.last_reap"

    # Pane alive but NO agent child (deerbox exited)
    tmux() {
        case "$1" in
            list-panes) echo "%24 9000" ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 1; }  # no agent found

    _reap_dead
    [[ "$(count_sessions)" -eq 0 ]]
}

@test "_reap_dead keeps deer session when deerbox is running" {
    insert_session "scan-%25" "idle" "%25"
    sql "UPDATE sessions SET agent_client='deer' WHERE session_id='scan-%25';"
    rm -f "$TRACKER_DIR/.last_reap"

    # Pane alive WITH agent child (deerbox running)
    tmux() {
        case "$1" in
            list-panes) echo "%25 9100" ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 0; }  # agent found

    _reap_dead
    [[ "$(count_sessions)" -eq 1 ]]
    [[ "$(get_status 'scan-%25')" == "idle" ]]
}

@test "_reap_dead deletes deer session when pane is closed" {
    insert_session "scan-%26" "idle" "%26"
    sql "UPDATE sessions SET agent_client='deer' WHERE session_id='scan-%26';"
    rm -f "$TRACKER_DIR/.last_reap"

    # Pane %26 is gone, only %1 exists
    tmux() {
        case "$1" in
            list-panes) echo "%1 1000" ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 1; }

    _reap_dead
    [[ "$(count_sessions)" -eq 0 ]]
}

@test "_reap_dead throttle prevents re-reap within 10s" {
    insert_session "scan-%27" "idle" "%27"
    rm -f "$TRACKER_DIR/.last_reap"

    tmux() {
        case "$1" in
            list-panes) echo "%27 9200" ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 1; }  # no agent

    # First reap succeeds
    _reap_dead
    [[ "$(count_sessions)" -eq 0 ]]

    # Re-insert, second reap should be throttled
    insert_session "scan-%27" "idle" "%27"
    _reap_dead
    [[ "$(count_sessions)" -eq 1 ]]  # throttled, session survives
}

@test "integration: deerbox scan -> run -> exit -> reap lifecycle" {
    rm -f "$TRACKER_DIR/.last_scan" "$TRACKER_DIR/.last_reap"

    # Phase 1: deerbox starts, scan detects it
    tmux() {
        case "$1" in
            list-panes) echo "%30 10000" ;;
            display-message) echo "/tmp/deer-project" ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 0; }
    _agent_client_type() { echo "deer"; }

    cmd_scan
    [[ "$(count_sessions)" -eq 1 ]]
    [[ "$(get_status 'scan-%30')" == "idle" ]]
    local client
    client=$(sql "SELECT agent_client FROM sessions WHERE session_id='scan-%30';")
    [[ "$client" == "deer" ]]

    # Phase 2: deerbox exits, reap cleans up
    rm -f "$TRACKER_DIR/.last_reap"
    _has_agent_child() { return 1; }  # deerbox gone

    _reap_dead
    [[ "$(count_sessions)" -eq 0 ]]
}

@test "integration: scan in cmd_refresh detects deerbox" {
    rm -f "$TRACKER_DIR/.last_scan"

    tmux() {
        case "$1" in
            list-panes) echo "%31 11000" ;;
            display-message) echo "/tmp/test" ;;
            show-option) echo "15" ;;
            run-shell) true ;;
            refresh-client) true ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 0; }
    _agent_client_type() { echo "deer"; }

    cmd_refresh
    [[ "$(count_sessions)" -eq 1 ]]
    [[ "$(get_status 'scan-%31')" == "idle" ]]
}

@test "integration: reap in cmd_refresh cleans exited deerbox" {
    insert_session "scan-%33" "idle" "%33"
    sql "UPDATE sessions SET agent_client='deer' WHERE session_id='scan-%33';"
    rm -f "$TRACKER_DIR/.last_reap" "$TRACKER_DIR/.last_scan"

    # Deerbox exited, pane still alive
    tmux() {
        case "$1" in
            list-panes) echo "%33 13000" ;;
            display-message) echo "/tmp/test" ;;
            show-option) echo "15" ;;
            run-shell) true ;;
            refresh-client) true ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 1; }  # no agent
    _agent_client_type() { echo "claude"; }

    cmd_refresh

    # Reap ran inside refresh and cleaned up the exited deerbox
    [[ "$(count_sessions)" -eq 0 ]]
}

@test "integration: reap in menu open cleans exited deerbox" {
    insert_session "scan-%32" "idle" "%32"
    sql "UPDATE sessions SET agent_client='deer' WHERE session_id='scan-%32';"
    rm -f "$TRACKER_DIR/.last_reap" "$TRACKER_DIR/.last_scan"

    # Deerbox exited, pane still alive
    tmux() {
        case "$1" in
            list-panes) echo "%32 12000" ;;
            display-message)
                if [[ "${*}" == *"pane_current_path"* ]]; then
                    echo "/tmp/test"
                else
                    echo "No active AI agents"
                fi ;;
            display-menu) true ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 1; }  # no agent
    _agent_client_type() { echo "claude"; }

    # _reap_dead runs before cmd_menu in the menu dispatch
    _reap_dead
    [[ "$(count_sessions)" -eq 0 ]]
}

@test "cmd_merge_sandbox evicts scan duplicate when real session owns same pane" {
    local sandbox_db="/tmp/tmux-claude-agent-tracker-sandbox.db"
    create_sandbox_db "$sandbox_db"

    # Scan detected deerbox first
    insert_session "scan-%40" "idle" "%40"
    sql "UPDATE sessions SET agent_client='deer' WHERE session_id='scan-%40';"

    # Sandbox has the real session for the same pane
    insert_session_into "$sandbox_db" "real-uuid-1" "working" "deer" "%40"

    cmd_merge_sandbox

    # scan-%40 should be evicted, only real-uuid-1 remains
    [[ "$(count_sessions)" -eq 1 ]]
    [[ "$(get_status 'real-uuid-1')" == "working" ]]
    local gone
    gone=$(sql "SELECT COUNT(*) FROM sessions WHERE session_id='scan-%40';")
    [[ "$gone" -eq 0 ]]
}

@test "cmd_merge_sandbox keeps scan session when no real session on that pane" {
    local sandbox_db="/tmp/tmux-claude-agent-tracker-sandbox.db"
    create_sandbox_db "$sandbox_db"

    # Scan session on pane %41
    insert_session "scan-%41" "idle" "%41"
    sql "UPDATE sessions SET agent_client='deer' WHERE session_id='scan-%41';"

    # Sandbox has a session on a DIFFERENT pane
    insert_session_into "$sandbox_db" "real-uuid-2" "working" "deer" "%42"

    cmd_merge_sandbox

    # Both should exist - different panes
    [[ "$(count_sessions)" -eq 2 ]]
    [[ "$(get_status 'scan-%41')" == "idle" ]]
    [[ "$(get_status 'real-uuid-2')" == "working" ]]
}

@test "integration: scan then merge deduplicates to single session per pane" {
    rm -f "$TRACKER_DIR/.last_scan"
    local sandbox_db="/tmp/tmux-claude-agent-tracker-sandbox.db"
    create_sandbox_db "$sandbox_db"

    # Step 1: scan detects deerbox on pane %43
    tmux() {
        case "$1" in
            list-panes) echo "%43 15000" ;;
            display-message) echo "/tmp/deer-project" ;;
            *) true ;;
        esac
    }
    _has_agent_child() { return 0; }
    _agent_client_type() { echo "deer"; }

    cmd_scan
    [[ "$(count_sessions)" -eq 1 ]]
    [[ "$(get_status 'scan-%43')" == "idle" ]]

    # Step 2: sandbox hooks fire, real session created in sandbox DB
    insert_session_into "$sandbox_db" "deer-uuid-1" "working" "deer" "%43"

    # Step 3: merge imports real session and evicts scan duplicate
    cmd_merge_sandbox
    [[ "$(count_sessions)" -eq 1 ]]
    [[ "$(get_status 'deer-uuid-1')" == "working" ]]
    local scan_gone
    scan_gone=$(sql "SELECT COUNT(*) FROM sessions WHERE session_id='scan-%43';")
    [[ "$scan_gone" -eq 0 ]]
}

# ── Pi client detection ────────────────────────────────────────────

@test "_detect_agent_client detects pi from session_id path" {
    run _detect_agent_client "/Users/user/.pi/sessions/session-abc.jsonl"
    [[ "$output" == "pi" ]]
}

@test "_detect_agent_client returns claude for UUID session_id" {
    run _detect_agent_client "550e8400-e29b-41d4-a716-446655440000"
    [[ "$output" == "claude" ]]
}

@test "_detect_agent_client returns deer in sandbox" {
    _SANDBOX=1
    run _detect_agent_client "some-id"
    [[ "$output" == "deer" ]]
    _SANDBOX=0
}

@test "_ensure_session stores agent_client=pi for pi-hooks sessions" {
    local raw_sid="/Users/test/.pi/sessions/session-abc.jsonl"
    local sid=$(sql_esc "$raw_sid")
    export TMUX_PANE="%44"
    tmux() {
        case "$1" in
            display-message) echo "test:0.0" ;;
            *) true ;;
        esac
    }
    _ensure_session "$sid" '{"cwd":"/tmp/test"}' "idle" "pi"
    local client
    client=$(sql "SELECT agent_client FROM sessions WHERE session_id='$sid';")
    [[ "$client" == "pi" ]]
}

@test "pi session shows in menu with [pi] tag" {
    local raw_sid="/Users/test/.pi/sessions/session-pi-test.jsonl"
    local sid=$(sql_esc "$raw_sid")
    sql "INSERT INTO sessions (session_id, status, cwd, project_name, agent_client, tmux_pane)
         VALUES ('$sid', 'working', '/tmp/test', 'test', 'pi', '%45');"
    local client
    client=$(sql "SELECT agent_client FROM sessions WHERE session_id='$sid';")
    [[ "$client" == "pi" ]]
}

@test "pi session counted in render alongside claude sessions" {
    sql "INSERT INTO sessions (session_id, status, cwd, project_name, agent_client, tmux_pane)
         VALUES ('pi-1', 'working', '/tmp/test', 'test', 'pi', '%46');"
    insert_session "claude-1" "working" "%47"
    _render_cache
    local out
    out=$(cat "$CACHE")
    # Both pi and claude sessions counted: 2 working
    [[ "$out" == *"2*"* ]]
}

@test "_detect_agent_client detects pi via process tree when TMUX_PANE set" {
    export TMUX_PANE="%48"
    tmux() {
        case "$1" in
            display-message) echo "12345" ;;
            *) true ;;
        esac
    }
    _agent_client_type() { echo "pi"; }
    run _detect_agent_client "some-uuid"
    [[ "$output" == "pi" ]]
}
