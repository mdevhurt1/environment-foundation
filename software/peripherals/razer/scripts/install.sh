#!/usr/bin/env bash
# Description: Installs OpenRazer (DKMS driver + daemon) and Polychromatic (GUI + CLI) from the official PPAs, and adds the user to the plugdev group.
# Profiles:    workstation, gaming
# Platforms:   ubuntu-24.04
# Dependencies: software-properties-common (add-apt-repository), linux-headers-$(uname -r) for DKMS, apt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
source "$REPO_ROOT/shared/logging.sh"

require_not_root
require_command add-apt-repository "install software-properties-common"

export DEBIAN_FRONTEND=noninteractive

# --- Preflight: DKMS needs matching kernel headers to build the driver. -------
check_headers() {
  local kver
  kver="$(uname -r)"
  if dpkg -s "linux-headers-${kver}" &>/dev/null; then
    log_ok "Kernel headers present (linux-headers-${kver}) — DKMS can build."
  else
    log_warn "linux-headers-${kver} not found. The DKMS driver will fail to build."
    log_warn "Install with: sudo apt-get install linux-headers-${kver}"
  fi
}

# --- Ensure the Ubuntu 'universe' component is enabled (OpenRazer dep). --------
ensure_universe() {
  if apt-cache policy 2>/dev/null | grep -q "universe"; then
    log_info "universe component already enabled."
  else
    log_info "Enabling universe component..."
    sudo add-apt-repository -y universe
  fi
}

# --- OpenRazer ----------------------------------------------------------------
install_openrazer() {
  if dpkg -s openrazer-meta &>/dev/null; then
    log_ok "openrazer-meta already installed — skipping."
    return
  fi
  log_info "Adding OpenRazer PPA (ppa:openrazer/stable)..."
  sudo add-apt-repository -y ppa:openrazer/stable
  sudo -E apt-get update -y
  log_info "Installing openrazer-meta (DKMS driver + daemon)..."
  sudo -E apt-get install -y openrazer-meta
  log_ok "OpenRazer installed."
}

# --- Polychromatic ------------------------------------------------------------
install_polychromatic() {
  if dpkg -s polychromatic &>/dev/null; then
    log_ok "polychromatic already installed — skipping."
    return
  fi
  log_info "Adding Polychromatic PPA (ppa:polychromatic/stable)..."
  sudo add-apt-repository -y ppa:polychromatic/stable
  sudo -E apt-get update -y
  log_info "Installing polychromatic (GUI controller + CLI)..."
  sudo -E apt-get install -y polychromatic
  log_ok "Polychromatic installed."
}

# --- plugdev group (the reboot gate) ------------------------------------------
add_to_plugdev() {
  if id -nG "$USER" | tr ' ' '\n' | grep -qx plugdev; then
    log_ok "$USER is already in the plugdev group."
  else
    log_info "Adding $USER to the plugdev group (required for device access)..."
    sudo gpasswd -a "$USER" plugdev
    log_warn ">>> REBOOT REQUIRED <<<"
    log_warn "The plugdev group change does not apply to this session."
    log_warn "Reboot, then run: bash scripts/verify.sh"
  fi
}

main() {
  check_headers
  ensure_universe
  install_openrazer
  install_polychromatic
  add_to_plugdev
  log_ok "Install steps complete. If prompted above, REBOOT before verifying."
  log_info "After reboot: bash scripts/verify.sh"
}

main "$@"
