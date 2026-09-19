#!/usr/bin/env bash
# SessionStart hook: inject the `using-superpowers` skill body into every session.
#
# WHY THIS EXISTS
# ---------------
# This behaviour used to come from the superpowers plugin's own
# hooks/hooks.json -> hooks/session-start. We disabled that plugin because it
# shipped `brainstorming` and `writing-plans` skills whose names collided with
# our canonical ones, and its injected mandate routed every agent to
# `superpowers:brainstorming` -- which writes specs to
# docs/superpowers/specs/ and commits them, instead of to the vault task
# folder, and emits no tree event. Specs were being silently lost.
#
# We vendored the 12 non-colliding skills into canonical/skills/ and stripped
# the `superpowers:` prefix from their cross-references, so the routing lines
# now resolve to OUR skills. This hook restores the injection the plugin used
# to provide. Without it, the mandate is only discoverable via the Skill tool.
#
# Upstream: github.com/obra/superpowers (MIT), vendored from 6.3.0.

set -euo pipefail

# Resolve via the DEPLOYED skills symlink, never relative to this script.
# This file is invoked through ~/.claude/cc-skills-inject.sh, so $BASH_SOURCE
# points into ~/.claude and "../skills" would resolve to ~/skills. Going
# through ~/.claude/skills also means we read whichever checkout configure.sh
# deployed -- the main worktree -- rather than a sibling worktree's copy.
SKILL_MD="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/using-superpowers/SKILL.md"

# A missing skill file must not break session start -- emit nothing, exit 0.
[ -r "$SKILL_MD" ] || exit 0

body=$(cat "$SKILL_MD")

escape_for_json() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

escaped=$(escape_for_json "$body")

context="<EXTREMELY_IMPORTANT>\nYou have skills.\n\n**Below is the full content of your 'using-superpowers' skill - your introduction to using skills. For all other skills, use the 'Skill' tool:**\n\n${escaped}\n</EXTREMELY_IMPORTANT>"

# printf, not a heredoc: bash 5.3+ hangs on heredocs here (obra/superpowers#571).
printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "SessionStart",\n    "additionalContext": "%s"\n  }\n}\n' "$context"
