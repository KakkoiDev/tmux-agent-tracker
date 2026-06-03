# Bug Fix: exit 127 ("command not found") on tmux-agent-tracker

**Date:** 2026-06-03
**Reporter:** Cyril Antoni
**Root cause:** Stale `tmux-claude-agent-tracker` path after project rename to `tmux-agent-tracker`

---

## Symptoms

```
Error: Hook 失败 (exit 127): bash: tmux-agent-tracker: command not found
Error: UserPromptSubmit 失败 (exit 127): bash: tmux-agent-tracker: command not found
```

```
entering tmux → '$HOME/Code/tmux-claude-agent-tracker/scripts/tracker.sh pane-focus %7' returned 127
```

---

## Root Cause

The project was renamed from `tmux-claude-agent-tracker` to `tmux-agent-tracker` (commit `236e45d`). The repo directory was moved from `~/Code/tmux-claude-agent-tracker/` to `~/Code/tmux-agent-tracker/`. Several config files still reference the old path.

---

## Files to Fix

### 1. `~/.tmux.conf` — Stale run-shell path

```
run-shell '$HOME/Code/tmux-claude-agent-tracker/agent-tracker.tmux'
```

Fix: change to the new path.

```
run-shell '$HOME/Code/tmux-agent-tracker/agent-tracker.tmux'
```

**Why:** tmux loads this config on startup. The old directory doesn't exist → exit 127.

---

### 2. `tmux-agent-tracker` CLI not in PATH

The pi-hooks config commands use `tmux-agent-tracker hook <event>`:

```json
{
  "type": "command",
  "command": "tmux-agent-tracker hook SessionStart"
}
```

The install script (`install.sh`) creates symlinks at:

```bash
~/.local/bin/tmux-agent-tracker   → bin/tmux-agent-tracker → scripts/tracker.sh
~/.local/bin/claude-agent-tracker → bin/tmux-agent-tracker → scripts/tracker.sh
```

Fix if missing: re-run the install script.

```bash
cd ~/Code/tmux-agent-tracker && bash install.sh
```

This re-creates the symlinks pointing to the correct path.

**Why:** Pi hooks call `tmux-agent-tracker` as a bare command. If the symlink is stale (points to old dir) or missing, bash returns exit 127.

---

### 3. `agent_status.conf` tmux status-right

File: `~/dotfiles/config/tmux/agent_status.conf`

```
set -g status-right "#(claude-agent-tracker status-bar) | %H:%M %d-%b-%y"
bind-key a run-shell "claude-agent-tracker menu"
```

The `claude-agent-tracker` binary should be in PATH (via `/usr/local/bin/claude-agent-tracker` → `tracker.sh`). If re-running `install.sh` fixes the symlink, this works without changes.

---

### 4. Verify `tracker.sh` has execute permission

```bash
chmod +x ~/Code/tmux-agent-tracker/scripts/tracker.sh
chmod +x ~/Code/tmux-agent-tracker/agent-tracker.tmux
```

---

## Verification

After fixes, run:

```bash
# Test CLI is in PATH (installed to ~/.local/bin)
which tmux-agent-tracker
# → $HOME/.local/bin/tmux-agent-tracker

# Test it works
tmux-agent-tracker init

# Reload tmux config
tmux source-file ~/.tmux.conf

# Check status bar
tmux-agent-tracker status-bar

# Verify no 127 errors
grep -r "tmux-claude-agent-tracker" ~/.tmux.conf ~/dotfiles/
# → no matches
```

---

## Summary

| File | Stale path | Fix |
|------|-----------|-----|
| `~/.tmux.conf` | `tmux-claude-agent-tracker/agent-tracker.tmux` | `tmux-agent-tracker/agent-tracker.tmux` |
| `/usr/local/bin/tmux-agent-tracker` | May point to old dir | Re-run `install.sh` |
| `/usr/local/bin/claude-agent-tracker` | May point to old dir | Re-run `install.sh` |
