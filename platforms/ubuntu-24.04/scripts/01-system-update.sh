#!/usr/bin/env bash
# Description: Updates system packages and removes stale dependencies
# Profiles:    all
# Platforms:   ubuntu-24.04
# Dependencies: none

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$REPO_ROOT/shared/logging.sh"

require_not_root

log_info "Starting system update..."

log_info "Updating package lists..."
sudo apt-get update -y
log_ok "Package lists updated"

log_info "Upgrading installed packages..."
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
log_ok "Packages upgraded"

log_info "Removing unused packages..."
sudo apt-get autoremove -y
log_ok "Cleanup complete"

log_ok "System update finished"
