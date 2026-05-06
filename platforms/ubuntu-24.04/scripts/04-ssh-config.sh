#!/usr/bin/env bash
# Description: Generates an ED25519 SSH keypair if one does not already exist
# Profiles:    all
# Platforms:   ubuntu-24.04
# Dependencies: 02-core-packages.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$REPO_ROOT/shared/logging.sh"

require_not_root

SSH_KEY="$HOME/.ssh/id_ed25519"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

log_info "Checking for existing SSH key at $SSH_KEY..."
if [ -f "$SSH_KEY" ]; then
    log_ok "SSH key already exists, skipping generation"
else
    log_info "Generating ED25519 SSH keypair..."
    ssh-keygen -t ed25519 -C "$(hostname)-$(date +%Y-%m-%d)" -f "$SSH_KEY" -N ""
    log_ok "SSH keypair generated at $SSH_KEY"
fi

log_info "Your public key — add this to GitHub, GitLab, or remote servers:"
printf '\n'
cat "${SSH_KEY}.pub"
printf '\n'
log_ok "SSH config complete"
