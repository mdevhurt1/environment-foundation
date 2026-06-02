#!/usr/bin/env bash
# Description: Installs Node.js 20 and Claude Code CLI via npm
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: curl (from 02-core-packages.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
source "$REPO_ROOT/shared/logging.sh"

require_not_root
require_command curl "run platforms/ubuntu-24.04/scripts/02-core-packages.sh first"

log_info "Checking Node.js version..."
if command -v node &>/dev/null; then
    NODE_MAJOR="$(node --version | cut -d. -f1 | tr -d 'v')"
    if [ "$NODE_MAJOR" -ge 20 ]; then
        log_ok "Node.js $(node --version) already installed, skipping"
    else
        log_warn "Node.js $(node --version) found but version 20+ is required — upgrading"
        curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
        sudo apt-get install -y nodejs
        log_ok "Node.js $(node --version) installed"
    fi
else
    log_info "Installing Node.js 20..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
    log_ok "Node.js $(node --version) installed"
fi

log_info "Checking Claude Code installation..."
if command -v claude &>/dev/null; then
    log_ok "Claude Code already installed at $(command -v claude), skipping"
else
    log_info "Installing Claude Code..."
    sudo npm install -g @anthropic-ai/claude-code
    log_ok "Claude Code installed: $(claude --version)"
fi

# sops is required by environment-secrets/install.sh to decrypt
# settings.local.json. Not in Ubuntu apt repos; install from GitHub release .deb.
log_info "Checking sops installation..."
if command -v sops &>/dev/null; then
    log_ok "sops $(sops --version --check-for-updates 2>/dev/null | head -1 || sops --version 2>&1 | head -1) already installed, skipping"
else
    log_info "Installing sops from GitHub release..."
    SOPS_URL=$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest \
        | jq -r '.assets[] | select(.name | test("amd64\\.deb$")) | .browser_download_url')
    [ -n "$SOPS_URL" ] || { log_error "could not determine sops .deb URL"; exit 1; }
    SOPS_DEB=$(mktemp --suffix=.deb)
    trap 'rm -f "$SOPS_DEB"' EXIT
    curl -fsSL -o "$SOPS_DEB" "$SOPS_URL"
    sudo apt-get install -y "$SOPS_DEB"
    log_ok "sops installed: $(sops --version 2>&1 | head -1)"
fi
