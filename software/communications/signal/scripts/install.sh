#!/usr/bin/env bash
# Description: Installs Signal Desktop from Signal's official apt repository (signed-by keyring in /usr/share/keyrings, deb822 source in /etc/apt/sources.list.d).
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: curl, gpg, apt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
source "$REPO_ROOT/shared/logging.sh"

require_not_root
require_command curl "install curl: sudo apt-get install -y curl"
require_command gpg  "install gnupg: sudo apt-get install -y gnupg"

export DEBIAN_FRONTEND=noninteractive

# Endpoints and destinations are Signal's own, current as of the official
# install page (signal.org/download/linux). Signal serves the deb822 source
# file itself, so we fetch it verbatim rather than hardcode the suite/arch,
# which have drifted historically.
KEY_URL="https://updates.signal.org/desktop/apt/keys.asc"
SOURCES_URL="https://updates.signal.org/static/desktop/apt/signal-desktop.sources"
KEYRING="/usr/share/keyrings/signal-desktop-keyring.gpg"
SOURCES="/etc/apt/sources.list.d/signal-desktop.sources"

# --- 1. Signing key (dearmored keyring, signed-by target) ---------------------
# Guard on *validity*, not mere existence: a keyring gpg can parse is trusted;
# an empty/corrupt file (e.g. a dearmored error page) is re-fetched.
install_keyring() {
  if [ -f "$KEYRING" ] && gpg --show-keys "$KEYRING" &>/dev/null; then
    log_ok "Signal signing key already present and valid ($KEYRING) — skipping."
    return
  fi
  [ -f "$KEYRING" ] && log_warn "Existing keyring is unreadable — re-fetching."
  log_info "Fetching Signal signing key and installing dearmored keyring..."
  local tmp
  tmp="$(mktemp)"
  curl -fsSL "$KEY_URL" | gpg --dearmor > "$tmp"
  sudo install -m 0644 "$tmp" "$KEYRING"
  rm -f "$tmp"
  log_ok "Installed keyring at $KEYRING"
}

# --- 2. apt source (deb822, fetched from Signal so it stays current) ----------
# Guard on *content*, not mere existence: a stale/corrupt file (a prior broken
# fetch on this repo left a saved 404 HTML page here) must be rewritten, or apt
# fails. We treat the source as present only if it names the Signal repo.
install_sources() {
  if [ -f "$SOURCES" ] && grep -q '^URIs:.*updates\.signal\.org' "$SOURCES"; then
    log_ok "Signal apt source already present and valid ($SOURCES) — skipping."
    return
  fi
  [ -f "$SOURCES" ] && log_warn "Existing apt source is not a valid Signal deb822 file — rewriting."
  log_info "Fetching Signal apt source list (deb822)..."
  local tmp
  tmp="$(mktemp)"
  curl -fsSL "$SOURCES_URL" -o "$tmp"
  # Sanity-check what we fetched before installing it, so a server error page
  # never lands in /etc/apt/sources.list.d.
  if ! grep -q '^URIs:.*updates\.signal\.org' "$tmp"; then
    rm -f "$tmp"
    log_error "Fetched apt source did not look like a Signal deb822 file — aborting."
    exit 1
  fi
  sudo install -m 0644 "$tmp" "$SOURCES"
  rm -f "$tmp"
  log_ok "Installed apt source at $SOURCES"
}

# --- 3. Install the package ---------------------------------------------------
install_signal() {
  if dpkg -s signal-desktop &>/dev/null; then
    log_ok "signal-desktop already installed — skipping."
    return
  fi
  log_info "Updating apt and installing signal-desktop..."
  sudo -E apt-get update -y
  sudo -E apt-get install -y signal-desktop
  log_ok "signal-desktop installed."
}

main() {
  install_keyring
  install_sources
  install_signal
  log_ok "Signal Desktop install complete."
  log_info "Launch it from the application menu or run: signal-desktop"
  log_info "First launch shows a QR code — link it from your phone: Signal → Settings → Linked Devices → +"
  log_info "Verify the install with: bash $SCRIPT_DIR/verify.sh"
}

main "$@"
