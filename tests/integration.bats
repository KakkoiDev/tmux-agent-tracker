#!/usr/bin/env bats

load integration_helpers

setup() {
    setup_integration
}

teardown() {
    teardown_integration
}

# ── 1. Full lifecycle ────────────────────────────────────────────────

@test "integration: full lifecycle start→prompt→block→unblock→stop→end" {
    local sid="lifecycle-1"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"

    # SessionStart → idle (fresh session)
    fire_hook SessionStart "$json"
    [[ "$(get_status "$sid")" == "idle" ]]

    # UserPromptSubmit → working
    fire_hook UserPromptSubmit "$json"
    [[ "$(get_status "$sid")" == "working" ]]
    [[ "$(read_cache)" == *"1*"* ]]

    # Notification → blocked
    fire_hook Notification "$json"
    [[ "$(get_status "$sid")" == "blocked" ]]
    [[ "$(read_cache)" == *"1!"* ]]

    # PostToolUse → working (unblock)
    fire_hook PostToolUse "$json"
    [[ "$(get_status "$sid")" == "working" ]]
    [[ "$(read_cache)" == *"1*"* ]]

    # Stop → completed
    fire_hook Stop "$json"
    [[ "$(get_status "$sid")" == "completed" ]]

    # SessionEnd → deleted
    fire_hook SessionEnd "$json"
    [[ "$(count_sessions)" -eq 0 ]]
}

# ── 2. Block transitions ────────────────────────────────────────────

@test "integration: working→blocked→working cycle updates cache" {
    local sid="block-cycle"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"

    fire_hook SessionStart "$json"
    fire_hook UserPromptSubmit "$json"
    [[ "$(get_status "$sid")" == "working" ]]

    # Block
    fire_hook Notification "$json"
    [[ "$(get_status "$sid")" == "blocked" ]]
    local blocked_cache
    blocked_cache=$(read_cache)
    [[ "$blocked_cache" == *"1!"* ]]

    # Unblock
    fire_hook PostToolUse "$json"
    [[ "$(get_status "$sid")" == "working" ]]
    local working_cache
    working_cache=$(read_cache)
    [[ "$working_cache" == *"0!"* ]]
}

# ── 3. No-op detection ──────────────────────────────────────────────

@test "integration: PostToolUse on working session is no-op" {
    local sid="noop-tool"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"

    fire_hook SessionStart "$json"
    fire_hook UserPromptSubmit "$json"
    [[ "$(get_status "$sid")" == "working" ]]

    # Record cache mtime
    sleep 1
    local before
    before=$(cache_mtime)

    # PostToolUse while already working — no-op
    sleep 1
    fire_hook PostToolUse "$json"
    local after
    after=$(cache_mtime)

    [[ "$before" == "$after" ]]
}

@test "integration: Notification on blocked session is no-op" {
    local sid="noop-notif"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"

    fire_hook SessionStart "$json"
    fire_hook UserPromptSubmit "$json"
    fire_hook Notification "$json"
    [[ "$(get_status "$sid")" == "blocked" ]]

    sleep 1
    local before
    before=$(cache_mtime)

    # Notification while already blocked — no-op
    sleep 1
    fire_hook Notification "$json"
    local after
    after=$(cache_mtime)

    [[ "$before" == "$after" ]]
}

# ── 4. Blocked timer ────────────────────────────────────────────────

@test "integration: blocked timer shows minutes" {
    local sid1="timer-min-1"
    local sid2="timer-min-2"

    fire_hook SessionStart "{\"session_id\":\"$sid1\",\"cwd\":\"/tmp/test\"}"
    fire_hook UserPromptSubmit "{\"session_id\":\"$sid1\",\"cwd\":\"/tmp/test\"}"
    fire_hook Notification "{\"session_id\":\"$sid1\",\"cwd\":\"/tmp/test\"}"

    # Backdate to 3 minutes ago
    sql "UPDATE sessions SET updated_at = unixepoch() - 180 WHERE session_id='$sid1';"

    # Trigger re-render by creating a second session
    fire_hook SessionStart "{\"session_id\":\"$sid2\",\"cwd\":\"/tmp/test\"}"
    fire_hook UserPromptSubmit "{\"session_id\":\"$sid2\",\"cwd\":\"/tmp/test\"}"

    local out
    out=$(read_cache)
    [[ "$out" == *"3m"* ]]
}

@test "integration: blocked timer shows hours" {
    local sid1="timer-hr-1"
    local sid2="timer-hr-2"

    # Use fire_hook_with_pane so backdated session survives paneless reaping
    fire_hook_with_pane SessionStart "{\"session_id\":\"$sid1\",\"cwd\":\"/tmp/test\"}"
    fire_hook_with_pane UserPromptSubmit "{\"session_id\":\"$sid1\",\"cwd\":\"/tmp/test\"}"
    fire_hook_with_pane Notification "{\"session_id\":\"$sid1\",\"cwd\":\"/tmp/test\"}"

    # Backdate to 2 hours ago
    sql "UPDATE sessions SET updated_at = unixepoch() - 7200 WHERE session_id='$sid1';"

    # Trigger re-render
    fire_hook SessionStart "{\"session_id\":\"$sid2\",\"cwd\":\"/tmp/test\"}"
    fire_hook UserPromptSubmit "{\"session_id\":\"$sid2\",\"cwd\":\"/tmp/test\"}"

    local out
    out=$(read_cache)
    [[ "$out" == *"2h"* ]]
}

# ── 5. Multiple sessions ────────────────────────────────────────────

@test "integration: 3 sessions show correct counts" {
    for i in 1 2 3; do
        fire_hook SessionStart "{\"session_id\":\"multi-$i\",\"cwd\":\"/tmp/test\"}"
        fire_hook UserPromptSubmit "{\"session_id\":\"multi-$i\",\"cwd\":\"/tmp/test\"}"
    done

    # s1=working, s2=blocked, s3=completed
    fire_hook Notification "{\"session_id\":\"multi-2\",\"cwd\":\"/tmp/test\"}"
    fire_hook Stop "{\"session_id\":\"multi-3\",\"cwd\":\"/tmp/test\"}"

    [[ "$(count_status working)" -eq 1 ]]
    [[ "$(count_status blocked)" -eq 1 ]]
    [[ "$(count_status completed)" -eq 1 ]]

    local out
    out=$(read_cache)
    [[ "$out" == *"0."* ]]   # 0 idle
    [[ "$out" == *"1*"* ]]   # 1 working
    [[ "$out" == *"1+"* ]]   # 1 completed
    [[ "$out" == *"1!"* ]]   # 1 blocked
}

@test "integration: 6 sessions with mixed states" {
    for i in $(seq 1 6); do
        fire_hook SessionStart "{\"session_id\":\"big-$i\",\"cwd\":\"/tmp/test\"}"
        fire_hook UserPromptSubmit "{\"session_id\":\"big-$i\",\"cwd\":\"/tmp/test\"}"
    done

    # 2 working (1,2), 2 blocked (3,4), 2 completed (5,6)
    fire_hook Notification "{\"session_id\":\"big-3\",\"cwd\":\"/tmp/test\"}"
    fire_hook Notification "{\"session_id\":\"big-4\",\"cwd\":\"/tmp/test\"}"
    fire_hook Stop "{\"session_id\":\"big-5\",\"cwd\":\"/tmp/test\"}"
    fire_hook Stop "{\"session_id\":\"big-6\",\"cwd\":\"/tmp/test\"}"

    [[ "$(count_status working)" -eq 2 ]]
    [[ "$(count_status blocked)" -eq 2 ]]
    [[ "$(count_status completed)" -eq 2 ]]

    local out
    out=$(read_cache)
    [[ "$out" == *"0."* ]]
    [[ "$out" == *"2*"* ]]
    [[ "$out" == *"2+"* ]]
    [[ "$out" == *"2!"* ]]
}

# ── 6. Concurrent hooks ─────────────────────────────────────────────

@test "integration: 10 parallel SessionStart+UserPromptSubmit creates" {
    local pids=()
    for i in $(seq 1 10); do
        (
            fire_hook SessionStart "{\"session_id\":\"conc-$i\",\"cwd\":\"/tmp/test\"}"
            fire_hook UserPromptSubmit "{\"session_id\":\"conc-$i\",\"cwd\":\"/tmp/test\"}"
        ) &
        pids+=($!)
    done
    # Tolerate cache-write races from concurrent mv
    for pid in "${pids[@]}"; do wait "$pid" || true; done

    [[ "$(count_sessions)" -eq 10 ]]
}

@test "integration: parallel mixed Notification/PostToolUse on different sessions" {
    # Setup: 10 working sessions
    for i in $(seq 1 10); do
        fire_hook SessionStart "{\"session_id\":\"mix-$i\",\"cwd\":\"/tmp/test\"}"
        fire_hook UserPromptSubmit "{\"session_id\":\"mix-$i\",\"cwd\":\"/tmp/test\"}"
    done

    # Even sessions get Notification, odd get PostToolUse — in parallel
    local pids=()
    for i in $(seq 1 10); do
        if (( i % 2 == 0 )); then
            fire_hook Notification "{\"session_id\":\"mix-$i\",\"cwd\":\"/tmp/test\"}" &
        else
            fire_hook PostToolUse "{\"session_id\":\"mix-$i\",\"cwd\":\"/tmp/test\"}" &
        fi
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid" || true; done

    [[ "$(count_status blocked)" -eq 5 ]]
    [[ "$(count_status working)" -eq 5 ]]
    [[ "$(count_sessions)" -eq 10 ]]
}

# ── 7. Rapid oscillation ────────────────────────────────────────────

@test "integration: sequential 4-flip on same session" {
    local sid="flip-seq"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"

    fire_hook SessionStart "$json"
    fire_hook UserPromptSubmit "$json"

    # working → blocked → working → blocked → working
    fire_hook Notification "$json"
    [[ "$(get_status "$sid")" == "blocked" ]]
    fire_hook PostToolUse "$json"
    [[ "$(get_status "$sid")" == "working" ]]
    fire_hook Notification "$json"
    [[ "$(get_status "$sid")" == "blocked" ]]
    fire_hook PostToolUse "$json"
    [[ "$(get_status "$sid")" == "working" ]]
}

@test "integration: concurrent 10-flip leaves valid state" {
    local sid="flip-conc"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"

    fire_hook SessionStart "$json"
    fire_hook UserPromptSubmit "$json"

    # Fire 10 alternating hooks concurrently
    local pids=()
    for i in $(seq 1 10); do
        if (( i % 2 == 0 )); then
            fire_hook PostToolUse "$json" &
        else
            fire_hook Notification "$json" &
        fi
        pids+=($!)
    done
    # Tolerate cache-write races from concurrent mv
    for pid in "${pids[@]}"; do wait "$pid" || true; done

    # Final state must be valid (either working or blocked — no corruption)
    local final
    final=$(get_status "$sid")
    [[ "$final" == "working" || "$final" == "blocked" ]]
    [[ "$(count_sessions)" -eq 1 ]]
}

# ── 8. Status-bar read ──────────────────────────────────────────────

@test "integration: status-bar output matches cache file" {
    local sid="sbar-1"
    fire_hook SessionStart "{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"
    fire_hook UserPromptSubmit "{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"

    local bar_out cache_out
    bar_out=$(run_status_bar)
    cache_out=$(read_cache)
    [[ "$bar_out" == "$cache_out" ]]
    [[ -n "$bar_out" ]]
}

@test "integration: status-bar empty when no cache" {
    rm -f "$CACHE"
    local out
    out=$(run_status_bar || true)
    [[ -z "$out" ]]
}

# ── 9. Session cleanup ──────────────────────────────────────────────

@test "integration: SessionEnd partial removal keeps other sessions" {
    fire_hook SessionStart "{\"session_id\":\"keep-1\",\"cwd\":\"/tmp/test\"}"
    fire_hook UserPromptSubmit "{\"session_id\":\"keep-1\",\"cwd\":\"/tmp/test\"}"
    fire_hook SessionStart "{\"session_id\":\"remove-1\",\"cwd\":\"/tmp/test\"}"
    fire_hook UserPromptSubmit "{\"session_id\":\"remove-1\",\"cwd\":\"/tmp/test\"}"

    [[ "$(count_sessions)" -eq 2 ]]

    fire_hook SessionEnd "{\"session_id\":\"remove-1\",\"cwd\":\"/tmp/test\"}"
    [[ "$(count_sessions)" -eq 1 ]]
    [[ "$(get_status keep-1)" == "working" ]]
    [[ -z "$(get_status remove-1)" ]]
}

@test "integration: last session removal zeros cache" {
    fire_hook SessionStart "{\"session_id\":\"last-1\",\"cwd\":\"/tmp/test\"}"
    fire_hook UserPromptSubmit "{\"session_id\":\"last-1\",\"cwd\":\"/tmp/test\"}"

    fire_hook SessionEnd "{\"session_id\":\"last-1\",\"cwd\":\"/tmp/test\"}"
    [[ "$(count_sessions)" -eq 0 ]]

    local out
    out=$(read_cache)
    [[ "$out" == *"0."* ]]
    [[ "$out" == *"0*"* ]]
    [[ "$out" == *"0!"* ]]
}

# ── 10. Completed status ─────────────────────────────────────────────

@test "integration: Stop sets completed, verified via cache" {
    local sid="completed-1"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"

    fire_hook SessionStart "$json"
    fire_hook UserPromptSubmit "$json"
    [[ "$(get_status "$sid")" == "working" ]]

    fire_hook Stop "$json"
    [[ "$(get_status "$sid")" == "completed" ]]

    local out
    out=$(read_cache)
    [[ "$out" == *"1+"* ]]
    [[ "$out" == *"0*"* ]]
}

@test "integration: completed resumes on UserPromptSubmit" {
    local sid="completed-resume"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"

    fire_hook SessionStart "$json"
    fire_hook UserPromptSubmit "$json"
    fire_hook Stop "$json"
    [[ "$(get_status "$sid")" == "completed" ]]

    fire_hook UserPromptSubmit "$json"
    [[ "$(get_status "$sid")" == "working" ]]
}

@test "integration: pane-focus clears completed to idle" {
    local sid="pf-clear"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"

    fire_hook_with_pane SessionStart "$json"
    fire_hook_with_pane UserPromptSubmit "$json"
    fire_hook Stop "$json"
    [[ "$(get_status "$sid")" == "completed" ]]

    # Get the pane assigned by fire_hook_with_pane
    local pane
    pane=$(sql "SELECT tmux_pane FROM sessions WHERE session_id='$sid';")

    # Fire pane-focus command (simulates session-window-changed hook)
    env TRACKER_DIR="$TRACKER_DIR" DB="$DB" CACHE="$CACHE" \
        COLOR_WORKING="$COLOR_WORKING" COLOR_BLOCKED="$COLOR_BLOCKED" \
        COLOR_IDLE="$COLOR_IDLE" COLOR_COMPLETED="$COLOR_COMPLETED" \
        PATH="$TEST_TMPDIR/bin:$PATH" \
        bash "$TRACKER_SH" pane-focus "$pane"

    [[ "$(get_status "$sid")" == "idle" ]]

    local out
    out=$(read_cache)
    [[ "$out" == *"1."* ]]
    [[ "$out" == *"0+"* ]]
}

@test "integration: full lifecycle with completed status" {
    local sid="completed-full"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"

    fire_hook SessionStart "$json"
    fire_hook UserPromptSubmit "$json"
    fire_hook Stop "$json"
    [[ "$(get_status "$sid")" == "completed" ]]

    # Resume
    fire_hook UserPromptSubmit "$json"
    [[ "$(get_status "$sid")" == "working" ]]

    # Block and unblock
    fire_hook Notification "$json"
    [[ "$(get_status "$sid")" == "blocked" ]]
    fire_hook PostToolUse "$json"
    [[ "$(get_status "$sid")" == "working" ]]

    # Complete again
    fire_hook Stop "$json"
    [[ "$(get_status "$sid")" == "completed" ]]

    fire_hook SessionEnd "$json"
    [[ "$(count_sessions)" -eq 0 ]]
}

# ── 15. Subagent lifecycle ─────────────────────────────────────────

@test "integration: subagent lifecycle - Stop deferred until subagents finish" {
    local sid="sub-life"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"
    local sub1="{\"session_id\":\"$sid\",\"agent_id\":\"sub-1\",\"agent_type\":\"researcher\",\"cwd\":\"/tmp/test\"}"

    fire_hook SessionStart "$json"
    fire_hook UserPromptSubmit "$json"
    [[ "$(get_status "$sid")" == "working" ]]

    # Spawn subagent
    fire_hook SubagentStart "$sub1"
    local count
    count=$(sql "SELECT subagent_count FROM sessions WHERE session_id='$sid';")
    [[ "$count" -eq 1 ]]

    # Stop fires while subagent active - should NOT complete
    fire_hook Stop "$json"
    [[ "$(get_status "$sid")" == "working" ]]

    # Subagent finishes
    fire_hook SubagentStop "$sub1"
    count=$(sql "SELECT subagent_count FROM sessions WHERE session_id='$sid';")
    [[ "$count" -eq 0 ]]

    # Real Stop - now completes
    fire_hook Stop "$json"
    [[ "$(get_status "$sid")" == "completed" ]]

    local out
    out=$(read_cache)
    [[ "$out" == *"1+"* ]]
}

@test "integration: SubagentStop clears blocked parent to working" {
    local sid="sub-unblock"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"
    local sub1="{\"session_id\":\"$sid\",\"agent_id\":\"sub-1\",\"agent_type\":\"researcher\",\"cwd\":\"/tmp/test\"}"

    fire_hook SessionStart "$json"
    fire_hook UserPromptSubmit "$json"
    fire_hook SubagentStart "$sub1"
    fire_hook Notification "$json"
    [[ "$(get_status "$sid")" == "blocked" ]]

    # SubagentStop clears blocked
    fire_hook SubagentStop "$sub1"
    [[ "$(get_status "$sid")" == "working" ]]

    local out
    out=$(read_cache)
    [[ "$out" == *"1*"* ]]
    [[ "$out" == *"0!"* ]]
}

@test "integration: multiple subagents count correctly through lifecycle" {
    local sid="multi-sub"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"

    fire_hook SessionStart "$json"
    fire_hook UserPromptSubmit "$json"

    # Spawn 3 subagents
    for i in 1 2 3; do
        fire_hook SubagentStart "{\"session_id\":\"$sid\",\"agent_id\":\"sub-$i\",\"agent_type\":\"worker\",\"cwd\":\"/tmp/test\"}"
    done
    local count
    count=$(sql "SELECT subagent_count FROM sessions WHERE session_id='$sid';")
    [[ "$count" -eq 3 ]]

    # Stop deferred
    fire_hook Stop "$json"
    [[ "$(get_status "$sid")" == "working" ]]

    # Subagents finish one by one
    for i in 1 2 3; do
        fire_hook SubagentStop "{\"session_id\":\"$sid\",\"agent_id\":\"sub-$i\",\"agent_type\":\"worker\",\"cwd\":\"/tmp/test\"}"
    done
    count=$(sql "SELECT subagent_count FROM sessions WHERE session_id='$sid';")
    [[ "$count" -eq 0 ]]

    # Real Stop
    fire_hook Stop "$json"
    [[ "$(get_status "$sid")" == "completed" ]]
}

@test "integration: PermissionRequest only blocks from working" {
    local sid="perm-guard"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"

    fire_hook SessionStart "$json"
    [[ "$(get_status "$sid")" == "idle" ]]

    # PermissionRequest on idle - should NOT block
    fire_hook PermissionRequest "$json"
    [[ "$(get_status "$sid")" == "idle" ]]

    # Move to working, then complete
    fire_hook UserPromptSubmit "$json"
    fire_hook Stop "$json"
    [[ "$(get_status "$sid")" == "completed" ]]

    # PermissionRequest on completed - should NOT block
    fire_hook PermissionRequest "$json"
    [[ "$(get_status "$sid")" == "completed" ]]
}

@test "integration: Notification only blocks from working" {
    local sid="notif-guard"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/test\"}"

    fire_hook SessionStart "$json"
    [[ "$(get_status "$sid")" == "idle" ]]

    # Notification on idle - should NOT block
    fire_hook Notification "$json"
    [[ "$(get_status "$sid")" == "idle" ]]

    # Move to working, then complete
    fire_hook UserPromptSubmit "$json"
    fire_hook Stop "$json"
    [[ "$(get_status "$sid")" == "completed" ]]

    # Notification on completed - should NOT block
    fire_hook Notification "$json"
    [[ "$(get_status "$sid")" == "completed" ]]
}

@test "integration: task_count only counted for completed sessions in cache" {
    local sid1="tc-working"
    local sid2="tc-completed"

    fire_hook SessionStart "{\"session_id\":\"$sid1\",\"cwd\":\"/tmp/test\"}"
    fire_hook UserPromptSubmit "{\"session_id\":\"$sid1\",\"cwd\":\"/tmp/test\"}"
    fire_hook TaskCompleted "{\"session_id\":\"$sid1\",\"cwd\":\"/tmp/test\"}"
    fire_hook TaskCompleted "{\"session_id\":\"$sid1\",\"cwd\":\"/tmp/test\"}"
    fire_hook TaskCompleted "{\"session_id\":\"$sid1\",\"cwd\":\"/tmp/test\"}"
    # s1: working with task_count=3

    fire_hook SessionStart "{\"session_id\":\"$sid2\",\"cwd\":\"/tmp/test\"}"
    fire_hook UserPromptSubmit "{\"session_id\":\"$sid2\",\"cwd\":\"/tmp/test\"}"
    fire_hook TaskCompleted "{\"session_id\":\"$sid2\",\"cwd\":\"/tmp/test\"}"
    fire_hook Stop "{\"session_id\":\"$sid2\",\"cwd\":\"/tmp/test\"}"
    # s2: completed with task_count=1

    local out
    out=$(read_cache)
    # Only s2's task_count should show (1+), not s1's
    [[ "$out" == *"1+"* ]]
    [[ "$out" == *"1*"* ]]
}

# ── 16. Pi hooks lifecycle ───────────────────────────────────────────

@test "pi: full session lifecycle via pi-hooks events" {
    local sid="/tmp/.pi/sessions/session-pi-1.jsonl"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/project\"}"

    # SessionStart → idle (pi client detected from session_id path)
    fire_hook SessionStart "$json"
    [[ "$(get_status "$sid")" == "idle" ]]
    [[ "$(sql \"SELECT agent_client FROM sessions WHERE session_id='$sid';\")" == "pi" ]]

    # UserPromptSubmit → working
    fire_hook UserPromptSubmit "$json"
    [[ "$(get_status "$sid")" == "working" ]]

    # PostToolUse → working (no-op)
    fire_hook PostToolUse "$json"
    [[ "$(get_status "$sid")" == "working" ]]

    # PostToolUseFailure → working (no-op)
    fire_hook PostToolUseFailure "$json"
    [[ "$(get_status "$sid")" == "working" ]]

    # Stop → completed
    fire_hook Stop "$json"
    [[ "$(get_status "$sid")" == "completed" ]]

    local out
    out=$(read_cache)
    [[ "$out" == *"1+"* ]]

    # SessionEnd → deleted
    fire_hook SessionEnd "$json"
    [[ "$(count_sessions)" -eq 0 ]]
}

@test "pi: session_id as file path does not break cache rendering" {
    local sid="/Users/test/.pi/sessions/session-pi-render.jsonl"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/project\"}"

    fire_hook SessionStart "$json"
    fire_hook UserPromptSubmit "$json"
    fire_hook Stop "$json"

    local out
    out=$(read_cache)
    [[ -n "$out" ]]
    [[ "$out" == *"1+"* ]]

    fire_hook SessionEnd "$json"
}

@test "pi: pi and claude sessions coexist in cache" {
    local pi_sid="/tmp/.pi/sessions/session-pi-mix.jsonl"
    local pi_json="{\"session_id\":\"$pi_sid\",\"cwd\":\"/tmp/project\"}"
    local cc_sid="cc-mix-1"
    local cc_json="{\"session_id\":\"$cc_sid\",\"cwd\":\"/tmp/project\"}"

    # Pi session
    fire_hook SessionStart "$pi_json"
    fire_hook UserPromptSubmit "$pi_json"
    [[ "$(sql \"SELECT agent_client FROM sessions WHERE session_id='$pi_sid';\")" == "pi" ]]

    # Claude session
    fire_hook SessionStart "$cc_json"
    fire_hook UserPromptSubmit "$cc_json"
    [[ "$(sql \"SELECT agent_client FROM sessions WHERE session_id='$cc_sid';\")" == "claude" ]]

    # Both working: count = 2
    local out
    out=$(read_cache)
    [[ "$out" == *"2*"* ]]

    # Cleanup
    fire_hook SessionEnd "$pi_json"
    fire_hook SessionEnd "$cc_json"
}

@test "pi: Stop → UserPromptSubmit resumes from completed" {
    local sid="/tmp/.pi/sessions/session-pi-resume.jsonl"
    local json="{\"session_id\":\"$sid\",\"cwd\":\"/tmp/project\"}"

    fire_hook SessionStart "$json"
    fire_hook UserPromptSubmit "$json"
    fire_hook Stop "$json"
    [[ "$(get_status "$sid")" == "completed" ]]

    # Resume
    fire_hook UserPromptSubmit "$json"
    [[ "$(get_status "$sid")" == "working" ]]

    fire_hook SessionEnd "$json"
}
