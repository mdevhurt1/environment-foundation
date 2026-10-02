#!/usr/bin/env bash
# Description: Removes what this module's install.sh created: the npm global Claude Code CLI. The ~/.claude links
#              belong to agents/scripts/install.sh (one owner since the 2026-09-19 reset); this script never touches
#              them, never restores a .backup-* or .pre-reset-* file, and points at the owner's uninstall instead.
#              Dry run by default; --yes to proceed.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: npm (CLI installed by install.sh)
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

NPM_PKG="@anthropic-ai/claude-code"
LINK_OWNER="$REPO_ROOT/software/development/agents/scripts/uninstall.sh"

ASSUME_YES=0
case "${1:-}" in
  --yes) ASSUME_YES=1 ;;
  "")    ASSUME_YES=0 ;;
  *)     log_error "Unknown argument: $1 (only --yes is accepted)"; exit 2 ;;
esac

npm_installed() { command -v npm &>/dev/null && npm ls -g --depth=0 "$NPM_PKG" &>/dev/null; }

log_info "Claude Code uninstall would REMOVE:"
if npm_installed; then
  printf '  - npm global package: %s\n' "$NPM_PKG"
else
  printf '  (nothing: %s is not installed globally via npm)\n' "$NPM_PKG"
fi

log_info "and would deliberately KEEP:"
# shellcheck disable=SC2088  # display text naming paths, not paths to expand
printf '  . %s\n' \
  "the ~/.claude links (CLAUDE.md, statusline, hooks, model policy, regen): owned by the agents module;" \
  "    remove them with: bash $LINK_OWNER --yes" \
  "~/.claude/settings.json and settings.local.json: user files, never removed" \
  "every ~/.claude/.backup-* dir and *.pre-reset-* file: never restored by this script" \
  "~/vault/ and the environment-foundation repository" \
  "Node.js: other software depends on it"
if [ -e "$HOME/.local/bin/claude" ]; then
  printf '  . %s\n' "$HOME/.local/bin/claude: a native install this module did not create"
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  log_warn "Dry run; nothing was removed. Re-run with --yes to proceed."
  exit 0
fi

if npm_installed; then
  log_info "Removing the npm global $NPM_PKG..."
  sudo npm uninstall -g "$NPM_PKG"
  log_ok "$NPM_PKG removed."
else
  log_ok "$NPM_PKG is not installed globally; skipping."
fi
if [ -e "$HOME/.local/bin/claude" ]; then
  log_warn "$HOME/.local/bin/claude is still present (a native install this module did not create)."
fi
log_info "The ~/.claude links were not touched. To remove them: bash $LINK_OWNER --yes"
