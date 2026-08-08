#!/usr/bin/env bash
# Description: Post-install acceptance test for the streamdeck module — checks Boatswain is installed, the udev rule is in place, and an Elgato device is attached and accessible.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: com.feaneron.Boatswain, 10-streamdeck.rules (installed by install.sh)

set -uo pipefail   # NOTE: no -e — we want every check to run and report.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

APP_ID="com.feaneron.Boatswain"
RULE_PATH="/etc/udev/rules.d/10-streamdeck.rules"

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

log_info "Verifying Stream Deck module install..."

# 1. Boatswain flatpak present.
check "Boatswain flatpak installed" flatpak info "$APP_ID"

# 2. udev rule file present and matching the Elgato vendor ID.
check "udev rule present ($RULE_PATH)" bash -c "[ -f '$RULE_PATH' ] && grep -q '0fd9' '$RULE_PATH'"

# 3. A Stream Deck is physically attached. Informational — the module installs
#    correctly with no device present, so this is reported but not fatal.
if lsusb 2>/dev/null | grep -qi '0fd9:'; then
  log_ok "Elgato device attached: $(lsusb | grep -i '0fd9:' | sed 's/^.*ID /ID /')"

  # 4. The hidraw node is user-accessible — this is what the udev rule buys.
  #    Only meaningful when a device is actually present.
  accessible=0
  for dev in /dev/hidraw*; do
    [ -e "$dev" ] || continue
    if [ -r "$dev" ] && [ -w "$dev" ]; then accessible=1; break; fi
  done
  if [ "$accessible" -eq 1 ]; then
    log_ok "at least one hidraw node is read/write for $USER"
  else
    log_error "no hidraw node is read/write for $USER"
    log_warn "the udev rule has not taken effect — unplug and reconnect the Stream Deck"
    fails=$((fails + 1))
  fi
else
  log_warn "no Elgato (0fd9) device attached — connect the Stream Deck to fully verify"
fi

echo
if [[ "$fails" -eq 0 ]]; then
  log_ok "All checks passed."
  log_info "Launch with: flatpak run $APP_ID"
  exit 0
else
  log_error "$fails check(s) failed."
  log_warn "If the udev or hidraw check failed, re-run install.sh, then unplug and"
  log_warn "reconnect the device so it re-enumerates under the rule."
  exit 1
fi
