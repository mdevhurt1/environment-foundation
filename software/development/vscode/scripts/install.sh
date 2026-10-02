#!/usr/bin/env bash
# Description: Installs Visual Studio Code from Microsoft's official apt
#              repository (signed-by keyring in /usr/share/keyrings, deb822
#              source in /etc/apt/sources.list.d), then runs configure.sh to
#              install the declared extensions. Skips the apt path entirely
#              when a `code` binary is already on PATH (e.g. the snap).
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: curl, gpg, apt
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

export DEBIAN_FRONTEND=noninteractive

# Endpoints and destinations are Microsoft's own, current as of the official
# Linux setup page (code.visualstudio.com/docs/setup/linux, read 2026-10-01).
# These are the same paths the `code` .deb's own postinst manages, so a later
# package upgrade rewrites them in place rather than adding a duplicate source.
KEY_URL="https://packages.microsoft.com/keys/microsoft.asc"
REPO_URI="https://packages.microsoft.com/repos/code"
KEYRING="/usr/share/keyrings/microsoft.gpg"
SOURCES="/etc/apt/sources.list.d/vscode.sources"

# --- 0. Already installed from any source? -----------------------------------
# VS Code ships officially as a .deb (apt repo) and as a classic snap. If a
# `code` binary is already on PATH, a second copy from apt would shadow or be
# shadowed by it, so we skip the whole apt path — before any sudo. Moving from
# the snap to apt is a manual decision; see README.md "Snap vs apt".
already_installed() {
  command -v code &>/dev/null
}

describe_existing() {
  local where version
  where="$(command -v code)"
  version="$(code --version 2>/dev/null | head -1 || true)"
  if snap list code &>/dev/null; then
    log_ok "VS Code ${version:-?} already installed as a snap ($where) — skipping the apt path."
  elif dpkg -s code &>/dev/null; then
    log_ok "VS Code ${version:-?} already installed from apt ($where) — skipping."
  else
    log_ok "VS Code ${version:-?} already on PATH ($where) — skipping the apt path."
  fi
}

# --- 1. Signing key (dearmored keyring, signed-by target) ---------------------
# Guard on validity, not mere existence: a keyring gpg can parse is trusted; an
# empty/corrupt file (e.g. a dearmored error page) is re-fetched.
install_keyring() {
  if [ -f "$KEYRING" ] && gpg --show-keys "$KEYRING" &>/dev/null; then
    log_ok "Microsoft signing key already present and valid ($KEYRING) — skipping."
    return
  fi
  [ -f "$KEYRING" ] && log_warn "Existing keyring is unreadable — re-fetching."
  require_command curl "install curl: sudo apt-get install -y curl"
  require_command gpg  "install gnupg: sudo apt-get install -y gnupg"
  log_info "Fetching Microsoft signing key and installing dearmored keyring..."
  local tmp
  tmp="$(mktemp)"
  curl -fsSL "$KEY_URL" | gpg --dearmor > "$tmp"
  if ! gpg --show-keys "$tmp" &>/dev/null; then
    rm -f "$tmp"
    log_error "Fetched key is not a valid OpenPGP key — aborting. Check $KEY_URL and re-run."
    exit 1
  fi
  sudo install -m 0644 "$tmp" "$KEYRING"
  rm -f "$tmp"
  log_ok "Installed keyring at $KEYRING"
}

# --- 2. apt source (deb822, contents per Microsoft's instructions) -----------
# Guard on content: the source counts as present only if it names the
# Microsoft code repo. Anything else at that path is rewritten.
install_sources() {
  if [ -f "$SOURCES" ] && grep -q '^URIs:.*packages\.microsoft\.com/repos/code' "$SOURCES"; then
    log_ok "VS Code apt source already present and valid ($SOURCES) — skipping."
    return
  fi
  [ -f "$SOURCES" ] && log_warn "Existing $SOURCES does not name the Microsoft code repo — rewriting."
  log_info "Writing VS Code apt source (deb822)..."
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
Types: deb
URIs: $REPO_URI
Suites: stable
Components: main
Architectures: amd64,arm64,armhf
Signed-By: $KEYRING
EOF
  sudo install -m 0644 "$tmp" "$SOURCES"
  rm -f "$tmp"
  log_ok "Installed apt source at $SOURCES"
}

# --- 3. Install the package ---------------------------------------------------
install_code() {
  if dpkg -s code &>/dev/null; then
    log_ok "code package already installed — skipping."
    return
  fi
  log_info "Updating apt and installing code..."
  sudo -E apt-get update -y
  sudo -E apt-get install -y code
  log_ok "code installed: $(code --version 2>/dev/null | head -1)"
}

main() {
  if already_installed; then
    describe_existing
  else
    install_keyring
    install_sources
    install_code
  fi

  # Extensions are per-user and need no sudo.
  bash "$SCRIPT_DIR/configure.sh"

  log_ok "VS Code install complete."
  log_info "Verify with: bash $SCRIPT_DIR/verify.sh"
}

main "$@"
