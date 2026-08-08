#!/usr/bin/env bash
# Description: Post-install acceptance test for the steam module — checks the package installed, the launcher is on PATH, i386 multiarch is enabled, and the desktop entry exists.
# Profiles:    gaming, workstation
# Platforms:   ubuntu-24.04, ubuntu-22.04
# Dependencies: steam-installer (installed by install.sh)

set -uo pipefail   # NOTE: no -e — we want every check to run and report.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
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

log_info "Verifying Steam install..."

# 1. Package installed (dpkg is the source of truth).
check "steam-installer package installed" \
  bash -c 'dpkg -s steam-installer 2>/dev/null | grep -q "^Status: install ok installed"'

# 2. Launcher on PATH (/usr/games/steam on 24.04).
check "steam launcher on PATH" command -v steam

# 3. i386 multiarch enabled — most of the Steam runtime and many titles are
#    32-bit. Without it Steam installs but games fail to launch.
check "i386 foreign architecture enabled" \
  bash -c 'dpkg --print-foreign-architectures | grep -qx i386'

# 4. Desktop entry present (application-menu integration).
check "desktop entry present" test -f /usr/share/applications/steam.desktop

echo
if [[ "$fails" -eq 0 ]]; then
  log_ok "All checks passed. Steam version:"
  dpkg-query -W -f '${Package} ${Version}\n' steam-installer 2>/dev/null || true
  log_info "First launch downloads the Steam runtime — allow several minutes."
  log_info "Enable Proton for Windows games: Steam -> Settings -> Compatibility"
  exit 0
else
  log_error "$fails check(s) failed."
  log_warn "Re-run the installer: bash $SCRIPT_DIR/install.sh"
  log_warn "If only the i386 check failed: sudo dpkg --add-architecture i386 && sudo apt-get update"
  exit 1
fi
