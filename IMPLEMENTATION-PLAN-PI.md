# Pi Integration Implementation Plan

## Overview

Add **Pi coding agent** (`pi`) as a supported agent client in `tmux-agent-tracker`. Pi runs as a Node.js-based TUI agent (process name: `pi`). Unlike Claude Code and Gemini CLI, Pi has no native CLI hook system — instead it has a TypeScript extension API with lifecycle events.

The integration uses **pi-hooks** (`npm:@hsingjui/pi-hooks`), a third-party Pi package that adapts Claude Code's hook configuration format to Pi's extension event system. Hooks are configured declaratively in Pi's settings JSON and invoke external commands with Claude Code-compatible JSON on stdin.

## Pi-Hooks Supported Events

pi-hooks maps Pi extension events to Claude Code-compatible hook events:

| pi-hooks Event      | Pi Extension Event         | Tracker Usage            |
|---------------------|---------------------------|--------------------------|
| `SessionStart`      | `session_start`           | Create session as `idle` |
| `UserPromptSubmit`  | `input` (after commands)  | Status → `working`       |
| `PostToolUse`       | `tool_result` (success)   | Status → `working`       |
| `PostToolUseFailure`| `tool_result` (failure)   | Status → `working`       |
| `Stop`              | `agent_end`               | Status → `completed`     |
| `SessionEnd`        | `session_shutdown`        | Delete session from DB   |

### Missing Events (vs Claude Code)

| Event               | Status    | Impact                             |
|---------------------|-----------|-------------------------------------|
| `Notification`      | ❌ N/A    | No blocked state for Pi sessions   |
| `PermissionRequest` | ❌ N/A    | No blocked state for Pi sessions   |
| `TaskCompleted`     | ❌ N/A    | Tasks not counted individually     |

Pi does not have permission dialogs like Claude Code, so no `blocked` state is possible. Pi sessions will only cycle through `idle → working → completed → idle`.

## JSON Input Format

pi-hooks sends Claude Code-compatible JSON on stdin. The `session_id` field is a **file path** (e.g., `/Users/user/.pi/sessions/session-123.jsonl`), not a UUID. The tracker already handles any string session_id.

Example `SessionStart`:
```json
{
  "session_id": "/Users/user/.pi/sessions/session-abc.jsonl",
  "transcript_path": "/Users/user/.pi/sessions/session-abc.jsonl",
  "cwd": "/Users/user/project",
  "hook_event_name": "SessionStart",
  "source": "startup"
}
```

Example `UserPromptSubmit`:
```json
{
  "session_id": "/Users/user/.pi/sessions/session-abc.jsonl",
  "cwd": "/Users/user/project",
  "hook_event_name": "UserPromptSubmit",
  "prompt": "Fix the bug in auth.ts"
}
```

## Implementation Tasks

### Phase 1: Tracker Core Changes

#### 1.1 Add `pi` to agent client detection (`scripts/helpers.sh`)

**File:** `scripts/helpers.sh`

Changes:
- `_has_agent_child()`: Add `|| $2 == "pi"` to the awk filter (both Darwin and Linux)
- `_agent_client_type()`: Add `pi` case to the awk filter and `case` statement

```diff
- '$1 == p && ($2 == "claude" || $2 == "codex" || $2 == "gemini" || $2 == "deer" || $2 == "deerbox")'
+ '$1 == p && ($2 == "claude" || $2 == "codex" || $2 == "gemini" || $2 == "deer" || $2 == "deerbox" || $2 == "pi")'
```

```diff
  case "$child_comm" in
      deer|deerbox) echo "deer" ;;
      codex) echo "codex" ;;
      gemini) echo "gemini" ;;
+     pi) echo "pi" ;;
      *) echo "claude" ;;
  esac
```

#### 1.2 Handle `pi` client in session creation (`scripts/tracker.sh`)

**File:** `scripts/tracker.sh`

Changes in `_ensure_session()`:
- `UserPromptSubmit` case: set `_client="pi"` when detecting pi hook JSON
- `SessionStart` case: set `_client="pi"` when detecting pi hook JSON

**Detection strategy:** Pi sessions use file paths as `session_id` (containing `.pi/sessions/` or `.jsonl`). Check for this pattern and use `pi` as `agent_client`.

Alternative: Check if `TMUX_PANE` env var's shell has a `pi` child process. But cleaner: just check session_id format or add a `--client pi` flag option.

Recommended: Check the `transcript_path` or `session_id` for `/.pi/sessions/` or `.jsonl` pattern. If yes, client is `pi`.

```bash
# Detect pi client from session file path pattern
_detect_client() {
    local sid="$1"
    if [[ "$sid" == *"/.pi/sessions/"* || "$sid" == *".jsonl"* && "$sid" != *"/.claude/"* ]]; then
        echo "pi"
        return
    fi
    # Fall through to existing detection
}
```

Actually, simpler: pi-hooks sends `transcript_path` pointing to the session file. The tracker already extracts `session_id` via `_json_val`. If `transcript_path` contains `.pi` or the session file ends with `.jsonl` (while `.claude` sessions end with `.json`), we can detect pi.

**Simplest approach:** The `session_id` from pi-hooks is a file path. Claude Code sessions have UUID-like IDs. We can just let the hook do the detection. But pi-hooks uses the same hook command — we can't distinguish at the JSON level easily.

**Best approach for now:** Keep it simple. The tracker's `_session_client()` already defaults to `claude`. Pi sessions will just show as `[claude]` in the menu. This is acceptable for v1. We can add proper detection later.

wait, actually the `agent_client` column has a default of `'claude'`. If we don't explicitly set it for pi sessions, they'll show as `[claude]` in the menu. Let's think about this differently.

Since pi-hooks invokes `tmux-agent-tracker hook SessionStart` with JSON on stdin, the tracker doesn't know which agent sent it. The `cwd` and `session_id` could come from any agent.

**Solution:** Add detection in `cmd_hook()`. Before calling `_ensure_session`, check the process tree. If `TMUX_PANE` is set, find the pane's shell and check for a `pi` child process.

```bash
# In cmd_hook(), before _ensure_session for SessionStart/UserPromptSubmit:
_detect_agent_client() {
    if [[ -n "${TMUX_PANE:-}" && "$_SANDBOX" -eq 0 ]]; then
        local shell_pid
        shell_pid=$(tmux display-message -t "$TMUX_PANE" -p '#{pane_pid}' 2>/dev/null) || true
        if [[ -n "$shell_pid" ]]; then
            _agent_client_type "$shell_pid"
            return
        fi
    fi
    echo "claude"
}
```

This is the most reliable approach and matches how `cmd_scan` already works. But it adds overhead to every hook. Let's check: `tmux display-message` is ~5ms, `ps` is ~5ms. So ~10ms total, which is acceptable.

Actually, even cleaner: we don't need to detect in every hook. We can detect once in `_ensure_session` (which only runs for SessionStart/UserPromptSubmit). Once the session is created with the right agent_client, all subsequent hooks just use the stored value.

So the changes are:

1. In `_ensure_session()`: detect client via process inspection
2. Or: add a `_detect_and_set_client()` helper used by SessionStart/UserPromptSubmit

### Phase 2: Pi Hook Configuration

#### 2.1 Create Pi extension config for pi-hooks

**New file:** `pi-hooks-config.json` (template, referenced by install.sh)

This is the Pi settings configuration that configures pi-hooks to call the tracker:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "tmux-agent-tracker hook SessionStart"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "tmux-agent-tracker hook UserPromptSubmit"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "tmux-agent-tracker hook PostToolUse"
          }
        ]
      }
    ],
    "PostToolUseFailure": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "tmux-agent-tracker hook PostToolUseFailure"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "tmux-agent-tracker hook Stop"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "tmux-agent-tracker hook SessionEnd"
          }
        ]
      }
    ]
  }
}
```

#### 2.2 Update install.sh for Pi hooks

**File:** `install.sh`

Add a new function `install_pi_hooks()` that:

1. Checks if `pi` is installed (`command -v pi`)
2. Checks if `~/.pi/agent/settings.json` exists
3. Checks if `pi-hooks` package is installed (`pi install --list` or check `~/.pi/agent/npm/`)
4. If not installed, offers to install: `pi install npm:@hsingjui/pi-hooks`
5. Merges tracker hooks into the existing Pi hooks config
6. Provides manual setup instructions if `jq` is not available

The hook config lives in Pi's settings, not as a separate file. Pi settings merge global (`~/.pi/agent/settings.json`) and project (`.pi/settings.json`).

**Merge strategy:**

```bash
install_pi_hooks() {
    # Check pi is installed
    if ! command -v pi >/dev/null 2>&1; then
        echo "pi hooks: pi not found, skipping"
        return
    fi

    # Check pi-hooks is installed
    if ! pi --help 2>/dev/null | grep -q "pi-hooks" && \
       [[ ! -d "$HOME/.pi/agent/npm/node_modules/@hsingjui/pi-hooks" ]]; then
        echo "pi hooks: pi-hooks package not installed"
        echo "  Install with: pi install npm:@hsingjui/pi-hooks"
        echo "  Then re-run: ./install.sh --hooks-only"
        return
    fi

    local pi_settings="$HOME/.pi/agent/settings.json"
    
    # Ensure pi settings exist
    if [[ ! -f "$pi_settings" ]]; then
        echo '{}' > "$pi_settings"
    fi

    # Check if hooks already configured
    if jq -e '.hooks.SessionStart' "$pi_settings" >/dev/null 2>&1; then
        local has_tracker
        has_tracker=$(jq -r '.hooks.SessionStart[]?.hooks[]?.command' "$pi_settings" 2>/dev/null | \
                      grep -c "tmux-agent-tracker" || echo "0")
        if [[ "$has_tracker" -gt 0 ]]; then
            echo "pi hooks: already configured"
            return
        fi
    fi

    # Merge tracker hooks (similar to Claude Code hook merging)
    # ...
}
```

### Phase 3: Process Scanning

#### 3.1 Detect `pi` processes in `cmd_scan`

Already covered by Phase 1.1 — `_has_agent_child` and `_agent_client_type` will detect `pi` processes. No additional changes needed.

Pi process characteristics:
- Process name: `pi` (visible in `ps aux` COMMAND column and `ps -eo comm`)
- Single process (no subprocess fork model)
- Booted by the shell directly (or via nvm shim)

### Phase 4: Tests

#### 4.1 Unit tests for pi client (`tests/tracker.bats`)

Add test cases:

```bash
@test "pi session created with agent_client='pi'" {
  insert_pi_session "session-1" "idle"
  run get_client "session-1"
  [[ "$output" == "pi" ]]
}

@test "pi hook SessionStart creates pi session" {
  run_tracker_hook "SessionStart" '{"session_id":"pi-session-1","cwd":"/tmp/project","hook_event_name":"SessionStart"}'
  [[ "$(get_client 'pi-session-1')" == "pi" ]]
}

@test "pi session not included with claude sessions in count" {
  insert_session "claude-1" "working"
  insert_pi_session "pi-1" "working"
  result=$(count_status "working")
  [[ "$result" == "1" ]]  # pi session excluded from COALESCE filter
}
```

Wait — pi sessions SHOULD be included in the count. Only `agent_type` (worktree/teammate) sessions are excluded. Pi sessions have `agent_type=''` and `agent_client='pi'`, so they should appear in the status bar.

Re-check: The render query uses `WHERE COALESCE(agent_type,'')=''` to filter. Pi sessions have `agent_type=''` so they are included. Good.

Menu display already shows `[client]` tag. Pi sessions will show as `[pi]`.

#### 4.2 Integration tests (`tests/integration.bats`)

Add test:
```bash
@test "pi hook SessionStart + UserPromptSubmit + Stop cycle" {
  # Simulate full pi session cycle
  run_tracker_subprocess hook SessionStart <<< '{"session_id":"pi-int-1","cwd":"/tmp/project","hook_event_name":"SessionStart"}'
  run_tracker_subprocess hook UserPromptSubmit <<< '{"session_id":"pi-int-1","cwd":"/tmp/project","hook_event_name":"UserPromptSubmit"}'
  run_tracker_subprocess hook PostToolUse <<< '{"session_id":"pi-int-1","cwd":"/tmp/project","hook_event_name":"PostToolUse"}'
  run_tracker_subprocess hook Stop <<< '{"session_id":"pi-int-1","cwd":"/tmp/project","hook_event_name":"Stop"}'
  # Assert status transitions: idle → working → working → completed
}
```

### Phase 5: Documentation

#### 5.1 Update README.md

- Add Pi to the "Tracked Agents" list at top
- Add Pi hook setup section (similar to Gemini/Codex sections)
- Note limitation: Pi sessions don't show blocked state

#### 5.2 Update ARCHITECTURE.md

- Add Pi row to the Hook Events table
- Add Pi to agent_client type table
- Document pi-hooks dependency and event mapping
- Add limitation note about missing Notification/PermissionRequest

### Phase 6: Skill Updates

#### 6.1 Update skill files

The bundled skills in `.claude/skills/` reference the tracker. Consider:
- Adding pi-hooks install instructions to the skill
- Or creating a separate Pi skill

## Event Flow (Pi Session)

```
pi starts
  │
  ├─► pi-hooks: SessionStart
  │    └─► tracker hook SessionStart → INSERT session (status=idle, agent_client=pi)
  │
user sends prompt
  │
  ├─► pi-hooks: UserPromptSubmit
  │    └─► tracker hook UserPromptSubmit → UPDATE status=working
  │
  ├─► pi-hooks: PostToolUse (for each tool)
  │    └─► tracker hook PostToolUse → UPDATE status=working (no-op if already working)
  │
  ├─► pi-hooks: PostToolUseFailure (if tool fails)
  │    └─► tracker hook PostToolUseFailure → UPDATE status=working
  │
  └─► pi-hooks: Stop
       └─► tracker hook Stop → UPDATE status=completed

pi exits
  │
  └─► pi-hooks: SessionEnd
       └─► tracker hook SessionEnd → DELETE session
```

## Limitations

1. **No blocked state**: Pi doesn't have permission dialogs. Sessions only show `idle`, `working`, or `completed`.
2. **No task count**: `TaskCompleted` is not available. Completed sessions always show count 1.
3. **External dependency**: Requires `pi-hooks` npm package. Users must `pi install npm:@hsingjui/pi-hooks` before the tracker can receive Pi events.
4. **Session ID format**: Pi session IDs are file paths, which may be very long. Truncation in menu/display may be needed.
5. **No `SubagentStart`/`SubagentStop`**: Pi may have subagent concepts, but pi-hooks doesn't expose them yet.

## Future Enhancements

1. **Bundled Pi extension**: Instead of depending on pi-hooks, ship a custom extension in the tracker that directly subscribes to Pi's lifecycle events and calls `tracker.sh hook`. This eliminates the external dependency and could provide richer events.

2. **Blocked detection via extension**: A custom Pi extension could detect when Pi is waiting for user input (e.g., when a `confirm` or `select` dialog is open) and set the tracker's `blocked` status.

3. **Pi-specific icons**: Allow per-agent-client icons in the status bar (e.g., `π` for pi sessions).

4. **Multi-agent mixed display**: Show separate counts per agent client or combined counts. This could be a user-configurable option.
