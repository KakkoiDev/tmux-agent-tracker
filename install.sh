#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/bin/tmux-agent-tracker"
LINK="$HOME/.local/bin/tmux-agent-tracker"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CODEX_CONFIG="$HOME/.codex/config.toml"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_SKILLS_DIR="$CODEX_HOME/skills"
HOOKS_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --hooks-only) HOOKS_ONLY=true ;;
    esac
done

# ── dependency check ─────────────────────────────────────────────────

missing=()
for cmd in sqlite3 tmux; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Missing dependencies: ${missing[*]}" >&2
    echo "Install them and re-run." >&2
    exit 1
fi

HAS_JQ=false
command -v jq >/dev/null && HAS_JQ=true

# ── upgrade pre-clean: remove stale pre-rename artifacts ─────────────
# Project was renamed tmux-claude-agent-tracker -> tmux-agent-tracker.
# Without this, a pull + reinstall leaves a broken old CLI symlink, stale
# skills, dead old hooks, and a dead tmux.conf/codex line behind. The old
# command name contains "claude-", which the new "tmux-agent-tracker"
# entries do not, so the old-only filters never touch freshly written ones.
# Delete matching lines in place while following symlinks. BSD `sed -i`
# refuses symlinked targets (e.g. a dotfiles-managed ~/.tmux.conf); the
# temp + cat-redirect writes through the link and preserves it.
_strip_lines() {
    local file="$1" script="$2" tmp
    [[ -f "$file" ]] || return 0
    tmp="$(mktemp)"
    sed "$script" "$file" > "$tmp" && cat "$tmp" > "$file"
    rm -f "$tmp"
}

_upgrade_preclean() {
    # Hooks and the Codex notify line are (re)configured in BOTH modes, so
    # always strip their stale old-name versions.

    # old hook entries in Claude / Gemini / Pi settings (old command name only)
    if $HAS_JQ; then
        local settings t
        for settings in "$HOME/.claude/settings.json" \
                        "$HOME/.gemini/settings.json" \
                        "$HOME/.pi/agent/settings.json"; do
            [[ -f "$settings" ]] || continue
            t="${settings}.preclean"
            if jq '
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
            ' "$settings" > "$t" 2>/dev/null; then
                mv "$t" "$settings"
            else
                rm -f "$t"
            fi
        done
    fi

    # old Codex notify line + comment
    if [[ -f "$CODEX_CONFIG" ]] && grep -Fq '"tmux-claude-agent-tracker", "codex-notify"' "$CODEX_CONFIG"; then
        _strip_lines "$CODEX_CONFIG" '/# tmux-claude-agent-tracker/d; /tmux-claude-agent-tracker", "codex-notify/d'
    fi

    # The CLI symlink, skill dirs, and tmux.conf line are only installed in
    # full mode, so only their cleanup belongs here (a --hooks-only run must
    # not strip the tmux.conf plugin line without re-adding it).
    if ! $HOOKS_ONLY; then
        rm -f "$HOME/.local/bin/tmux-claude-agent-tracker"

        local skills_root
        for skills_root in "$HOME/.claude/skills" "$CODEX_SKILLS_DIR"; do
            rm -rf "$skills_root/tmux-claude-agent-tracker" \
                   "$skills_root/tmux-claude-agent-tracker-dev"
        done

        local tmux_conf="$HOME/.tmux.conf"
        if [[ -f "$tmux_conf" ]] && grep -q "claude-tracker.tmux" "$tmux_conf" 2>/dev/null; then
            _strip_lines "$tmux_conf" '/# Claude Agent Tracker/d; /claude-tracker\.tmux/d'
        fi
    fi

    return 0
}
_upgrade_preclean

# ── hooks-only mode: skip CLI/DB/tmux.conf ───────────────────────────

if ! $HOOKS_ONLY; then

# ── symlink CLI to PATH ─────────────────────────────────────────────

mkdir -p "$(dirname "$LINK")"
ln -sf "$BIN" "$LINK"
echo "CLI: $LINK"

# ── init DB ──────────────────────────────────────────────────────────

"$SCRIPT_DIR/scripts/tracker.sh" init

# ── add plugin to tmux.conf ──────────────────────────────────────────

TMUX_CONF="$HOME/.tmux.conf"
PLUGIN_LINE="run-shell '$SCRIPT_DIR/agent-tracker.tmux'"
if ! grep -qF "agent-tracker.tmux" "$TMUX_CONF" 2>/dev/null; then
    echo "" >> "$TMUX_CONF"
    echo "# Agent Tracker" >> "$TMUX_CONF"
    echo "$PLUGIN_LINE" >> "$TMUX_CONF"
    echo "tmux.conf: added plugin line"
else
    echo "tmux.conf: already configured"
fi

# ── install skill bundles (Claude + Codex) ───────────────────────────

for skill_dir in "$SCRIPT_DIR"/.claude/skills/tmux-agent-tracker*; do
    [[ -d "$skill_dir" ]] || continue
    skill_name="$(basename "$skill_dir")"
    for skills_root in "$HOME/.claude/skills" "$CODEX_SKILLS_DIR"; do
        skill_dest="$skills_root/$skill_name"
        mkdir -p "$skill_dest"
        cp -Rf "$skill_dir/." "$skill_dest/"
        echo "Skill: $skill_dest"
    done
done

fi  # end !HOOKS_ONLY

# ── configure Claude Code hooks ──────────────────────────────────────

TRACKER_EVENTS=(
    SessionStart SessionEnd UserPromptSubmit
    PostToolUse PostToolUseFailure Stop StopFailure Notification PermissionRequest
    Elicitation ElicitationResult
    TaskCompleted
)
# Notification must match only permission_prompt or elicitation_dialog (user attention needed)
_get_matcher() {
    case "$1" in
        Notification) echo "permission_prompt|elicitation_dialog" ;;
        *) echo "" ;;
    esac
}

_print_manual_hooks() {
    cat <<'MANUAL_HOOKS'

Add the following to ~/.claude/settings.json under "hooks":

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
MANUAL_HOOKS
}

install_hooks() {
    if ! $HAS_JQ; then
        echo "hooks: jq not found — skipping auto-configuration"
        _print_manual_hooks
        return
    fi

    if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
        # Create minimal settings with hooks
        local hooks_json="{"
        local first=true
        for event in "${TRACKER_EVENTS[@]}"; do
            $first || hooks_json+=","
            first=false
            local matcher
            matcher=$(_get_matcher "$event")
            hooks_json+="\"$event\":[{\"matcher\":\"$matcher\",\"hooks\":[{\"type\":\"command\",\"command\":\"tmux-agent-tracker hook $event\"}]}]"
        done
        hooks_json+="}"

        jq -n --argjson hooks "$hooks_json" '{
            "$schema": "https://json.schemastore.org/claude-code-settings.json",
            hooks: $hooks
        }' > "$CLAUDE_SETTINGS"
        echo "hooks: created $CLAUDE_SETTINGS with all tracker hooks"
        return
    fi

    # Settings file exists — merge tracker hooks into existing hooks
    local tmp="${CLAUDE_SETTINGS}.tmp"
    local changed=false

    cp "$CLAUDE_SETTINGS" "$tmp"

    # Ensure top-level "hooks" key exists
    if ! jq -e '.hooks' "$tmp" >/dev/null 2>&1; then
        jq '. + {hooks: {}}' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
    fi

    for event in "${TRACKER_EVENTS[@]}"; do
        local cmd="tmux-agent-tracker hook $event"

        # Check if this exact command already exists under this event
        if jq -e --arg event "$event" --arg cmd "$cmd" '
            .hooks[$event] // [] | map(.hooks[]? | select(.command == $cmd)) | length > 0
        ' "$tmp" >/dev/null 2>&1; then
            continue
        fi

        # Append tracker hook entry to this event
        local matcher
            matcher=$(_get_matcher "$event")
        jq --arg event "$event" --arg cmd "$cmd" --arg matcher "$matcher" '
            .hooks[$event] = (.hooks[$event] // []) + [{
                matcher: $matcher,
                hooks: [{type: "command", command: $cmd}]
            }]
        ' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
        changed=true
    done

    if $changed; then
        mv "$tmp" "$CLAUDE_SETTINGS"
        echo "hooks: added tracker hooks to $CLAUDE_SETTINGS"
    else
        rm -f "$tmp"
        echo "hooks: already configured"
    fi
}

install_hooks

# ── configure Gemini CLI hooks ───────────────────────────────────────

GEMINI_SETTINGS="$HOME/.gemini/settings.json"

# Gemini events map to tracker internal commands:
#   SessionStart  -> hook SessionStart
#   SessionEnd    -> hook SessionEnd
#   BeforeAgent   -> hook UserPromptSubmit
#   AfterAgent    -> hook Stop
#   AfterTool     -> hook PostToolUse
#   Notification (ToolPermission) -> hook Notification
GEMINI_EVENT_MAP=(
    "SessionStart:SessionStart:"
    "SessionEnd:SessionEnd:"
    "BeforeAgent:UserPromptSubmit:"
    "AfterAgent:Stop:"
    "AfterTool:PostToolUse:"
    "Notification:Notification:ToolPermission"
)

_print_manual_gemini_hooks() {
    cat <<'MANUAL_GEMINI'

Add the following to ~/.gemini/settings.json under "hooks":

{
  "hooks": {
    "SessionStart": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook SessionStart" }] }],
    "SessionEnd": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook SessionEnd" }] }],
    "BeforeAgent": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook UserPromptSubmit" }] }],
    "AfterAgent": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook Stop" }] }],
    "AfterTool": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook PostToolUse" }] }],
    "Notification": [{ "matcher": "ToolPermission", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook Notification" }] }]
  }
}
MANUAL_GEMINI
}

install_gemini_hooks() {
    # Only install if ~/.gemini directory exists (Gemini CLI is set up)
    if [[ ! -d "$HOME/.gemini" ]]; then
        return
    fi

    if ! $HAS_JQ; then
        echo "gemini hooks: jq not found - skipping auto-configuration"
        _print_manual_gemini_hooks
        return
    fi

    if [[ ! -f "$GEMINI_SETTINGS" ]]; then
        # Create minimal settings with hooks
        local hooks_json="{"
        local first=true
        for entry in "${GEMINI_EVENT_MAP[@]}"; do
            local gemini_event="${entry%%:*}"
            local remainder="${entry#*:}"
            local tracker_cmd="${remainder%%:*}"
            local matcher="${remainder#*:}"
            $first || hooks_json+=","
            first=false
            hooks_json+="\"$gemini_event\":[{\"matcher\":\"$matcher\",\"hooks\":[{\"type\":\"command\",\"command\":\"tmux-agent-tracker hook $tracker_cmd\"}]}]"
        done
        hooks_json+="}"

        jq -n --argjson hooks "$hooks_json" '{hooks: $hooks}' > "$GEMINI_SETTINGS"
        echo "gemini hooks: created $GEMINI_SETTINGS with all tracker hooks"
        return
    fi

    # Settings file exists - merge tracker hooks into existing hooks
    local tmp="${GEMINI_SETTINGS}.tmp"
    local changed=false

    cp "$GEMINI_SETTINGS" "$tmp"

    # Ensure top-level "hooks" key exists
    if ! jq -e '.hooks' "$tmp" >/dev/null 2>&1; then
        jq '. + {hooks: {}}' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
    fi

    for entry in "${GEMINI_EVENT_MAP[@]}"; do
        local gemini_event="${entry%%:*}"
        local remainder="${entry#*:}"
        local tracker_cmd="${remainder%%:*}"
        local matcher="${remainder#*:}"
        local cmd="tmux-agent-tracker hook $tracker_cmd"

        # Check if this exact command already exists under this event
        if jq -e --arg event "$gemini_event" --arg cmd "$cmd" '
            .hooks[$event] // [] | map(.hooks[]? | select(.command == $cmd)) | length > 0
        ' "$tmp" >/dev/null 2>&1; then
            continue
        fi

        # Append tracker hook entry to this event
        jq --arg event "$gemini_event" --arg cmd "$cmd" --arg matcher "$matcher" '
            .hooks[$event] = (.hooks[$event] // []) + [{
                matcher: $matcher,
                hooks: [{type: "command", command: $cmd}]
            }]
        ' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
        changed=true
    done

    if $changed; then
        mv "$tmp" "$GEMINI_SETTINGS"
        echo "gemini hooks: added tracker hooks to $GEMINI_SETTINGS"
    else
        rm -f "$tmp"
        echo "gemini hooks: already configured"
    fi
}

install_gemini_hooks

# ── configure Pi hooks (pi-hooks extension) ─────────────────────────

PI_SETTINGS="$HOME/.pi/agent/settings.json"

PI_EVENTS=(
    SessionStart UserPromptSubmit
    PostToolUse PostToolUseFailure Stop SessionEnd
)

_print_manual_pi_hooks() {
    cat <<'MANUAL_PI'

To configure Pi hooks via pi-hooks:

1. Install pi-hooks package:
   pi install npm:@hsingjui/pi-hooks

2. Add to ~/.pi/agent/settings.json:

{
  "hooks": {
    "SessionStart": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook SessionStart" }] }],
    "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook UserPromptSubmit" }] }],
    "PostToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook PostToolUse" }] }],
    "PostToolUseFailure": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook PostToolUseFailure" }] }],
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook Stop" }] }],
    "SessionEnd": [{ "matcher": "", "hooks": [{ "type": "command", "command": "tmux-agent-tracker hook SessionEnd" }] }]
  }
}

Then restart Pi for hooks to take effect.
MANUAL_PI
}

install_pi_hooks() {
    if ! command -v pi >/dev/null 2>&1; then
        return
    fi

    echo ""
    echo "── Pi hooks ──"

    if ! $HAS_JQ; then
        echo "pi hooks: jq not found — skipping auto-configuration"
        _print_manual_pi_hooks
        return
    fi

    # Check pi-hooks package is installed
    local pi_hooks_ok=false
    if [[ -d "$HOME/.pi/agent/npm/node_modules/@hsingjui/pi-hooks" ]]; then
        pi_hooks_ok=true
    fi
    if ! $pi_hooks_ok; then
        echo "pi hooks: @hsingjui/pi-hooks package not found"
        echo "  Install: pi install npm:@hsingjui/pi-hooks"
        _print_manual_pi_hooks
        return
    fi

    if [[ ! -f "$PI_SETTINGS" ]]; then
        # Create minimal settings with hooks
        local hooks_json="{use: {extension: ['pi-hooks']}, "
        hooks_json+='"hooks":{'
        local first=true
        for event in "${PI_EVENTS[@]}"; do
            $first || hooks_json+=","
            first=false
            hooks_json+="\"$event\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"tmux-agent-tracker hook $event\"}]}]"
        done
        hooks_json+="}}"

        jq -n --argjson hooks "$hooks_json" '{
            use: {extension: ["pi-hooks"]},
            hooks: $hooks
        }' > "$PI_SETTINGS" 2>/dev/null || {
            echo "pi hooks: failed to create $PI_SETTINGS"
            _print_manual_pi_hooks
            return
        }
        echo "pi hooks: created $PI_SETTINGS with all tracker hooks"
        return
    fi

    # Settings file exists — merge tracker hooks
    local tmp="${PI_SETTINGS}.tmp"
    local changed=false

    cp "$PI_SETTINGS" "$tmp"

    # Ensure top-level "hooks" key exists
    if ! jq -e '.hooks' "$tmp" >/dev/null 2>&1; then
        jq '. + {hooks: {}}' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
    fi

    # Ensure pi-hooks extension is enabled
    if ! jq -e '.use.extension | index("pi-hooks")' "$tmp" >/dev/null 2>&1; then
        jq '.use.extension = (.use.extension // []) + ["pi-hooks"]' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
        changed=true
    fi

    for event in "${PI_EVENTS[@]}"; do
        local cmd="tmux-agent-tracker hook $event"

        # Check if this exact command already exists under this event
        if jq -e --arg event "$event" --arg cmd "$cmd" '
            .hooks[$event] // [] | map(.hooks[]? | select(.command == $cmd)) | length > 0
        ' "$tmp" >/dev/null 2>&1; then
            continue
        fi

        # Append tracker hook entry to this event
        jq --arg event "$event" --arg cmd "$cmd" '
            .hooks[$event] = (.hooks[$event] // []) + [{
                matcher: "",
                hooks: [{type: "command", command: $cmd}]
            }]
        ' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
        changed=true
    done

    if $changed; then
        mv "$tmp" "$PI_SETTINGS"
        echo "pi hooks: added tracker hooks to $PI_SETTINGS"
        echo "pi hooks: extension pi-hooks enabled in use.extension"
    else
        rm -f "$tmp"
        echo "pi hooks: already configured"
    fi
}

# ── configure Codex notify hook ──────────────────────────────────────

_print_manual_codex_notify() {
    cat <<'MANUAL_CODEX'

Add this to ~/.codex/config.toml:

notify = ["tmux-agent-tracker", "codex-notify"]

MANUAL_CODEX
}

install_codex_notify() {
    local notify_line='notify = ["tmux-agent-tracker", "codex-notify"]'
    mkdir -p "$(dirname "$CODEX_CONFIG")"

    _has_global_notify() {
        awk '
            /^[[:space:]]*#/ { next }
            /^[[:space:]]*\[/ { in_table=1 }
            !in_table && /^[[:space:]]*notify[[:space:]]*=/ { found=1 }
            END { exit(found ? 0 : 1) }
        ' "$1"
    }

    _has_global_tracker_notify() {
        awk -v needle="$notify_line" '
            /^[[:space:]]*#/ { next }
            /^[[:space:]]*\[/ { in_table=1 }
            !in_table {
                line=$0
                sub(/^[[:space:]]+/, "", line)
                sub(/[[:space:]]+$/, "", line)
                if (line == needle) found=1
            }
            END { exit(found ? 0 : 1) }
        ' "$1"
    }

    if [[ ! -f "$CODEX_CONFIG" ]]; then
        {
            echo "# tmux-agent-tracker"
            echo "$notify_line"
        } > "$CODEX_CONFIG"
        echo "codex: created $CODEX_CONFIG with notify hook"
        return
    fi

    if _has_global_notify "$CODEX_CONFIG"; then
        if _has_global_tracker_notify "$CODEX_CONFIG"; then
            echo "codex: notify hook already configured"
            return
        fi
        echo "codex: existing notify command found in $CODEX_CONFIG; leaving it unchanged"
        _print_manual_codex_notify
        return
    fi

    # migrate a previously appended notify line from table scope to top-level
    if grep -Fq '"tmux-agent-tracker", "codex-notify"' "$CODEX_CONFIG"; then
        local tmp
        tmp=$(mktemp)
        sed \
            -e '/^[[:space:]]*# tmux-agent-tracker[[:space:]]*$/d' \
            -e '/"tmux-agent-tracker",[[:space:]]*"codex-notify"/d' \
            "$CODEX_CONFIG" > "$tmp"
        {
            echo "# tmux-agent-tracker"
            echo "$notify_line"
            echo ""
            cat "$tmp"
        } > "${tmp}.new"
        mv "${tmp}.new" "$CODEX_CONFIG"
        rm -f "$tmp"
        echo "codex: moved notify hook to top-level in $CODEX_CONFIG"
        return
    fi

    {
        echo "# tmux-agent-tracker"
        echo "$notify_line"
        echo ""
        cat "$CODEX_CONFIG"
    } > "${CODEX_CONFIG}.tmp"
    mv "${CODEX_CONFIG}.tmp" "$CODEX_CONFIG"
    echo "codex: added top-level notify hook to $CODEX_CONFIG"
}

install_codex_notify

install_pi_hooks

# ── done ─────────────────────────────────────────────────────────────

echo ""
if $HOOKS_ONLY; then
    echo "Done. Restart Claude Code, Gemini CLI, Codex, and Pi for hooks to take effect."
else
    echo "Done. Reload tmux: tmux source ~/.tmux.conf"
    echo "Then restart Claude Code, Gemini CLI, Codex, and Pi for hooks to take effect."
fi
