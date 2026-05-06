#!/usr/bin/env bash
# Description: Sets up ~/.claude/settings.json and prints API key instructions
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: claude installed (install.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
source "$REPO_ROOT/shared/logging.sh"

require_not_root
require_command claude "install Claude Code first: bash $(dirname "$SCRIPT_DIR")/install.sh"

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

log_info "Setting up Claude Code configuration..."

mkdir -p "$CLAUDE_DIR"

if [ -f "$SETTINGS" ]; then
    log_warn "$SETTINGS already exists — skipping to avoid overwriting your config"
    log_info "Review your existing settings at: $SETTINGS"
else
    cat > "$SETTINGS" << 'EOF'
{
  "theme": "dark",
  "autoUpdates": true
}
EOF
    log_ok "Created $SETTINGS with baseline configuration"
fi

log_warn "Action required: set your ANTHROPIC_API_KEY"
log_info "Add the following to ~/.zshrc (or ~/.bashrc if using bash):"
printf '\n  export ANTHROPIC_API_KEY="your-key-here"\n\n'
log_info "Get your API key at: https://console.anthropic.com/settings/keys"
log_ok "Claude Code configuration complete — set ANTHROPIC_API_KEY and reload your shell"
