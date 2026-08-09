#!/usr/bin/env bash
# Description: Post-install acceptance test for the discord module — checks the Flathub remote is configured, the Discord flatpak is installed, and its exported desktop entry exists.
# Profiles:    gaming, workstation
# Platforms:   ubuntu-24.04, ubuntu-22.04
# Dependencies: flatpak, com.discordapp.Discord (installed by install.sh)

set -uo pipefail   # NOTE: no -e — we want every check to run and report.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

APP_ID="com.discordapp.Discord"
EXPORT_DESKTOP="/var/lib/flatpak/exports/share/applications/${APP_ID}.desktop"

fails=0
check() {
  # check "<label>" <command...>
  local label="$1"; shift
  if "$@" &>/dev/null; then
    log_ok "$label"
  else
    log_error "$label"
    fails=$((fails + 1))
  fi
}

log_info "Verifying Discord install..."

# 1. flatpak itself is present — install.sh installs it if it was absent.
check "flatpak on PATH" command -v flatpak

# 2. The Flathub remote is configured. Without it the app cannot update.
check "flathub remote configured" \
  bash -c 'flatpak remotes --columns=name 2>/dev/null | grep -qx flathub'

# 3. The app is installed.
check "Discord flatpak installed ($APP_ID)" flatpak info "$APP_ID"

# 4. Exported desktop entry — this is what puts Discord in the application
#    menu. install.sh warns that a fresh flatpak install may need a logout
#    before PATH/menu integration appears, so this is the check that catches it.
if [ -f "$EXPORT_DESKTOP" ]; then
  log_ok "desktop entry exported ($EXPORT_DESKTOP)"
else
  log_error "desktop entry missing ($EXPORT_DESKTOP)"
  log_warn "log out and back in once so flatpak's menu integration is picked up"
  fails=$((fails + 1))
fi

echo
if [[ "$fails" -eq 0 ]]; then
  log_ok "All checks passed. Discord version:"
  flatpak info "$APP_ID" 2>/dev/null | grep -E '^\s+Version:' || true
  log_info "Launch it from the application menu or run: flatpak run $APP_ID"
  exit 0
else
  log_error "$fails check(s) failed."
  log_warn "Re-run the installer: bash $SCRIPT_DIR/install.sh"
  exit 1
fi
