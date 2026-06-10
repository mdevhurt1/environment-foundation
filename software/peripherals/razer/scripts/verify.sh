#!/usr/bin/env bash
# Description: Post-install acceptance test for the razer module — checks the DKMS module built, the daemon is available, the user is in plugdev, and Polychromatic sees the device.
# Profiles:    workstation, gaming
# Platforms:   ubuntu-24.04
# Dependencies: openrazer-meta, polychromatic (installed by install.sh)

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

log_info "Verifying Razer module install..."

# 1. DKMS module built and installed.
check "DKMS razer module built/installed" bash -c 'dkms status 2>/dev/null | grep -qi razer'

# 2. Daemon binary present (version prints).
check "openrazer-daemon available" bash -c 'openrazer-daemon -v'

# 3. User in plugdev group (the reboot gate took effect).
check "$USER in plugdev group" bash -c 'id -nG "$USER" | tr " " "\n" | grep -qx plugdev'

# 4. Polychromatic sees at least one device.
check "polychromatic-cli lists a device" bash -c 'polychromatic-cli --list-devices 2>/dev/null | grep -qi razer'

echo
if [[ "$fails" -eq 0 ]]; then
  log_ok "All checks passed. Listing devices:"
  polychromatic-cli --list-devices 2>/dev/null || true
  exit 0
else
  log_error "$fails check(s) failed."
  log_warn "If the plugdev check failed, you have not rebooted since install.sh."
  log_warn "If the DKMS check failed, ensure linux-headers-\$(uname -r) is installed, then: sudo dkms autoinstall && reboot"
  exit 1
fi
