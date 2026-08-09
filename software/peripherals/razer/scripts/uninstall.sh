#!/usr/bin/env bash
# Description: Removes OpenRazer and Polychromatic, their PPAs and the plugdev membership install.sh granted. Dry run by default; --yes to proceed.
# Profiles:    workstation, gaming
# Platforms:   ubuntu-24.04
# Dependencies: apt, add-apt-repository, gpasswd (installed by install.sh)
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

ASSUME_YES=0
case "${1:-}" in
  --yes) ASSUME_YES=1 ;;
  "")    ASSUME_YES=0 ;;
  *)     log_error "Unknown argument: $1 (only --yes is accepted)"; exit 2 ;;
esac

plan() { printf '  - %s\n' "$*"; }
keep() { printf '  . %s\n' "$*"; }

log_info "Razer uninstall would REMOVE:"
plan "apt packages: openrazer-meta, polychromatic"
plan "the DKMS openrazer-driver module (removed with openrazer-meta)"
plan "apt sources: ppa:openrazer/stable, ppa:polychromatic/stable"
plan "$USER's membership of the plugdev group (install.sh added it)"

log_info "and would deliberately KEEP:"
keep "~/.config/polychromatic — saved effects and device profiles (user data)"
keep "the plugdev group itself — a system group other packages use"

log_warn "Removing plugdev membership can affect OTHER plugdev-gated devices."
log_warn "If you use any, re-add yourself afterwards: sudo gpasswd -a $USER plugdev"

if [ "$ASSUME_YES" -ne 1 ]; then
  log_warn "Dry run — nothing was removed. Re-run with --yes to proceed."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive

for pkg in polychromatic openrazer-meta; do
  if dpkg -s "$pkg" &>/dev/null; then
    log_info "Removing $pkg..."
    sudo -E apt-get remove -y "$pkg"
    log_ok "$pkg removed."
  else
    log_ok "$pkg is not installed — skipping."
  fi
done
sudo -E apt-get autoremove -y

for ppa in ppa:openrazer/stable ppa:polychromatic/stable; do
  match="${ppa#ppa:}"
  if grep -Rqs "$match" /etc/apt/sources.list.d/ 2>/dev/null; then
    log_info "Removing $ppa..."
    sudo add-apt-repository -y -r "$ppa"
    log_ok "$ppa removed."
  else
    log_ok "$ppa is not configured — skipping."
  fi
done
sudo -E apt-get update -y

if id -nG "$USER" | tr ' ' '\n' | grep -qx plugdev; then
  log_info "Removing $USER from the plugdev group..."
  sudo gpasswd -d "$USER" plugdev
  log_ok "$USER removed from plugdev."
  log_warn "Log out and back in for the group change to take effect."
else
  log_ok "$USER is not in plugdev — skipping."
fi

log_ok "Razer uninstall complete."
log_warn "A reboot clears the loaded DKMS driver from the running kernel."
