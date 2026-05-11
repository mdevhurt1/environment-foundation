#!/usr/bin/env bash
# Description: Reverses install. Interactive — prompts before each destructive op.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: apt, dconf, gnome-extensions, systemctl

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
MODULE_ROOT="$(dirname "$SCRIPT_DIR")"
CANONICAL="$MODULE_ROOT/canonical"
source "$REPO_ROOT/shared/logging.sh"

require_not_root

confirm() {
  local prompt="$1"
  local ans
  read -r -p "[uninstall] $prompt [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# Tier-specific uninstall functions added below by later tasks:
# uninstall_tier1   — Task 3.5
# uninstall_tier2   — Task 2.7
# uninstall_tier3   — Task 1.4

main() {
  # Reverse order: Tier 3 (heaviest) first, Tier 1 last.
  uninstall_tier3
  uninstall_tier2
  uninstall_tier1
  log_ok "Uninstall complete. Module files in the repo are untouched."
}

main "$@"
