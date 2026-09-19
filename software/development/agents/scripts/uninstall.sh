#!/usr/bin/env bash
# Description: Removes the symlinks install.sh created. Dry run by default; --yes to proceed. Never touches ~/.config/agents/env or the vault.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04
# Dependencies: symlinks deployed by install.sh
# Idempotent.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
source "$REPO_ROOT/shared/logging.sh"
require_not_root
ASSUME_YES=0
case "${1:-}" in --yes) ASSUME_YES=1 ;; "") ;; *) log_error "unknown argument: $1"; exit 2 ;; esac
links=("$HOME/.codex/AGENTS.md" "$HOME/.pi/agent/AGENTS.md" "$HOME/.claude/skills" "$HOME/.gemini/config/skills" "$HOME/.claude/CLAUDE.md" "$HOME/.claude/statusline-command.sh" "$HOME/.claude/model-policy.json" "$HOME/.claude/cc-memory-inject.sh" "$HOME/.claude/cc-outbound-guard.sh" "$HOME/.agents/skills" "$HOME/.agents/AGENTS.md")
[ -f "$HOME/.agents/agy-context-path" ] && links+=("$(cat "$HOME/.agents/agy-context-path")")
log_info "would remove (kept: ~/.config/agents/env, agy-context-path, the vault):"
for l in "${links[@]}"; do [ -L "$l" ] && printf '  - %s\n' "$l"; done
[ "$ASSUME_YES" -eq 1 ] || { log_warn "Dry run; re-run with --yes."; exit 0; }
for l in "${links[@]}"; do
    if [ -L "$l" ]; then rm "$l"; log_ok "removed $l"; fi
done
exit 0
