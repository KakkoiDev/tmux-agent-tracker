#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── confirmation ─────────────────────────────────────────────────────

echo "This will remove tmux-claude-agent-tracker and all its artifacts:"
echo ""
echo "  - CLI symlink (~/.local/bin/tmux-claude-agent-tracker)"
echo "  - tmux.conf plugin line"
echo "  - Claude Code hooks (settings.json)"
echo "  - Gemini CLI hooks (~/.gemini/settings.json)"
echo "  - Pi hooks (~/.pi/agent/settings.json)"
echo "  - Codex notify hook (~/.codex/config.toml)"
echo "  - Skill folders (~/.claude/skills and ~/.codex/skills)"
echo "  - Data directory (~/.tmux-claude-agent-tracker/)"
echo "  - Live tmux state (status bar, hooks, options)"
echo ""
printf "Continue? [y/N] "
read -r answer
[[ "$answer" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }

echo ""

# ── CLI symlinks ─────────────────────────────────────────────────────

for link in "$HOME/.local/bin/tmux-claude-agent-tracker"; do
    if [[ -L "$link" || -f "$link" ]]; then
        rm -f "$link"
        echo "Removed: $link"
    fi
done

# ── tmux.conf ────────────────────────────────────────────────────────

TMUX_CONF="$HOME/.tmux.conf"
if [[ -f "$TMUX_CONF" ]] && grep -q "claude-tracker.tmux" "$TMUX_CONF" 2>/dev/null; then
    # Platform-aware sed in-place
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i '/# Claude Agent Tracker/d; /claude-tracker\.tmux/d' "$TMUX_CONF"
    else
        sed -i '' '/# Claude Agent Tracker/d; /claude-tracker\.tmux/d' "$TMUX_CONF"
    fi
    # Remove trailing blank lines left behind
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$TMUX_CONF"
    else
        sed -i '' -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$TMUX_CONF"
    fi
    echo "Removed: tmux.conf plugin lines"
fi

# ── Claude Code hooks ───────────────────────────────────────────────

CLAUDE_SETTINGS="$HOME/.claude/settings.json"
if [[ -f "$CLAUDE_SETTINGS" ]]; then
    if command -v jq >/dev/null 2>&1; then
        tmp="${CLAUDE_SETTINGS}.tmp"
        # Remove hook entries where command matches tmux-claude-agent-tracker
        jq '
            if .hooks then
                .hooks |= with_entries(
                    .value |= map(
                        .hooks |= map(select(.command | test("tmux-claude-agent-tracker") | not))
                        | select(.hooks | length > 0)
                    )
                    | select(.value | length > 0)
                )
                | if (.hooks | length) == 0 then del(.hooks) else . end
            else . end
        ' "$CLAUDE_SETTINGS" > "$tmp" && mv "$tmp" "$CLAUDE_SETTINGS"
        echo "Removed: Claude Code hooks from settings.json"
    else
        echo ""
        echo "jq not found. Manually remove hooks containing 'tmux-claude-agent-tracker' from:"
        echo "  $CLAUDE_SETTINGS"
        echo ""
    fi
fi

# ── Gemini CLI hooks ────────────────────────────────────────────────

GEMINI_SETTINGS="$HOME/.gemini/settings.json"
if [[ -f "$GEMINI_SETTINGS" ]]; then
    if command -v jq >/dev/null 2>&1; then
        tmp="${GEMINI_SETTINGS}.tmp"
        # Remove hook entries where command matches tmux-claude-agent-tracker
        jq '
            if .hooks then
                .hooks |= with_entries(
                    .value |= map(
                        .hooks |= map(select(.command | test("tmux-claude-agent-tracker") | not))
                        | select(.hooks | length > 0)
                    )
                    | select(.value | length > 0)
                )
                | if (.hooks | length) == 0 then del(.hooks) else . end
            else . end
        ' "$GEMINI_SETTINGS" > "$tmp" && mv "$tmp" "$GEMINI_SETTINGS"
        echo "Removed: Gemini CLI hooks from settings.json"
    else
        echo ""
        echo "jq not found. Manually remove hooks containing 'tmux-claude-agent-tracker' from:"
        echo "  $GEMINI_SETTINGS"
        echo ""
    fi
fi

# ── Pi hooks ─────────────────────────────────────────────────────────

PI_SETTINGS="$HOME/.pi/agent/settings.json"
if [[ -f "$PI_SETTINGS" ]]; then
    if command -v jq >/dev/null 2>&1; then
        tmp="${PI_SETTINGS}.tmp"
        # Remove hook entries where command matches tmux-claude-agent-tracker
        jq '
            if .hooks then
                .hooks |= with_entries(
                    .value |= map(
                        .hooks |= map(select(.command | test("tmux-claude-agent-tracker") | not))
                        | select(.hooks | length > 0)
                    )
                    | select(.value | length > 0)
                )
                | if (.hooks | length) == 0 then del(.hooks) else . end
            else . end
        ' "$PI_SETTINGS" > "$tmp" && mv "$tmp" "$PI_SETTINGS"
        echo "Removed: Pi hooks from $PI_SETTINGS"
    else
        echo ""
        echo "jq not found. Manually remove hooks containing 'tmux-claude-agent-tracker' from:"
        echo "  $PI_SETTINGS"
        echo ""
    fi
fi

# ── Codex notify hook ───────────────────────────────────────────────

CODEX_CONFIG="$HOME/.codex/config.toml"
if [[ -f "$CODEX_CONFIG" ]]; then
    if grep -Fq '"tmux-claude-agent-tracker", "codex-notify"' "$CODEX_CONFIG"; then
        if sed --version 2>/dev/null | grep -q GNU; then
            sed -i '/# tmux-claude-agent-tracker/d; /tmux-claude-agent-tracker", "codex-notify/d' "$CODEX_CONFIG"
        else
            sed -i '' '/# tmux-claude-agent-tracker/d; /tmux-claude-agent-tracker", "codex-notify/d' "$CODEX_CONFIG"
        fi
        echo "Removed: Codex notify hook from config.toml"
    fi
fi

# ── Skill folders ────────────────────────────────────────────────────

for skills_root in "$HOME/.claude/skills" "${CODEX_HOME:-$HOME/.codex}/skills"; do
    for skill_name in tmux-claude-agent-tracker tmux-claude-agent-tracker-dev; do
        skill_dir="$skills_root/$skill_name"
        if [[ -d "$skill_dir" ]]; then
            rm -rf "$skill_dir"
            echo "Removed: $skill_dir"
        fi
    done
done

# ── Data directory ───────────────────────────────────────────────────

DATA_DIR="$HOME/.tmux-claude-agent-tracker"
if [[ -d "$DATA_DIR" ]]; then
    rm -rf "$DATA_DIR"
    echo "Removed: $DATA_DIR"
fi

# ── Live tmux state ──────────────────────────────────────────────────

if tmux info >/dev/null 2>&1; then
    # Strip tracker injection from status-right
    current_status_right=$(tmux show-option -gqv status-right 2>/dev/null || true)
    if [[ "$current_status_right" == *"tracker.sh"* ]] || [[ "$current_status_right" == *"@claude-tracker-status"* ]]; then
        cleaned=$(printf '%s' "$current_status_right" | sed -E \
            -e 's~#\{@claude-tracker-status\}~~g' \
            -e 's~#\([^)]*tracker\.sh (status-bar|refresh)\) \| ~~g' \
            -e 's~#\([^)]*tracker\.sh (status-bar|refresh)\)~~g')
        tmux set -g status-right "$cleaned"
        echo "Cleaned: status-right"
    fi

    # Remove tmux hooks referencing tracker.sh
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        hook_name=$(echo "$line" | sed -E 's/^([^ ]+)\[([0-9]+)\].*/\1/' )
        hook_idx=$(echo "$line" | sed -E 's/^[^ ]+\[([0-9]+)\].*/\1/')
        tmux set-hook -gu "${hook_name}[${hook_idx}]" 2>/dev/null || true
    done < <(tmux show-hooks -g 2>/dev/null | grep "tracker\.sh" || true)
    echo "Cleaned: tmux hooks"

    # Clear tracker status option
    tmux set -gu @claude-tracker-status 2>/dev/null || true

    # Unbind menu key
    keybinding=$(tmux show-option -gqv @claude-tracker-keybinding 2>/dev/null || true)
    keybinding="${keybinding:-a}"
    tmux unbind-key "$keybinding" 2>/dev/null || true
    echo "Unbound: prefix + $keybinding"

    # Clear all @claude-tracker-* options
    while IFS= read -r opt; do
        [[ -z "$opt" ]] && continue
        opt_name=$(echo "$opt" | awk '{print $1}')
        tmux set -gu "$opt_name" 2>/dev/null || true
    done < <(tmux show-options -g 2>/dev/null | grep "@claude-tracker-" || true)
    echo "Cleaned: tmux options"
fi

echo ""
echo "Done. tmux-claude-agent-tracker has been fully removed."
