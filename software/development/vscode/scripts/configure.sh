#!/usr/bin/env bash
# Description: Installs the VS Code extensions declared in
#              canonical/extensions.txt that are not already installed.
#              Per-user, no sudo. Never removes extensions and never touches
#              user settings (~/.config/Code/User).
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: code (installed by install.sh, or the snap)
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root
require_command code "install VS Code first: bash $SCRIPT_DIR/install.sh"

EXT_LIST="$SCRIPT_DIR/../canonical/extensions.txt"
if [ ! -f "$EXT_LIST" ]; then
  log_error "Extension list missing at $EXT_LIST — restore it from git (git checkout -- software/development/vscode/canonical/extensions.txt)."
  exit 1
fi

# Marketplace IDs are case-insensitive; compare lowercased, comments and
# blank lines stripped.
declared="$(grep -vE '^[[:space:]]*(#|$)' "$EXT_LIST" | tr -d ' \t\r' | tr '[:upper:]' '[:lower:]' | sort -u | sed '/^$/d')"
installed="$(code --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' | sort -u)"

missing="$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$installed") | sed '/^$/d')"
extra="$(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$installed") | sed '/^$/d')"

if [ -z "$missing" ]; then
  log_ok "All $(printf '%s\n' "$declared" | grep -c .) declared extensions already installed — skipping."
else
  log_info "Installing $(printf '%s\n' "$missing" | grep -c .) missing extension(s)..."
  while IFS= read -r ext; do
    [ -n "$ext" ] || continue
    code --install-extension "$ext"
    log_ok "installed $ext"
  done <<< "$missing"
fi

if [ -n "$extra" ]; then
  log_warn "Installed but not declared in canonical/extensions.txt (left alone):"
  printf '%s\n' "$extra" | sed 's/^/  /' >&2
  log_info "To track them, append to $EXT_LIST: code --list-extensions"
fi
