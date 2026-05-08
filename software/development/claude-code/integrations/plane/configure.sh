#!/usr/bin/env bash
# Description: Installs the Plane API skill for Claude Code and prints API key instructions
# Profiles:    workstation
# Platforms:   ubuntu-24.04, ubuntu-22.04
# Dependencies: claude (install.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
source "$REPO_ROOT/shared/logging.sh"

require_not_root
require_command claude "install Claude Code first: bash $REPO_ROOT/software/development/claude-code/scripts/install.sh"

SKILL_SRC="$SCRIPT_DIR/skill.md"
SKILL_DST="$HOME/.claude/skills/plane-api/SKILL.md"
SKILL_DIR="$(dirname "$SKILL_DST")"

log_info "Setting up Plane integration for Claude Code..."

mkdir -p "$SKILL_DIR"

if [ -f "$SKILL_DST" ]; then
    log_warn "$SKILL_DST already exists — skipping to avoid overwriting your skill"
    log_info "To reinstall, remove $SKILL_DST and re-run this script"
else
    cp "$SKILL_SRC" "$SKILL_DST"
    log_ok "Plane API skill installed to $SKILL_DST"
fi

log_warn "Action required: set your PLANE_API_KEY"
log_info "Add the following to ~/.zshrc:"
printf '\n  export PLANE_API_KEY="your-key-here"\n\n'
log_info "Get your API key at: http://plane.homelab → Settings → API Tokens"
log_ok "Plane integration setup complete — set PLANE_API_KEY and reload your shell"
