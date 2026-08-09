#!/usr/bin/env bash
# Description: Removes the Steam client. Dry run by default; --yes to proceed. Never touches game libraries or user data.
# Profiles:    gaming, workstation
# Platforms:   ubuntu-24.04, ubuntu-22.04
# Dependencies: apt (steam installed by install.sh)
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

log_info "Steam uninstall would REMOVE:"
plan "apt package: steam-installer (and the steam runtime packages it pulled in)"

log_info "and would deliberately KEEP:"
keep "~/.steam and ~/.local/share/Steam — game libraries, saves, config (user data)"
keep "the i386 foreign architecture — other 32-bit packages depend on it"

if [ "$ASSUME_YES" -ne 1 ]; then
  log_warn "Dry run — nothing was removed. Re-run with --yes to proceed."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive

if dpkg -s steam-installer &>/dev/null; then
  log_info "Removing steam-installer..."
  sudo -E apt-get remove -y steam-installer
  sudo -E apt-get autoremove -y
  log_ok "steam-installer removed."
else
  log_ok "steam-installer is not installed — nothing to remove."
fi

log_ok "Steam uninstall complete."
log_info "Game data is still at ~/.steam and ~/.local/share/Steam — delete it by hand if you want it gone."
