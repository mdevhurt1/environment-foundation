#!/usr/bin/env bash
# Description: Removes the Discord flatpak. Dry run by default; --yes to proceed. Never touches per-app user data or the shared Flathub remote.
# Profiles:    gaming, workstation
# Platforms:   ubuntu-24.04, ubuntu-22.04
# Dependencies: flatpak (Discord installed by install.sh)
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

APP_ID="com.discordapp.Discord"

ASSUME_YES=0
case "${1:-}" in
  --yes) ASSUME_YES=1 ;;
  "")    ASSUME_YES=0 ;;
  *)     log_error "Unknown argument: $1 (only --yes is accepted)"; exit 2 ;;
esac

plan() { printf '  - %s\n' "$*"; }
keep() { printf '  . %s\n' "$*"; }

log_info "Discord uninstall would REMOVE:"
plan "flatpak app: $APP_ID (and its exported desktop entry)"

log_info "and would deliberately KEEP:"
keep "~/.var/app/$APP_ID — settings, cache, logins (user data)"
keep "the flathub remote — shared by every other flatpak on this machine"
keep "the flatpak package itself — shared infrastructure"

if [ "$ASSUME_YES" -ne 1 ]; then
  log_warn "Dry run — nothing was removed. Re-run with --yes to proceed."
  exit 0
fi

if flatpak info "$APP_ID" &>/dev/null; then
  log_info "Uninstalling $APP_ID..."
  sudo flatpak uninstall -y "$APP_ID"
  log_ok "$APP_ID removed."
else
  log_ok "$APP_ID is not installed — nothing to remove."
fi

log_ok "Discord uninstall complete."
log_info "App data is still at ~/.var/app/$APP_ID — remove it by hand if you want it gone."
