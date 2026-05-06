#!/usr/bin/env bash
# Description: Adds current user to docker group and enables Docker on boot
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04
# Dependencies: docker installed (install.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
source "$REPO_ROOT/shared/logging.sh"

require_not_root
require_command docker "install Docker first: bash $SCRIPT_DIR/install.sh"

log_info "Adding $USER to the docker group..."
if groups "$USER" | grep -q '\bdocker\b'; then
    log_ok "$USER is already in the docker group, skipping"
else
    sudo usermod -aG docker "$USER"
    log_ok "$USER added to the docker group"
    log_warn "Log out and back in for group membership to take effect"
fi

log_info "Enabling Docker service on boot..."
sudo systemctl enable docker
sudo systemctl start docker
log_ok "Docker service enabled and started"

log_ok "Docker configuration complete"
