#!/usr/bin/env bash
# Description: Post-install acceptance test for the obs-studio module — checks the package installed, the binary is on PATH, and the desktop entry exists.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: obs-studio (installed by install.sh)

set -uo pipefail   # NOTE: no -e — we want every check to run and report.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
source "$REPO_ROOT/shared/logging.sh"

require_not_root

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

log_info "Verifying OBS Studio install..."

# 1. Package installed (dpkg registers it).
check "obs-studio package installed" bash -c 'dpkg -s obs-studio 2>/dev/null | grep -q "^Status: install ok installed"'

# 2. Launcher binary on PATH.
check "obs binary on PATH" command -v obs

# 3. Desktop entry present (application-menu integration).
check "desktop entry present" test -f /usr/share/applications/com.obsproject.Studio.desktop

echo
if [[ "$fails" -eq 0 ]]; then
  log_ok "All checks passed. OBS Studio version:"
  dpkg-query -W -f '${Package} ${Version}\n' obs-studio 2>/dev/null || true
  log_info "Launch it from the application menu or run: obs"
  exit 0
else
  log_error "$fails check(s) failed."
  log_warn "Re-run the installer: bash $SCRIPT_DIR/install.sh"
  exit 1
fi
