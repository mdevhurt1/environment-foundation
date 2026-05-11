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

uninstall_tier3() {
  log_info "Tier 3: Netdata"
  if confirm "Stop and uninstall Netdata? (data in /var/cache/netdata will be lost)"; then
    if [[ -x /usr/libexec/netdata/netdata-uninstaller.sh ]]; then
      sudo /usr/libexec/netdata/netdata-uninstaller.sh --yes --force
    elif [[ -x /usr/sbin/netdata-uninstaller.sh ]]; then
      sudo /usr/sbin/netdata-uninstaller.sh --yes --force
    elif command -v dpkg >/dev/null 2>&1 && dpkg -l netdata >/dev/null 2>&1; then
      sudo apt remove --purge -y netdata
    else
      log_warn "Netdata uninstaller not found — remove manually if needed."
    fi
    sudo rm -rf /etc/netdata /var/cache/netdata /var/lib/netdata
  fi
}

main() {
  # Reverse order: Tier 3 (heaviest) first, Tier 1 last.
  uninstall_tier3
  uninstall_tier2
  uninstall_tier1
  log_ok "Uninstall complete. Module files in the repo are untouched."
}

main "$@"
