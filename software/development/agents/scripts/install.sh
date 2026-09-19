#!/usr/bin/env bash
# Description: Links ~/.agents/{AGENTS.md,skills} to canonical/ and each runtime's global path to them
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04
# Dependencies: the runtimes' config dirs
# Idempotent: re-running replaces symlinks, never copies.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
source "$REPO_ROOT/shared/logging.sh"
require_not_root
canon="$(cd "$SCRIPT_DIR/.." && pwd)/canonical"

link() { # link <target> <linkpath>
    mkdir -p "$(dirname "$2")"
    if [ -e "$2" ] && [ ! -L "$2" ]; then
        mv "$2" "$2.pre-reset-$(date +%Y%m%d-%H%M%S)"
        echo "moved existing $2 aside"
    fi
    ln -sfn "$1" "$2"
    echo "linked $2 -> $1"
}

# Shared location every runtime can be pointed at
link "$canon/AGENTS.md" "$HOME/.agents/AGENTS.md"
# skills dir exists only after Task 4; until then leave every runtime's skills untouched
if [ -d "$canon/skills" ]; then
    link "$canon/skills" "$HOME/.agents/skills"
    # Claude Code has no shared-dir discovery, so its skills dir points at the shared set
    link "$HOME/.agents/skills" "$HOME/.claude/skills"
    # Antigravity CLI: global skills root per its embedded docs (absent today, so nothing is clobbered)
    link "$HOME/.agents/skills" "$HOME/.gemini/config/skills"
fi

# Codex: global AGENTS.md. Do NOT link ~/.codex/skills: it is a real directory holding
# Codex's managed .system/ skills, and Codex discovers ~/.agents/skills natively.
link "$HOME/.agents/AGENTS.md" "$HOME/.codex/AGENTS.md"

# Pi: global AGENTS.md; reads ~/.agents/skills natively
link "$HOME/.agents/AGENTS.md" "$HOME/.pi/agent/AGENTS.md"

# Claude Code: the five ~/.claude links into claude-code/canonical/ (idempotent today; configure.sh is parked in Task 6)
cc="$REPO_ROOT/software/development/claude-code/canonical"
link "$cc/CLAUDE.md"                    "$HOME/.claude/CLAUDE.md"
link "$cc/statusline-command.sh"        "$HOME/.claude/statusline-command.sh"
link "$cc/model-policy.json"            "$HOME/.claude/model-policy.json"
link "$cc/shell/cc-memory-inject.sh"    "$HOME/.claude/cc-memory-inject.sh"
link "$cc/shell/cc-outbound-guard.sh"   "$HOME/.claude/cc-outbound-guard.sh"

# Antigravity CLI: path recorded by Task 3 in ~/.agents/agy-context-path
if [ -f "$HOME/.agents/agy-context-path" ]; then
    link "$HOME/.agents/AGENTS.md" "$(cat "$HOME/.agents/agy-context-path")"
fi
