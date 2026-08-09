#!/usr/bin/env bash
# Description: Removes Boatswain and the Elgato udev rule. Dry run by default; --yes to proceed. Never touches Boatswain's saved decks or the shared Flathub remote.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: flatpak, udevadm (installed by install.sh)
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

APP_ID="com.feaneron.Boatswain"
RULE_PATH="/etc/udev/rules.d/10-streamdeck.rules"

ASSUME_YES=0
case "${1:-}" in
  --yes) ASSUME_YES=1 ;;
  "")    ASSUME_YES=0 ;;
  *)     log_error "Unknown argument: $1 (only --yes is accepted)"; exit 2 ;;
esac

plan() { printf '  - %s\n' "$*"; }
keep() { printf '  . %s\n' "$*"; }

log_info "Stream Deck uninstall would REMOVE:"
plan "flatpak app: $APP_ID"
plan "udev rule: $RULE_PATH (install.sh wrote it)"

log_info "and would deliberately KEEP:"
keep "~/.var/app/$APP_ID — saved decks, icons, action config (user data)"
keep "the flathub remote — shared by every other flatpak on this machine"

if [ "$ASSUME_YES" -ne 1 ]; then
  log_warn "Dry run — nothing was removed. Re-run with --yes to proceed."
  exit 0
fi

if flatpak info "$APP_ID" &>/dev/null; then
  log_info "Uninstalling $APP_ID..."
  sudo flatpak uninstall -y "$APP_ID"
  log_ok "$APP_ID removed."
else
  log_ok "$APP_ID is not installed — skipping."
fi

if [ -f "$RULE_PATH" ]; then
  log_info "Removing $RULE_PATH..."
  sudo rm -f "$RULE_PATH"
  sudo udevadm control --reload-rules
  sudo udevadm trigger
  log_ok "udev rule removed and rules reloaded."
else
  log_ok "$RULE_PATH already absent — skipping."
fi

log_ok "Stream Deck uninstall complete."
log_info "Your decks are still at ~/.var/app/$APP_ID."
log_warn "An attached Stream Deck keeps its current permissions until you replug it."
