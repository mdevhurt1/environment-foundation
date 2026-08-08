#!/usr/bin/env bash
# Description: Installs Docker Engine (CE) from Docker's official repository
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04
# Dependencies: curl, gnupg, ca-certificates (from 02-core-packages.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
source "$REPO_ROOT/shared/logging.sh"

require_not_root
export DEBIAN_FRONTEND=noninteractive
require_command curl "run platforms/ubuntu-24.04/scripts/02-core-packages.sh first"

log_info "Checking for existing Docker installation..."
if command -v docker &>/dev/null; then
    log_ok "Docker already installed: $(docker --version), skipping"
    exit 0
fi

log_info "Adding Docker's official GPG key..."
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
log_ok "GPG key added"

log_info "Adding Docker repository..."
echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
log_ok "Docker repository added"

log_info "Installing Docker Engine..."
sudo apt-get update -y
sudo apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
log_ok "Docker Engine installed: $(docker --version)"
