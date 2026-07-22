#!/usr/bin/env bash
# Description: Installs Discord as a Flatpak from Flathub
# Profiles:    gaming, workstation
# Platforms:   ubuntu-24.04, ubuntu-22.04
# Dependencies: 02-core-packages.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
source "$REPO_ROOT/shared/logging.sh"

require_not_root

export DEBIAN_FRONTEND=noninteractive

APP_ID="com.discordapp.Discord"

log_info "Checking for existing Discord installation..."
if flatpak info "$APP_ID" &>/dev/null; then
    log_ok "Discord already installed, skipping"
    exit 0
fi

if ! command -v flatpak &>/dev/null; then
    log_info "Installing flatpak..."
    sudo -E apt-get update -y
    sudo -E apt-get install -y flatpak
    log_ok "flatpak installed"
else
    log_ok "flatpak already present"
fi

log_info "Adding the Flathub remote (if not already present)..."
sudo flatpak remote-add --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo
log_ok "Flathub remote ready"

log_info "Installing Discord from Flathub..."
sudo flatpak install -y flathub "$APP_ID"
log_ok "Discord installed"

log_info "Discord is installed. Launch it from the application menu or run:"
log_info "  flatpak run $APP_ID"
log_warn "If the menu entry or 'flatpak' PATH integration is missing, log out and back in (or reboot) once."
log_ok "Discord install complete"
