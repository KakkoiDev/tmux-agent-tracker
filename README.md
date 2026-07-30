# tmux-agent-tracker

> `lib/` is vendored from [tmux-toolkit](https://github.com/KakkoiDev/tmux-toolkit)
> via `git subtree`; do not edit it in place, CI fails on drift. If you are an agent
> picking up in-flight work on this plugin, start at
> [tmux-toolkit `docs/RESUME.md`](https://github.com/KakkoiDev/tmux-toolkit/blob/main/docs/RESUME.md).

Track [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Gemini CLI](https://github.com/google-gemini/gemini-cli), [Antigravity (`agy`)](https://antigravity.google), [Pi coding agent](https://github.com/earendil-works/pi), and Codex agent sessions in your tmux status bar. Hook-driven, no daemon, no polling.

## Status Bar

```
0. 2* 1+ 1!3m
```

| Symbol | Meaning |
|--------|---------|
| `0.` | 0 idle |
| `2*` | 2 working |
| `1+` | 1 completed (output ready) |
| `1!3m` | 1 blocked for 3m (longest wait) |

Completed (`+`) auto-clears to idle when you focus the pane.

## Menu

`prefix + a` opens the agent list. Select to jump to pane.

```
AI Agents
─────────────
! [claude] project-a/main
+ [gemini] project-b/feature
* [claude] project-c/dev
. [codex] project-d/fix
─────────────
Quit      q
```

## How It Works

- Claude Code, Gemini CLI, and Pi hooks fire on session events (start, stop, tool use, permission, failure)
- Codex `notify` events are mapped into tracker state transitions
- Each hook writes to a local SQLite database and pushes to a tmux option (~35ms)
- `refresh-client -S` triggers instant display via `#{@agent-tracker-status}`
- A periodic `#()` refresh keeps the blocked timer current
- Dead sessions are automatically reaped via tmux pane cross-referencing

No background daemon. No polling. Pure event-driven tracking.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full design.

## Platform Support

- **macOS** and **Linux**
- Claude Code **native binary** and **npm/node** installs
- Gemini CLI v0.26.0+
- Bash 3.2+ (macOS default) and Bash 4+/5+ (Linux)

## Deer Sandbox Support

Sessions running inside [deer/deerbox](https://github.com/zdavison/deer) sandboxes are automatically detected via host-side process scanning. The tracker identifies `deerbox` as a child process and registers the session with `[deer]` client tag.

```
AI Agents
─────────────
* [claude] project-a/main
. [deer]   project-b/feature
```

**How it works**: Deer's SRT sandbox blocks hook execution (PATH is not available inside the sandbox). Instead of hooks, the tracker's periodic `cmd_scan` detects `deerbox` processes on tmux panes and registers them in the host database. Select a deer session in the menu to navigate to its pane.

**Limitation**: Deer sessions show as idle (`.`) regardless of actual agent state. Full status tracking (working/blocked/completed) requires hooks, which cannot fire inside the sandbox. The session is cleaned up automatically when deerbox exits.

## Install

### Requirements

- `tmux 3.0+`
- `sqlite3`
- `jq` (optional -- enables automatic Claude Code hook configuration)

### Quick Start

```bash
git clone https://github.com/KakkoiDev/tmux-agent-tracker.git ~/.tmux/plugins/tmux-agent-tracker
cd ~/.tmux/plugins/tmux-agent-tracker && ./install.sh
```

The install script:
1. Symlinks the CLI to `~/.local/bin/`
2. Initializes the SQLite database
3. Adds the plugin to `~/.tmux.conf`
4. Configures Claude Code hooks in `~/.claude/settings.json` (requires `jq`)
5. Configures Gemini CLI hooks in `~/.gemini/settings.json` (if `~/.gemini` exists)
6. Configures Codex notify hook in `~/.codex/config.toml`
7. Configures Pi hooks in `~/.pi/agent/settings.json` (if Pi and pi-hooks are installed)
7. Copies skill bundles to `~/.claude/skills/` and `~/.codex/skills/`

If `jq` is not installed, the script prints the hook JSON for manual configuration.

## Hook Setup (Claude + Gemini + Codex)

### Automatic (recommended)

Run:

```bash
~/.tmux/plugins/tmux-agent-tracker/install.sh --hooks-only
```

This configures:
- Claude Code hooks in `~/.claude/settings.json`
- Gemini CLI hooks in `~/.gemini/settings.json` (if `~/.gemini` exists)
- Codex notify hook in `~/.codex/config.toml`

Verify:

```bash
jq '.hooks | keys' ~/.claude/settings.json
jq '.hooks | keys' ~/.gemini/settings.json  # if using Gemini CLI
rg -n 'notify\\s*=\\s*\\[.*tmux-agent-tracker.*codex-notify' ~/.codex/config.toml
jq '.hooks | keys' ~/.pi/agent/settings.json  # if using Pi
```

### Pi hooks setup

Pi requires the [pi-hooks](https://npmjs.com/package/@hsingjui/pi-hooks) extension package to bridge Pi's extension events to Claude Code-compatible hook commands.

#### Automatic (recommended)

Run:

```bash
~/.tmux/plugins/tmux-agent-tracker/install.sh --hooks-only
```

This configures Pi hooks in `~/.pi/agent/settings.json` (if Pi and pi-hooks are detected).

#### Prerequisites

1. Install pi-hooks:
   ```bash
   pi install npm:@hsingjui/pi-hooks
   ```
2. Verify it's installed:
   ```bash
   ls ~/.pi/agent/npm/node_modules/@hsingjui/pi-hooks
   ```

#### Manual setup

Add to `~/.pi/agent/settings.json`:

```json
{
  "use": {
    "extension": ["pi-hooks"]
  },
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

Then restart Pi.

#### Limitations

Pi does not have permission dialogs like Claude Code, so **no `blocked` state** is possible. Pi sessions only cycle through `idle → working → completed`. The `Notification` and `PermissionRequest` hooks are not available.

See [ARCHITECTURE.md](ARCHITECTURE.md#pi-integration) for details.

### Antigravity hooks setup

Antigravity (`agy`) uses a global `hooks.json` file at `~/.gemini/config/hooks.json`. Hooks receive `conversationId` as the session identifier.

#### Automatic (recommended)

Run:

```bash
~/.tmux/plugins/tmux-agent-tracker/install.sh --hooks-only
```

This creates or updates `~/.gemini/config/hooks.json` with a `"tmux-agent-tracker"` block.

Verify:

```bash
jq '."tmux-agent-tracker"' ~/.gemini/config/hooks.json
```

#### Manual setup

Add to `~/.gemini/config/hooks.json`:

```json
{
  "tmux-agent-tracker": {
    "enabled": true,
    "SessionStart": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook SessionStart" }] }],
    "SessionEnd": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook SessionEnd" }] }],
    "PreInvocation": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook UserPromptSubmit" }] }],
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook Stop" }] }],
    "PreToolUse": [{ "matcher": "ask_permission|ask_question", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook PermissionRequest" }] }],
    "PostToolUse": [{ "matcher": "ask_permission|ask_question", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook PostToolUse" }] }]
  }
}
```

Then restart `agy`.

#### Event mapping

| Antigravity event | Tracker hook | State change |
|---|---|---|
| `SessionStart` | `SessionStart` | → idle |
| `PreInvocation` | `UserPromptSubmit` | → working |
| `PostToolUse` (permission tools) | `PostToolUse` | → working |
| `PreToolUse` (permission tools) | `PermissionRequest` | → blocked |
| `Stop` | `Stop` | → completed |
| `SessionEnd` | `SessionEnd` | delete row |

#### Limitations

Antigravity does not expose a direct `blocked` hook for all permission prompts. The `PreToolUse` matcher on `ask_permission|ask_question` catches the tracker's own permission requests; other gating dialogs will not trigger the `blocked` state.

### Manual setup

Claude (`~/.claude/settings.json`):

```json
{
  "hooks": {
    "SessionStart": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook SessionStart" }] }],
    "SessionEnd": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook SessionEnd" }] }],
    "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook UserPromptSubmit" }] }],
    "PostToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook PostToolUse" }] }],
    "PostToolUseFailure": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook PostToolUseFailure" }] }],
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook Stop" }] }],
    "StopFailure": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook StopFailure" }] }],
    "Notification": [{ "matcher": "permission_prompt|elicitation_dialog", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook Notification" }] }],
    "PermissionRequest": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook PermissionRequest" }] }],
    "Elicitation": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook Elicitation" }] }],
    "ElicitationResult": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook ElicitationResult" }] }],
    "TaskCompleted": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook TaskCompleted" }] }]
  }
}
```

Codex (`~/.codex/config.toml`):

```toml
notify = ["tmux-agent-tracker", "codex-notify"]
```

## Skill Install (Claude + Codex)

Install or refresh bundled skills in both locations:

```bash
PLUGIN_DIR="$HOME/.tmux/plugins/tmux-agent-tracker"
for skill_src in "$PLUGIN_DIR"/.claude/skills/tmux-agent-tracker*; do
  skill_name="$(basename "$skill_src")"
  mkdir -p "$HOME/.claude/skills/$skill_name" "${CODEX_HOME:-$HOME/.codex}/skills/$skill_name"
  cp -Rf "$skill_src/." "$HOME/.claude/skills/$skill_name/"
  cp -Rf "$skill_src/." "${CODEX_HOME:-$HOME/.codex}/skills/$skill_name/"
done
```

### TPM

```bash
set -g @plugin 'KakkoiDev/tmux-agent-tracker'
```

Then `prefix + I` to install. TPM runs `agent-tracker.tmux` which automatically provisions CLI symlinks and syncs skill bundles into Claude and Codex skill folders. You only need to run the hook installer once:

```bash
~/.tmux/plugins/tmux-agent-tracker/install.sh --hooks-only
```

## Uninstall

```bash
cd ~/.tmux/plugins/tmux-agent-tracker && ./uninstall.sh
```

Removes all artifacts: CLI symlinks, tmux.conf lines, Claude Code hooks, Gemini CLI hooks, Codex notify hook, Claude/Codex skill folders, data directory, and live tmux state.

## Configuration

Set in `~/.tmux.conf`:

### Display

| Option | Default | Purpose |
|--------|---------|---------|
| `@agent-tracker-keybinding` | `a` | Menu key (after prefix) |
| `@agent-tracker-items-per-page` | `10` | Menu page size |
| `@agent-tracker-key-next` | `i` | Next page |
| `@agent-tracker-key-prev` | `o` | Previous page |
| `@agent-tracker-key-quit` | `q` | Quit menu |
| `@agent-tracker-show-project` | `0` | `1` to show project name |
| `@agent-tracker-max-name-length` | `40` | Truncate long menu names with `…` (`0` to disable) |
| `@agent-tracker-status-interval` | `60` | Blocked timer refresh (seconds) |
| `@agent-tracker-completed-delay` | `3` | Seconds to show completed before auto-clear (`0` to disable) |

### Colors

| Option | Default | Purpose |
|--------|---------|---------|
| `@agent-tracker-color-working` | `black` | Working count color |
| `@agent-tracker-color-blocked` | `black` | Blocked count color |
| `@agent-tracker-color-idle` | `black` | Idle count color |
| `@agent-tracker-color-completed` | `black` | Completed count color |

```bash
set -g @agent-tracker-color-working 'green'
set -g @agent-tracker-color-blocked 'red'
set -g @agent-tracker-color-idle 'yellow'
```

### Icons

Customize the status bar indicators:

| Option | Default | Purpose |
|--------|---------|---------|
| `@agent-tracker-icon-idle` | `.` | Idle indicator |
| `@agent-tracker-icon-working` | `*` | Working indicator |
| `@agent-tracker-icon-completed` | `+` | Completed indicator |
| `@agent-tracker-icon-blocked` | `!` | Blocked indicator |

```bash
set -g @agent-tracker-icon-idle '💤'
set -g @agent-tracker-icon-working '🔨'
set -g @agent-tracker-icon-completed '✅'
set -g @agent-tracker-icon-blocked '🔴'
```

### State Transition Hooks

Run shell commands when an agent changes state. Each command receives 5 arguments: `$1=from_state $2=to_state $3=session_id $4=project_name $5=prompt_summary`. Commands run asynchronously (backgrounded).

| Option | Default | Fires on |
|--------|---------|----------|
| `@agent-tracker-on-working` | `""` | Any state -> working |
| `@agent-tracker-on-completed` | `""` | Any state -> completed |
| `@agent-tracker-on-blocked` | `""` | Any state -> blocked |
| `@agent-tracker-on-idle` | `""` | Any state -> idle |
| `@agent-tracker-on-transition` | `""` | Any state change (catch-all) |

```bash
# Desktop notification when blocked
set -g @agent-tracker-on-blocked 'notify-send "Claude blocked" "Agent in $4 needs attention"'

# Sound alert when completed or blocked
set -g @agent-tracker-on-completed 'paplay /usr/share/sounds/freedesktop/stereo/complete.oga'
set -g @agent-tracker-on-blocked 'paplay /usr/share/sounds/freedesktop/stereo/complete.oga'

# macOS equivalents
set -g @agent-tracker-on-completed 'afplay /System/Library/Sounds/Glass.aiff'
set -g @agent-tracker-on-blocked 'afplay /System/Library/Sounds/Glass.aiff'

# Phone push notifications via ntfy.sh (free, no account needed)
# 1. Install ntfy app on phone (App Store / Google Play)
# 2. Pick a unique topic name:
#      echo "claude-$(openssl rand -hex 4)"
# 3. Subscribe to that topic in the ntfy app
# 4. Add hooks (replace MY_TOPIC with your topic name):
set -g @agent-tracker-on-blocked '/usr/bin/curl -s -d "[$4] Blocked: $5" ntfy.sh/MY_TOPIC'
set -g @agent-tracker-on-completed '/usr/bin/curl -s -d "[$4] Completed: $5" ntfy.sh/MY_TOPIC'
```

### Phone Push Notifications (ntfy.sh)

Get push notifications on your phone when agents finish or need attention. Uses [ntfy.sh](https://ntfy.sh) - free, no account, no signup.

**1. Generate a private topic ID:**

```bash
echo "claude-$(openssl rand -hex 4)"
# Output: claude-2bb1234q (your ID will differ)
```

**2. Subscribe on your phone:**

- Install the ntfy app ([App Store](https://apps.apple.com/app/ntfy/id1625396347) / [Google Play](https://play.google.com/store/apps/details?id=io.heckel.ntfy))
- Tap **+** and subscribe to your topic (e.g. `claude-2bb1234q`)

**3. Add hooks to `~/.tmux.conf`** (replace `claude-2bb1234q` with your topic):

```bash
set -g @agent-tracker-on-blocked 'curl -s -d "Agent in $4 needs attention" ntfy.sh/claude-2bb1234q'
set -g @agent-tracker-on-completed 'curl -s -d "Agent in $4 finished" ntfy.sh/claude-2bb1234q'
```

**4. Test it:**

```bash
curl -s -d "Test notification" ntfy.sh/claude-2bb1234q
```

Reload tmux (`tmux source ~/.tmux.conf`) and you'll get push notifications whenever an agent blocks or completes.

## Remote Access (Phone / Tablet)

Access your tmux sessions from a phone or tablet using [Tailscale](https://tailscale.com) + SSH. Tailscale creates an encrypted WireGuard tunnel — no port forwarding, no dynamic DNS.

### Linux

```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Enable Tailscale SSH (authenticates via Tailscale identity, no SSH keys needed)
sudo tailscale up --ssh

# Install SSH server if not already present
sudo apt install openssh-server   # Debian/Ubuntu
sudo dnf install openssh-server   # Fedora
```

### macOS

```bash
# Install Tailscale via Mac App Store or Homebrew
brew install --cask tailscale

# Open Tailscale from Applications — sign in and enable SSH in the menu bar icon
# Or from CLI:
sudo tailscale up --ssh

# macOS has SSH built in — enable it:
# System Settings > General > Sharing > Remote Login
```

### Phone Setup

1. Install Tailscale on your phone (App Store / Google Play) and sign in with the same account
2. Install an SSH client — **Termius** (iOS/Android, free) or **Termux** (Android)
3. Get your machine's Tailscale IP: `tailscale ip`
4. SSH from phone: `ssh user@100.x.y.z`
5. Attach to your session: `tmux attach`

### Verify

```bash
tailscale status    # device online
tailscale ip        # 100.x.y.z address
ssh localhost       # SSH works locally
```

## Known Limitations

Claude Code fires the `Notification` hook 4-41s (median ~11s) after the agent actually starts waiting for user input. This is an upstream delay in Claude Code's hook dispatch, not a tracker bug. The tracker processes each hook in ~77ms. No workaround exists since the tracker is purely event-driven and cannot poll Claude Code's internal state.

## License

MIT
