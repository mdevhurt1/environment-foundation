#!/usr/bin/env bash
# Shared logging and guard functions for environment-foundation scripts.
#
# Source this file near the top of every script using the pattern:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   REPO_ROOT="$(cd "$SCRIPT_DIR/<relative path to repo root>" && pwd)"
#   source "$REPO_ROOT/shared/logging.sh"

log_info()  { printf '[INFO]  %s\n' "$*"; }
log_ok()    { printf '[OK]    %s\n' "$*"; }
log_warn()  { printf '[WARN]  %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

# require_command <cmd> [hint]
# Exits 1 if <cmd> is not on PATH. <hint> should be a recovery instruction.
require_command() {
    local cmd="$1"
    local hint="${2:-install $cmd before running this script}"
    if ! command -v "$cmd" &>/dev/null; then
        log_error "$cmd not found — $hint"
        exit 1
    fi
}

# require_not_root
# Exits 1 if the calling script is run as root. All scripts expect a
# normal user with sudo access.
require_not_root() {
    if [ "$(id -u)" -eq 0 ]; then
        log_error "Do not run this script as root. Use a normal user with sudo access."
        exit 1
    fi
}
