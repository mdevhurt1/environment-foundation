#!/usr/bin/env bash
# Description: Removes all three Performance Dashboard tiers — Netdata, Conky and the Vitals extension — plus the configs and autostart entry the module deployed. Dry run by default; --yes to proceed.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: apt, dconf, gnome-extensions, systemctl
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

VITALS_UUID="Vitals@CoreCoding.com"

ASSUME_YES=0
case "${1:-}" in
  --yes) ASSUME_YES=1 ;;
  "")    ASSUME_YES=0 ;;
  *)     log_error "Unknown argument: $1 (only --yes is accepted)"; exit 2 ;;
esac

plan() { printf '  - %s\n' "$*"; }
keep() { printf '  . %s\n' "$*"; }

log_info "Performance Dashboard uninstall would REMOVE:"
plan "Tier 3: Netdata, and /etc/netdata, /var/cache/netdata, /var/lib/netdata"
plan "Tier 2: the running conky process, ~/.config/conky/{perf-dashboard.conkyrc,widgets.lua,conky-helpers.sh}"
plan "Tier 2: the autostart entry ~/.config/autostart/perf-dashboard-conky.desktop"
plan "Tier 2: apt packages conky-all, power-profiles-daemon, lm-sensors"
plan "Tier 1: the $VITALS_UUID extension and its dconf subtree"
plan "Tier 1: apt package gnome-shell-extension-manager"

log_info "and would deliberately KEEP:"
keep "the module files in this repository"
keep "any other conky configs in ~/.config/conky/"
keep "your GNOME settings outside the vitals dconf subtree"

log_warn "Netdata's historical metrics in /var/cache/netdata are deleted and"
log_warn "cannot be recovered."

if [ "$ASSUME_YES" -ne 1 ]; then
  log_warn "Dry run — nothing was removed. Re-run with --yes to proceed."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive

# Reverse order: Tier 3 (heaviest) first, Tier 1 last.

uninstall_tier3() {
  log_info "Tier 3: Netdata"
  if [[ -x /usr/libexec/netdata/netdata-uninstaller.sh ]]; then
    sudo /usr/libexec/netdata/netdata-uninstaller.sh --yes --force || true
  elif [[ -x /usr/sbin/netdata-uninstaller.sh ]]; then
    sudo /usr/sbin/netdata-uninstaller.sh --yes --force || true
  elif command -v dpkg >/dev/null 2>&1 && dpkg -s netdata >/dev/null 2>&1; then
    sudo -E apt-get remove --purge -y netdata || true
  else
    log_warn "Netdata uninstaller not found — nothing to do."
  fi
  sudo rm -rf /etc/netdata /var/cache/netdata /var/lib/netdata || true
  log_ok "Tier 3 removed."
}

uninstall_tier2() {
  log_info "Tier 2: Conky"
  pkill -x conky 2>/dev/null || true
  rm -f "$HOME/.config/autostart/perf-dashboard-conky.desktop"
  rm -f "$HOME/.config/conky/perf-dashboard.conkyrc"
  rm -f "$HOME/.config/conky/widgets.lua"
  rm -f "$HOME/.config/conky/conky-helpers.sh"
  # Only succeeds if the directory is empty — other conky configs are kept.
  rmdir "$HOME/.config/conky" 2>/dev/null || true
  sudo -E apt-get remove -y conky-all power-profiles-daemon lm-sensors || true
  log_ok "Tier 2 removed."
}

uninstall_tier1() {
  log_info "Tier 1: Vitals"
  gnome-extensions disable "$VITALS_UUID" 2>/dev/null || true
  gnome-extensions uninstall "$VITALS_UUID" 2>/dev/null || true
  dconf reset -f /org/gnome/shell/extensions/vitals/ 2>/dev/null || true
  sudo -E apt-get remove -y gnome-shell-extension-manager || true
  log_ok "Tier 1 removed."
}

main() {
  uninstall_tier3
  uninstall_tier2
  uninstall_tier1
  log_ok "Uninstall complete. Module files in the repo are untouched."
}

main
