#!/usr/bin/env bash
# Description: Post-install acceptance test for the vscode module — checks the
#              `code` binary runs and reports a version, the update channel
#              (apt source, or the snap) is present, and every extension
#              declared in canonical/extensions.txt is installed.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: code (installed by install.sh, or the snap)

set -uo pipefail   # NOTE: no -e — we want every check to run and report.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

SOURCES="/etc/apt/sources.list.d/vscode.sources"
EXT_LIST="$SCRIPT_DIR/../canonical/extensions.txt"

fails=0
check() {
  # check "<label>" <command...>
  local label="$1"; shift
  if "$@" &>/dev/null; then
    log_ok "$label"
  else
    log_error "$label"
    fails=$((fails + 1))
  fi
}

log_info "Verifying VS Code install..."

# 1. Binary on PATH.
check "code binary on PATH" command -v code

# 2. It actually runs and reports a version (a real no-op call).
check "code --version reports a version" bash -c 'code --version 2>/dev/null | head -1 | grep -qE "^[0-9]+\.[0-9]+"'

# 3. Update channel. The apt source is what install.sh creates; a snap install
#    updates itself through snapd and needs no apt source, so that case warns
#    and skips rather than failing (capability, not provenance).
if [ -f "$SOURCES" ] && grep -q '^URIs:.*packages\.microsoft\.com/repos/code' "$SOURCES"; then
  log_ok "VS Code apt source present ($SOURCES)"
elif snap list code &>/dev/null; then
  log_warn "No VS Code apt source — code is a snap and updates through snapd; skipping this check."
else
  log_error "No update channel: neither $SOURCES nor a code snap is present"
  fails=$((fails + 1))
fi

# 4. Declared extensions installed (one check per extension, so a miss names it).
if [ -f "$EXT_LIST" ] && command -v code &>/dev/null; then
  installed="$(code --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r ext; do
    ext="$(printf '%s' "$ext" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    [ -n "$ext" ] || continue
    check "extension $ext installed" grep -qxF "$ext" <<< "$installed"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$EXT_LIST")
else
  log_error "cannot check extensions (list at $EXT_LIST or the code binary is missing)"
  fails=$((fails + 1))
fi

echo
if [[ "$fails" -eq 0 ]]; then
  log_ok "All checks passed. VS Code version: $(code --version 2>/dev/null | head -1)"
  exit 0
else
  log_error "$fails check(s) failed."
  log_warn "Re-run the installer: bash $SCRIPT_DIR/install.sh"
  exit 1
fi
