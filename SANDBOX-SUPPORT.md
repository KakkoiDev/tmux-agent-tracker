# Sandbox Support for Deer/Deerbox

## Problem

When Claude Code runs inside deer/deerbox's SRT sandbox:
- `~/.tmux-claude-agent-tracker/tracker.db` is **not writable** (sandbox only allows writes to worktree, `~/.claude/`, `/tmp/`)
- `TMUX_PANE` and `TMUX` env vars are **not forwarded** by default
- `tmux` commands (`refresh-client`, `set`, `display-message`) **fail** because the tmux socket is inaccessible
- `config_cache` write fails (same dir as DB)
- Sessions launched in deerbox are invisible to the tracker

## Constraints

Deer's SRT sandbox `allowWrite` paths (from `buildSrtSettings`):
- `options.worktreePath` (the git worktree)
- Git internal dirs (`objects/`, `refs/`, `logs/`)
- `~/.claude/` and `~/.claude.json`
- `/tmp` and `/private/tmp`

No config surface exists to add extra writable paths (`extraWritePaths` exists in code but is not exposed in `deer.toml`).

## Solution

Detect sandbox environment and use `/tmp` as fallback for DB and cache.

### Detection Strategy

Attempt a real write to `TRACKER_DIR`. This is the only reliable method because:
- Bash `-w` test checks permission bits, not actual sandbox enforcement. macOS `sandbox-exec` (used by SRT) intercepts at the syscall level - the directory still has `rwx` bits but writes are blocked by the kernel extension. `-w` returns true, actual writes fail.
- Env var checks (`CLAUDE_CODE_OAUTH_TOKEN=proxy-managed`) are fragile and deer-specific.
- Process tree inspection (`pgrep srt`) adds latency and may not work in all sandbox runtimes.

The probe-write approach is sandbox-agnostic and adds ~2ms overhead (one `touch` + one `rm`).

### Changes

#### 1. `scripts/tracker.sh` - Sandbox-aware path resolution

Add after line 11 (`CACHE="${CACHE:-$TRACKER_DIR/status_cache}"`):

```bash
# -- sandbox fallback ------------------------------------------------
# If TRACKER_DIR is not writable (e.g., deer/deerbox SRT sandbox),
# fall back to /tmp. The host-side tracker keeps the real DB; sandbox
# sessions write to a temp DB that the host merges on refresh.
#
# Detection: attempt a real write probe. Bash's `-w` only checks
# permission bits, which are unchanged inside macOS sandbox-exec.
# The sandbox intercepts at the syscall level, so `-w` returns true
# but actual writes fail. A probe write is the only reliable test.
_SANDBOX=0
if [[ -d "$TRACKER_DIR" ]]; then
    _probe="$TRACKER_DIR/.sandbox-probe.$$"
    if ! touch "$_probe" 2>/dev/null; then
        _SANDBOX=1
        DB="/tmp/tmux-claude-agent-tracker-sandbox.db"
        CACHE="/tmp/tmux-claude-agent-tracker-sandbox-cache"
    else
        rm -f "$_probe" 2>/dev/null
    fi
    unset _probe
fi
```

#### 2. `scripts/tracker.sh` - Sandbox-aware init

`cmd_init` must handle both paths. When `_SANDBOX=1`, init the temp DB instead.

**Important**: Use `CREATE TABLE IF NOT EXISTS` (not `DROP TABLE + CREATE`). Multiple concurrent deerbox instances share the same `/tmp` sandbox DB. Dropping the table would destroy other sessions.

```bash
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
    # ... existing init code ...
}
```

#### 3. `scripts/tracker.sh` - Suppress tmux calls in sandbox

All `tmux` calls will fail in the sandbox (no socket access). Wrap them:

```bash
_tmux() {
    [[ "$_SANDBOX" -eq 1 ]] && return 0
    tmux "$@"
}
```

Replace bare `tmux` calls **in the hook path only** with `_tmux`. Host-only commands (menu, status-bar, goto, refresh, merge-sandbox) keep bare `tmux` since they never run in sandbox.

Hook-path locations to replace:
- `_ensure_session` line ~248: `tmux display-message`
- `_hook_stop` line ~379: `tmux run-shell`
- `cmd_hook` line ~192-195: `tmux refresh-client -S`
- `_render_cache`: `tmux set` (called from hook path)
- `_write_cache`: `tmux set` (called from hook path)

#### 4. `scripts/tracker.sh` - Sandbox `_ensure_session` adjustments

In sandbox mode, `TMUX_PANE` is empty (unless user sets `env_passthrough_extra`). The session still registers but without pane info. The host-side merge (step 6) picks it up.

Mark sandbox sessions with `agent_client='deer'` so the host can distinguish them in the menu:

```bash
case "$event" in
    SessionStart)
        local _client="claude"
        [[ "$_SANDBOX" -eq 1 ]] && _client="deer"
        _ensure_session "$sid" "$json" "idle" "$_client" ;;
    UserPromptSubmit)
        local _client="claude"
        [[ "$_SANDBOX" -eq 1 ]] && _client="deer"
        _ensure_session "$sid" "$json" "working" "$_client" ;;
esac
```

Also skip `_reap_dead` in sandbox mode (no tmux pane list to cross-reference):

```bash
case "$event" in
    SessionStart|UserPromptSubmit)
        [[ "$_SANDBOX" -eq 0 ]] && _reap_dead 2>/dev/null || true ;;
esac
```

Skip `_ensure_schema` in sandbox mode (sandbox DB is created fresh with latest schema, migration marker files can't be written to `TRACKER_DIR`):

```bash
cmd_hook() {
    [[ -f "$DB" ]] || return 0
    [[ "$_SANDBOX" -eq 0 ]] && _ensure_schema
    # ... rest of cmd_hook ...
}
```

#### 5. `scripts/tracker.sh` - `_load_config_fast` sandbox fallback

Config cache is also not writable. Use hardcoded defaults in sandbox:

```bash
_load_config_fast() {
    [[ -n "${COLOR_WORKING:-}" ]] && return 0
    if [[ "$_SANDBOX" -eq 1 ]]; then
        # Hardcode defaults - no tmux option access in sandbox
        COLOR_WORKING="black"; COLOR_BLOCKED="black"
        COLOR_IDLE="black"; COLOR_COMPLETED="black"
        ICON_IDLE="."; ICON_WORKING="*"
        ICON_COMPLETED="+"; ICON_BLOCKED="!"
        COMPLETED_DELAY=3; DEBUG_LOG=0; _HAS_HOOKS=0
        return 0
    fi
    local _cc="$TRACKER_DIR/config_cache"
    if [[ -f "$_cc" ]]; then
        source "$_cc"
    else
        load_config 2>/dev/null || true
    fi
}
```

#### 6. `scripts/tracker.sh` - Host-side merge command

New command `cmd_merge_sandbox` that the host tracker runs periodically to pull sandbox sessions into the real DB. This runs on the host only (from `cmd_refresh`), so bare `tmux` calls are correct.

```bash
cmd_merge_sandbox() {
    local sandbox_db="/tmp/tmux-claude-agent-tracker-sandbox.db"
    [[ -f "$sandbox_db" ]] || return 0

    # Import sandbox sessions into host DB.
    # INSERT OR REPLACE: sandbox is authoritative for its sessions.
    # Safe because session IDs are globally unique (UUID from Claude Code).
    sqlite3 "$DB" <<SQL
ATTACH '$sandbox_db' AS sandbox;
INSERT OR REPLACE INTO sessions
    SELECT * FROM sandbox.sessions;
DETACH sandbox;
SQL

    _render_cache 2>/dev/null || true
    tmux refresh-client -S 2>/dev/null || true
}
```

Add to the `cmd_refresh` path so it runs every `status-interval`:

```bash
cmd_refresh() {
    # ... existing refresh logic ...

    # Merge sandbox sessions if any
    cmd_merge_sandbox 2>/dev/null || true
}
```

Expose as a standalone command for manual use:

```bash
# In the command dispatch (case block at bottom of tracker.sh):
merge-sandbox) cmd_merge_sandbox ;;
```

#### 7. Auto-init sandbox DB on first hook

The sandbox Claude Code session won't run `tmux-claude-agent-tracker init`. Add auto-init:

```bash
# After _SANDBOX detection block:
if [[ "$_SANDBOX" -eq 1 ]] && [[ ! -f "$DB" ]]; then
    cmd_init
fi
```

### Deer config recommendation

Users should add to `~/.config/deer/config.toml`:

```toml
[sandbox]
env_passthrough_extra = ["TMUX", "TMUX_PANE", "TRACKER_DIR"]
```

Even though tmux commands won't work in the sandbox, forwarding `TMUX_PANE` lets the sandbox session record which pane it belongs to. The host-side merge then has correct pane info.

### Edge cases

- **Multiple concurrent deerbox sessions**: All write to the same `/tmp/` sandbox DB. SQLite WAL handles concurrent writes. Each session has a unique `session_id`. `CREATE TABLE IF NOT EXISTS` prevents one session from destroying another's data.
- **Sandbox DB cleanup**: `cmd_merge_sandbox` could optionally delete merged rows or the file. For simplicity, let normal reaping handle stale sessions. The sandbox DB survives across deerbox runs (persistent in `/tmp` until reboot or manual cleanup).
- **No tmux in sandbox**: All tmux calls are no-ops via `_tmux` wrapper. The sandbox session tracks state in the temp DB purely for host-side merge.
- **DB schema version**: The sandbox DB is created fresh with `IF NOT EXISTS` using the current schema. No migration needed. `_ensure_schema` is skipped (marker files can't be written).
- **`load_config` in sandbox**: Falls back to hardcoded defaults. No tmux option reads.
- **Debug logging**: `_debug_log` writes to `$TRACKER_DIR/debug.log` which is not writable in sandbox. Existing `|| return 0` guard handles this silently. Optionally redirect to `/tmp/tmux-claude-agent-tracker-sandbox.log` when `_SANDBOX=1`.
- **Probe write cost**: ~2ms per hook invocation (one `touch` + one `rm`). Acceptable given hooks already take ~65-77ms. Each hook is a new bash process, so the probe cannot be cached across invocations.
- **`TRACKER_DIR` does not exist**: If the directory was never created (no `init` ran), `[[ -d "$TRACKER_DIR" ]]` returns false, `_SANDBOX` stays 0. This is correct - not a sandbox, just uninitialized. Normal `cmd_init` handles this case.
- **Pane eviction after merge**: Host's `_ensure_session` evicts other sessions on the same pane. Sandbox sessions have empty panes, so they are never evicted by pane-based logic.

### Files changed

| File | Change |
|------|--------|
| `scripts/tracker.sh` | Sandbox detection (probe write), `_tmux` wrapper, `_load_config_fast` fallback, skip `_ensure_schema`/`_reap_dead`, `agent_client='deer'`, `cmd_merge_sandbox`, auto-init, `merge-sandbox` command |
| `ARCHITECTURE.md` | Document sandbox support section, update process boundaries diagram |
| `tests/tracker.bats` | Add sandbox mode tests (detection, init, tmux suppression, config defaults) |
| `tests/integration.bats` | Add sandbox merge tests, concurrent deerbox session tests |

### Testing

```bash
# Simulate sandbox: make TRACKER_DIR read-only via macOS sandbox-exec
# (mirrors how deer's SRT actually blocks writes)
sandbox-exec -p '(version 1)(allow default)(deny file-write* (subpath "/tmp/test-tracker-sandbox"))' \
  bash -c '
    export TRACKER_DIR=/tmp/test-tracker-sandbox
    echo "{\"session_id\":\"test-sandbox\",\"cwd\":\"/tmp\"}" | \
      ~/Code/tmux-claude-agent-tracker/scripts/tracker.sh hook SessionStart
  '

# Verify sandbox DB created in /tmp
sqlite3 /tmp/tmux-claude-agent-tracker-sandbox.db \
  "SELECT session_id, status FROM sessions;"

# Verify host merge
~/Code/tmux-claude-agent-tracker/scripts/tracker.sh merge-sandbox
sqlite3 ~/.tmux-claude-agent-tracker/tracker.db \
  "SELECT session_id, status FROM sessions WHERE session_id='test-sandbox';"

# Fallback: chmod-based test (simpler, doesn't need sandbox-exec)
mkdir -p /tmp/test-tracker-sandbox
chmod 555 /tmp/test-tracker-sandbox
TRACKER_DIR=/tmp/test-tracker-sandbox \
  echo '{"session_id":"test-chmod","cwd":"/tmp"}' | \
  ~/Code/tmux-claude-agent-tracker/scripts/tracker.sh hook SessionStart
chmod 755 /tmp/test-tracker-sandbox  # restore
```
