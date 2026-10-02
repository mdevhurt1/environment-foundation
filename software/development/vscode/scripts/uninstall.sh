#!/usr/bin/env bash
# Description: Removes the apt-installed VS Code package, its apt source and
#              (if nothing else uses it) the Microsoft keyring. Dry run by
#              default; --yes to proceed. Never touches user settings or
#              installed extensions, and never removes a snap it did not install.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: apt (code installed by install.sh)
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

KEYRING="/usr/share/keyrings/microsoft.gpg"
SOURCES="/etc/apt/sources.list.d/vscode.sources"

ASSUME_YES=0
case "${1:-}" in
  --yes) ASSUME_YES=1 ;;
  "")    ASSUME_YES=0 ;;
  *)     log_error "Unknown argument: $1 (only --yes is accepted)"; exit 2 ;;
esac

# microsoft.gpg is a generic name other Microsoft repos (Edge, packages-microsoft-prod)
# also point at; keep it if any other apt source still references it.
keyring_shared() {
  grep -rlsF "$KEYRING" /etc/apt/sources.list.d/ 2>/dev/null | grep -vxF "$SOURCES" | grep -q .
}

plan() { printf '  - %s\n' "$*"; }
keep() { printf '  . %s\n' "$*"; }

log_info "VS Code uninstall would REMOVE:"
plan "apt package: code (if installed from apt)"
plan "apt source: $SOURCES"
if keyring_shared; then
  keep "keyring: $KEYRING — another apt source still references it"
else
  plan "keyring: $KEYRING"
fi

log_info "and would deliberately KEEP:"
keep "$HOME/.config/Code — user settings, keybindings, state (user data)"
keep "$HOME/.vscode/extensions — installed extensions (user data)"
if snap list code &>/dev/null; then
  keep "the code snap — not installed by this module (remove by hand: sudo snap remove code)"
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  log_warn "Dry run — nothing was removed. Re-run with --yes to proceed."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive

if dpkg -s code &>/dev/null; then
  log_info "Removing code..."
  sudo -E apt-get remove -y code
  log_ok "code removed."
else
  log_ok "code apt package is not installed — skipping."
fi

if [ -f "$SOURCES" ]; then
  sudo rm -f "$SOURCES"
  log_ok "removed $SOURCES"
else
  log_ok "$SOURCES already absent."
fi

if [ ! -f "$KEYRING" ]; then
  log_ok "$KEYRING already absent."
elif keyring_shared; then
  log_ok "kept $KEYRING (still referenced by another apt source)."
else
  sudo rm -f "$KEYRING"
  log_ok "removed $KEYRING"
fi

log_info "Refreshing apt after removing the source..."
sudo -E apt-get update -y

log_ok "VS Code uninstall complete."
log_info "Settings remain in ~/.config/Code and extensions in ~/.vscode/extensions — remove them by hand if you want them gone."
