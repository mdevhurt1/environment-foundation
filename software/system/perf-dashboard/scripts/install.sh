#!/usr/bin/env bash
# Description: Installs system-level components for the perf-dashboard module (Netdata, Conky, lm-sensors, GNOME Vitals).
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: curl, gnome-shell 46+, apt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
MODULE_ROOT="$(dirname "$SCRIPT_DIR")"
CANONICAL="$MODULE_ROOT/canonical"
source "$REPO_ROOT/shared/logging.sh"

require_not_root

require_x11_or_warn() {
  if [[ "${XDG_SESSION_TYPE:-}" != "x11" ]]; then
    log_warn "session is '${XDG_SESSION_TYPE:-unknown}'. Tier 2 (Conky) requires X11."
    log_warn "conky-all will install but configure.sh will skip its autostart."
  fi
}

require_gnome() {
  require_command gnome-shell "install GNOME desktop — this module requires GNOME 46+"
  local gnome_ver
  gnome_ver=$(gnome-shell --version | awk '{print $3}' | cut -d. -f1)
  if [[ "$gnome_ver" -lt 46 ]]; then
    log_error "GNOME Shell 46+ required (found $gnome_ver) — upgrade GNOME or use Ubuntu 24.04+"
    exit 1
  fi
}

# Tier-specific functions are added below by later tasks.
# install_apt_packages   — Task 2.4
# run_sensors_detect     — Task 2.4
# install_netdata        — Task 1.3
# verify_netdata_bind    — Task 1.3
# install_vitals         — Task 3.2

main() {
  require_x11_or_warn
  require_gnome
  # Tier 3 first (security-critical bind verification).
  install_netdata
  verify_netdata_bind
  # Tier 2 next (apt packages used by Tier 2's userspace bits).
  install_apt_packages
  run_sensors_detect
  # Tier 1 last (requires user action to log out / log in).
  install_vitals
  log_ok "Install complete. Next: bash scripts/configure.sh, then log out and back in."
}

main "$@"
