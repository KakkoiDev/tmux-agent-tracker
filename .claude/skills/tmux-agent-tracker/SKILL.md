---
name: tmux-agent-tracker
description: Track Claude Code and Codex agent sessions in tmux. Use when installing, configuring, debugging, or customizing tmux-agent-tracker hooks, status bar rendering, menu behavior, and state transitions.
---

# tmux-agent-tracker

Track Claude Code, Pi, and Codex agent sessions in the tmux status bar. Hook-driven, no daemon, no polling.

## How It Works

1. Claude Code, Pi, and Gemini CLI hooks fire on session events and write JSON to stdin
2. Codex `notify` fires on agent events and calls `tracker.sh codex-notify`
3. `tracker.sh` parses hook JSON, updates a SQLite DB, and re-renders the status bar
4. `#{@agent-tracker-status}` displays the cached status string (instant, no subprocess)
5. A periodic `#(tracker.sh refresh)` keeps the blocked timer current
6. Dead sessions are reaped by cross-referencing tmux panes

## State Machine

```
SessionStart --> idle
UserPromptSubmit --> working
PostToolUse --> working (if blocked/idle)
PostToolUseFailure --> working (if blocked)
Notification(permission_prompt|elicitation_dialog) --> blocked (if working)
Stop --> completed (if working/blocked)
SessionEnd --> [deleted]
pane-focus --> idle (if completed, on focused pane)
```

Completed auto-clears to idle when the user focuses the pane.

## CLI Commands

All commands go through `tmux-agent-tracker` (symlinked to `scripts/tracker.sh`).

| Command | Purpose |
|---------|---------|
| `init` | Create/reset the SQLite DB |
| `hook <event>` | Handle a Claude Code hook event (reads JSON from stdin) |
| `status-bar` | Output the cached status string |
| `refresh` | Re-render from DB, update tmux option (no stdout) |
| `menu [page]` | Show interactive agent menu |
| `goto <target>` | Jump to a pane by tmux target (`session:window.pane`) |
| `pane-focus <pane_id>` | Clear completed status on focused pane |
| `pane-focus-if-active <pane_id>` | Clear completed only if pane is currently focused |
| `scan` | Discover untracked Claude processes via pgrep |
| `cleanup` | Remove stale sessions (>24h or dead panes) |
| `codex-notify <json>` | Handle Codex notify payloads and map to tracker states |

## Pi Hook Configuration (pi-hooks)

Pi uses the [pi-hooks](https://npmjs.com/package/@hsingjui/pi-hooks) extension to bridge Pi's extension events to tracker commands.

### Prerequisites

```bash
pi install npm:@hsingjui/pi-hooks
```

### Hook Events

| pi-hooks Event | Pi Extension Event | Tracker Action |
|----------------|-------------------|----------------|
| `SessionStart` | `session_start` | Create session as idle |
| `UserPromptSubmit` | `input` | Set working |
| `PostToolUse` | `tool_result` (success) | Set working (clears blocked) |
| `PostToolUseFailure` | `tool_result` (failure) | Set working (clears stuck blocked) |
| `Stop` | `agent_end` | Set completed |
| `SessionEnd` | `session_shutdown` | Delete session |

### Limitations

- No `blocked` state: Pi doesn't have permission dialogs
- No `TaskCompleted`: Tasks not counted individually
- Requires `pi-hooks` npm package

### Configuration

These hooks are configured in `~/.pi/agent/settings.json`. The `install.sh` script detects Pi and configures them automatically.

### Verify

```json
{
  "use": { "extension": ["pi-hooks"] },
  "hooks": {
    "SessionStart": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook SessionStart" }] }],
    "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook UserPromptSubmit" }] }],
    "PostToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook PostToolUse" }] }],
    "PostToolUseFailure": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook PostToolUseFailure" }] }],
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook Stop" }] }],
    "SessionEnd": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook SessionEnd" }] }]
  }
}
```

## Claude Code Hook Configuration

### Hook Events

These hooks must be in `~/.claude/settings.json`. The `install.sh` script configures them automatically.

| Hook Event | Matcher | Tracker Action |
|------------|---------|----------------|
| `SessionStart` | `""` | Create session as idle |
| `SessionEnd` | `""` | Delete session |
| `UserPromptSubmit` | `""` | Set working |
| `PostToolUse` | `""` | Set working (clears blocked) |
| `PostToolUseFailure` | `""` | Set working (clears stuck blocked) |
| `Stop` | `""` | Set completed |
| `Notification` | `"permission_prompt\|elicitation_dialog"` | Set blocked |

**Why `PostToolUseFailure`?** Claude Code's `Stop` hook does not fire on user interrupt. If a user rejects a permission prompt, the session stays stuck at `blocked`. `PostToolUseFailure` clears it.

**Why the Notification matcher?** The `Notification` hook fires for `permission_prompt`, `elicitation_dialog`, `idle_prompt`, `auth_success`. Only the first two mean Claude is waiting for user input.

## Codex Notify Configuration

Codex must include this in `~/.codex/config.toml`:

```toml
notify = ["tmux-agent-tracker", "codex-notify"]
```

Without this notify hook, no Codex sessions are tracked and `[codex]` will never appear in the menu.

## tmux Configuration Options

Set in `~/.tmux.conf` with `set -g @option value`.

### Display

| Option | Default | Purpose |
|--------|---------|---------|
| `@agent-tracker-keybinding` | `a` | Menu key (after prefix) |
| `@agent-tracker-items-per-page` | `10` | Menu page size |
| `@agent-tracker-key-next` | `i` | Next page key |
| `@agent-tracker-key-prev` | `o` | Previous page key |
| `@agent-tracker-key-quit` | `q` | Quit menu key |
| `@agent-tracker-show-project` | `0` | `1` to show project name in status |
| `@agent-tracker-status-interval` | `60` | Blocked timer refresh interval (seconds) |
| `@agent-tracker-completed-delay` | `3` | Seconds to show completed before auto-clear (`0` to disable) |

### Colors

| Option | Default | Purpose |
|--------|---------|---------|
| `@agent-tracker-color-working` | `black` | Working count color |
| `@agent-tracker-color-blocked` | `black` | Blocked count color |
| `@agent-tracker-color-idle` | `black` | Idle count color |
| `@agent-tracker-color-completed` | `black` | Completed count color |

### Icons

| Option | Default | Purpose |
|--------|---------|---------|
| `@agent-tracker-icon-idle` | `.` | Idle indicator |
| `@agent-tracker-icon-working` | `*` | Working indicator |
| `@agent-tracker-icon-completed` | `+` | Completed indicator |
| `@agent-tracker-icon-blocked` | `!` | Blocked indicator |

### State Transition Hooks

Shell commands executed when an agent changes state. Each receives 4 args: `$1=from_state $2=to_state $3=session_id $4=project_name`. Runs async (backgrounded).

| Option | Default | Fires on |
|--------|---------|----------|
| `@agent-tracker-on-working` | `""` | Any state -> working |
| `@agent-tracker-on-completed` | `""` | Any state -> completed |
| `@agent-tracker-on-blocked` | `""` | Any state -> blocked |
| `@agent-tracker-on-idle` | `""` | Any state -> idle |
| `@agent-tracker-on-transition` | `""` | Any state change (catch-all) |

Example:
```bash
set -g @agent-tracker-on-blocked 'notify-send "Claude blocked" "Agent in $4 needs attention"'
set -g @agent-tracker-on-completed 'paplay /usr/share/sounds/complete.oga'
```

## Key Files

| File | Purpose |
|------|---------|
| `agent-tracker.tmux` | TPM entry point, status bar injection, pane-focus hooks |
| `scripts/tracker.sh` | All commands: hook, render, menu, goto, scan, cleanup |
| `scripts/helpers.sh` | Config loading, tmux option helpers, version check |
| `bin/tmux-agent-tracker` | CLI wrapper (delegates to tracker.sh) |
| `install.sh` | Symlinks CLI, inits DB, configures tmux.conf and Claude Code hooks |
| `tests/tracker.bats` | Full test suite (bats) |

## DB Schema

Single table `sessions` in `~/.tmux-agent-tracker/tracker.db`:

| Column | Type | Purpose |
|--------|------|---------|
| `session_id` | TEXT PK | Claude Code session ID |
| `status` | TEXT | `working`, `blocked`, `idle`, `completed` |
| `cwd` | TEXT | Working directory |
| `project_name` | TEXT | `basename(cwd)` |
| `git_branch` | TEXT | Current branch |
| `tmux_pane` | TEXT | `%N` pane ID |
| `tmux_target` | TEXT | `session:window.pane` |
| `started_at` | INTEGER | Unix timestamp |
| `updated_at` | INTEGER | Unix timestamp (for blocked timer) |
