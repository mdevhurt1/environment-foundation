#!/usr/bin/env bash
# Description: Installs core utilities needed before any software modules
# Profiles:    all
# Platforms:   ubuntu-24.04
# Dependencies: 01-system-update.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$REPO_ROOT/shared/logging.sh"

require_not_root

PACKAGES=(
    build-essential
    curl
    wget
    git
    vim
    htop
    tree
    unzip
    zip
    jq
    software-properties-common
    apt-transport-https
    ca-certificates
    gnupg
    lsb-release
)

log_info "Installing core packages..."
sudo apt-get install -y "${PACKAGES[@]}"
log_ok "Core packages installed"
