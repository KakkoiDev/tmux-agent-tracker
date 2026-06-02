---
name: tmux-agent-tracker-dev
description: Development guide for tmux-agent-tracker. Debugging, testing, architecture internals, and conventions. Use when developing or debugging this project.
---

# tmux-agent-tracker Development

Pure bash + SQLite tmux plugin. See MEMO.md for full details, ARCHITECTURE.md for design diagrams.

## File Map

| File | Lines | Purpose |
|------|-------|---------|
| `scripts/tracker.sh` | 688 | All core logic: hooks, render, menu, goto, scan, cleanup |
| `scripts/helpers.sh` | 162 | Config loading, tmux option helpers, platform detection |
| `agent-tracker.tmux` | 71 | TPM entry point, status bar injection, keybindings |
| `tests/tracker.bats` | 1363 | 121 unit tests (mocked tmux/git) |
| `tests/integration.bats` | 433 | 20 integration tests (isolated tmux server) |
| `tests/helpers.bash` | 129 | Unit test helpers: DB setup, mocks |
| `pi-hooks-config.json` | 55 | Pi hooks extension configuration template |
| `tests/integration_helpers.bash` | 148 | Integration helpers: isolated tmux, fire_hook |

## Debug Workflow

```bash
# Enable debug logging
tmux set -g @agent-tracker-debug-log 1

# Watch the log
tail -f ~/.tmux-agent-tracker/debug.log
```

Log entries include timestamps and context:
- `HOOK <event> sid=<id>` -- every hook entry
- `old=<status> changed=y/n` -- state transition results
- `_reap_dead` -- each reaped session with reason
- `_render_cache` -- raw count data (`w|b|i|c|dur` format)

Auto-truncation: at 1500 lines, keeps last 1000 via `tail -n 1000` + atomic `mv`.

## Testing

BATS framework, 141 tests total.

```bash
bats tests/                              # all tests
bats tests/tracker.bats                  # unit only
bats tests/integration.bats              # integration only
bats tests/tracker.bats -f "PostToolUse" # filter by name
```

### Unit Tests (tracker.bats)

Each test gets a fresh temp dir + isolated DB. `source_tracker_functions` evals tracker.sh with:
- Mocked `tmux()`, `git()`, `load_config()` as no-ops
- Overridden `TRACKER_DIR`, `DB`, `CACHE` to temp paths

Key helpers in `tests/helpers.bash`:
- `setup_test_env()` / `teardown_test_env()` -- temp dir lifecycle
- `insert_session(sid, status, pane, updated_at)` -- direct SQL insert
- `source_tracker_functions()` -- eval tracker.sh with mocks applied
- `count_status(status)`, `get_status(sid)`, `count_sessions()` -- query helpers

### Integration Tests (integration.bats)

Each test gets an isolated tmux server (unique socket per test). Wrapper scripts in `$PATH`:
- `tmux` wrapper routes to isolated server
- `pgrep` wrapper always succeeds (prevents _reap_dead killing test sessions)
- `git` wrapper returns fake branch

Key helpers in `tests/integration_helpers.bash`:
- `fire_hook(event, json)` -- invoke tracker.sh as subprocess
- `fire_hook_with_pane(event, json)` -- same but sets TMUX_PANE
- `run_status_bar()` -- subprocess status-bar invocation
- Production DB leak guard: snapshots session count before test, asserts no increase after

## Architecture Internals

**Push/Pull split**: Hooks write DB + render + `tmux refresh-client -S` (push). Periodic `#(tracker.sh refresh)` recomputes blocked timers (pull).

**Performance budget**: ~77ms state-changing hook, ~65ms no-op. No-ops skip render + tmux refresh.

**Hot path**: PostToolUse/Notification batch `SELECT + UPDATE + SELECT` in single sqlite3 call. Skip render when `changes() = 0`.

**JSON parsing**: `_json_val()` pure bash parameter expansion. No jq at runtime. Only handles simple string values.

**SQLite WAL mode**: IPC between concurrent hook processes. 100ms busy_timeout. Each call is a new connection.

**Two-tier config**:
- `_load_config_fast` -- sources config_cache directly, no freshness check (hook path)
- `load_config` -- checks cache freshness via date + stat, 60s TTL (status-bar/menu path)

**Platform split**: `_has_claude_child` uses `ps -eo ppid,comm | awk` on macOS, `pgrep -P -x` on Linux. `_file_mtime` uses `stat -f %m` (macOS) vs `stat -c %Y` (Linux).

## Environment Variables

| Variable | Overridable | Purpose |
|----------|-------------|---------|
| `TRACKER_DIR` | Yes | Data directory (default: `~/.tmux-agent-tracker`) |
| `DB` | Yes | Database path (default: `$TRACKER_DIR/tracker.db`) |
| `CACHE` | Yes | Status cache path (default: `$TRACKER_DIR/status_cache`) |
| `TMUX_PANE` | No | Set by tmux, current pane ID |
| `AGENT_TRACKER_PLUGIN_DIR` | Yes | Plugin root directory |
| `DEBUG_LOG` | Internal | Loaded from config, controls `_debug_log` |

## Known Upstream Limitations (Claude Code)

- **Notification hook delay**: Measured 4-41s (median ~11s) between agent blocking and hook firing. Zero dropped notifications across 10 concurrent sessions. Entirely upstream.
- **PostToolUse unreliability**: Sometimes never fires, session stays idle
- **No timing guarantees**: Claude Code provides no SLA on hook dispatch latency
- **Stop hook**: Most reliable and lowest-latency of all hooks
- **PostToolUseFailure**: Added specifically to clear stuck `blocked` states from unreliable hooks
- **No heuristic workaround**: "Assume blocked after N seconds of silence" would false-positive during LLM thinking (which can exceed 30s)

## Conventions

- No jq at runtime -- pure bash JSON parsing only
- Atomic file writes via `printf > tmp && mv tmp target`
- All SQL in tracker.sh -- no external migration files
- Single `sessions` table -- no schema complexity
- Bash 3.2+ compatible (macOS default)
