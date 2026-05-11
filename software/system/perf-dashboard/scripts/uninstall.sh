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

uninstall_tier1() {
  log_info "Tier 1: Vitals"
  local uuid="Vitals@CoreCoding.com"
  if confirm "Disable + uninstall Vitals extension and reset its dconf?"; then
    gnome-extensions disable "$uuid" 2>/dev/null || true
    gnome-extensions uninstall "$uuid" 2>/dev/null || true
    dconf reset -f /org/gnome/shell/extensions/vitals/ 2>/dev/null || true
  fi
  if confirm "Remove gnome-shell-extension-manager apt package?"; then
    DEBIAN_FRONTEND=noninteractive sudo apt-get remove -y gnome-shell-extension-manager
  fi
}

uninstall_tier2() {
  log_info "Tier 2: Conky"
  if confirm "Stop Conky and remove user-side configs + autostart?"; then
    pkill -x conky 2>/dev/null || true
    rm -f "$HOME/.config/autostart/perf-dashboard-conky.desktop"
    rm -f "$HOME/.config/conky/perf-dashboard.conkyrc"
    rm -f "$HOME/.config/conky/widgets.lua"
    rm -f "$HOME/.config/conky/conky-helpers.sh"
    rmdir "$HOME/.config/conky" 2>/dev/null || true
  fi
  if confirm "Remove apt packages (conky-all, power-profiles-daemon, lm-sensors)?"; then
    DEBIAN_FRONTEND=noninteractive sudo apt-get remove -y conky-all power-profiles-daemon lm-sensors
  fi
}

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
