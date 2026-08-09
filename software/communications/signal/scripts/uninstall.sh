#!/usr/bin/env bash
# Description: Removes Signal Desktop, its apt source and its keyring. Dry run by default; --yes to proceed. Never touches the local message database.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: apt (signal-desktop installed by install.sh)
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

KEYRING="/usr/share/keyrings/signal-desktop-keyring.gpg"
SOURCES="/etc/apt/sources.list.d/signal-desktop.sources"

ASSUME_YES=0
case "${1:-}" in
  --yes) ASSUME_YES=1 ;;
  "")    ASSUME_YES=0 ;;
  *)     log_error "Unknown argument: $1 (only --yes is accepted)"; exit 2 ;;
esac

plan() { printf '  - %s\n' "$*"; }
keep() { printf '  . %s\n' "$*"; }

log_info "Signal Desktop uninstall would REMOVE:"
plan "apt package: signal-desktop"
plan "apt source: $SOURCES"
plan "keyring: $KEYRING"

log_info "and would deliberately KEEP:"
keep "~/.config/Signal — the local message database and device link (user data)"

if [ "$ASSUME_YES" -ne 1 ]; then
  log_warn "Dry run — nothing was removed. Re-run with --yes to proceed."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive

if dpkg -s signal-desktop &>/dev/null; then
  log_info "Removing signal-desktop..."
  sudo -E apt-get remove -y signal-desktop
  log_ok "signal-desktop removed."
else
  log_ok "signal-desktop is not installed — skipping."
fi

if [ -f "$SOURCES" ]; then
  sudo rm -f "$SOURCES"
  log_ok "removed $SOURCES"
else
  log_ok "$SOURCES already absent."
fi

if [ -f "$KEYRING" ]; then
  sudo rm -f "$KEYRING"
  log_ok "removed $KEYRING"
else
  log_ok "$KEYRING already absent."
fi

log_info "Refreshing apt after removing the source..."
sudo -E apt-get update -y

log_ok "Signal Desktop uninstall complete."
log_info "Your message database is still at ~/.config/Signal — remove it by hand if you want it gone."
log_warn "Unlink this device from your phone: Signal -> Settings -> Linked Devices."
