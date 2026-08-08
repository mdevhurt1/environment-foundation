#!/usr/bin/env bash
# Description: Installs the Steam client with i386 support
# Profiles:    gaming, workstation
# Platforms:   ubuntu-24.04, ubuntu-22.04
# Dependencies: 02-core-packages.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
source "$REPO_ROOT/shared/logging.sh"

require_not_root

export DEBIAN_FRONTEND=noninteractive

log_info "Checking for existing Steam installation..."
if command -v steam &>/dev/null; then
    log_ok "Steam already installed, skipping"
    exit 0
fi

log_info "Enabling i386 (32-bit) architecture — required for many Steam games..."
sudo dpkg --add-architecture i386
sudo -E apt-get update -y
log_ok "i386 architecture enabled"

log_info "Installing Steam..."
sudo -E apt-get install -y steam-installer
log_ok "Steam installed"

log_info "Steam is installed. Launch it from the application menu or run: steam"
log_info "Enable Proton for Windows games: Steam → Settings → Compatibility"
log_ok "Steam install complete"
