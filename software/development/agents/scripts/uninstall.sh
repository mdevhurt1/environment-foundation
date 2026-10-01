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
links=("$HOME/.codex/AGENTS.md" "$HOME/.pi/agent/AGENTS.md" "$HOME/.claude/CLAUDE.md" "$HOME/.claude/statusline-command.sh" "$HOME/.claude/model-policy.json" "$HOME/.claude/cc-memory-inject.sh" "$HOME/.claude/cc-outbound-guard.sh" "$HOME/.claude/cc-memory-index-regen.sh" "$HOME/.agents/AGENTS.md")
# Skill roots are real dirs of per-skill links since v2.0.0 (AI_ST-107); a pre-v2.0.0 install left whole-dir links
roots=("$HOME/.claude/skills" "$HOME/.gemini/config/skills")
for r in "${roots[@]}"; do
    if [ -L "$r" ]; then links+=("$r")
    elif [ -d "$r" ]; then
        for l in "$r"/*; do [ -L "$l" ] && case "$(readlink "$l")" in "$HOME/.agents/skills/"*) links+=("$l");; esac; done
    fi
done
links+=("$HOME/.agents/skills")   # last: the per-skill links above resolve through it
agy_path="$(head -n1 "$HOME/.agents/agy-context-path" 2>/dev/null || true)"
case "$agy_path" in /*) links+=("$agy_path") ;; esac   # install.sh links only an absolute path
ours() { # a link install.sh made: it points into a canonical/ tree of any clone, or into ~/.agents
    case "$(readlink "$1")" in */software/development/agents/canonical/*|*/software/development/claude-code/canonical/*|"$HOME/.agents/"*) return 0;; esac
    return 1
}
backup() { ls -1d "$1".pre-reset-* 2>/dev/null | tail -n1 || true; }   # newest file install.sh moved aside; none is not an error
log_info "would remove (kept: ~/.config/agents/env, agy-context-path, the vault):"
for l in "${links[@]}"; do
    [ -L "$l" ] || continue
    if ours "$l"; then printf '  - %s%s\n' "$l" "$(b=$(backup "$l"); [ -n "$b" ] && echo " (then restore $b)")"
    else printf '  ~ %s (skipped: points at %s, not ours)\n' "$l" "$(readlink "$l")"; fi
done
[ "$ASSUME_YES" -eq 1 ] || { log_warn "Dry run; re-run with --yes."; exit 0; }
for l in "${links[@]}"; do
    [ -L "$l" ] || continue
    if ! ours "$l"; then log_warn "skipped $l: points at $(readlink "$l"), not a link install.sh made"; continue; fi
    rm "$l"; log_ok "removed $l"
    b=$(backup "$l"); if [ -n "$b" ]; then mv "$b" "$l"; log_ok "restored $l from $b"; fi
done
for r in "${roots[@]}"; do   # an emptied root goes too; one still holding vendor skills (synced/) stays
    if [ -d "$r" ] && [ ! -L "$r" ] && rmdir "$r" 2>/dev/null; then log_ok "removed empty $r"; fi
done
exit 0
