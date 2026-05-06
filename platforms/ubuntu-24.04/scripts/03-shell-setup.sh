#!/usr/bin/env bash
# Description: Installs zsh, sets it as default shell, installs oh-my-zsh
# Profiles:    all
# Platforms:   ubuntu-24.04
# Dependencies: 02-core-packages.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$REPO_ROOT/shared/logging.sh"

require_not_root
require_command curl "run 02-core-packages.sh first"

log_info "Checking zsh..."
if command -v zsh &>/dev/null; then
    log_ok "zsh already installed, skipping"
else
    log_info "Installing zsh..."
    sudo apt-get install -y zsh
    log_ok "zsh installed"
fi

log_info "Checking default shell..."
CURRENT_SHELL="$(getent passwd "$USER" | cut -d: -f7)"
if [ "$CURRENT_SHELL" = "$(command -v zsh)" ]; then
    log_ok "zsh is already the default shell, skipping"
else
    sudo usermod -s "$(command -v zsh)" "$USER"
    log_ok "Default shell set to zsh — open a new terminal for this to take effect"
fi

log_info "Checking oh-my-zsh..."
if [ -d "$HOME/.oh-my-zsh" ]; then
    log_ok "oh-my-zsh already installed, skipping"
else
    log_info "Installing oh-my-zsh..."
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    log_ok "oh-my-zsh installed"
fi

log_ok "Shell setup complete"
