#!/usr/bin/env bash
# Description: Post-install acceptance test for the perf-dashboard module — checks each of the three tiers (Vitals extension, Conky, Netdata) is installed and running. Thin acceptance gate; scripts/doctor.sh does the deep drift and security checks.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: gnome-extensions, conky, netdata, curl (installed by install.sh)

set -uo pipefail   # NOTE: no -e — we want every check to run and report.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

VITALS_UUID="Vitals@CoreCoding.com"

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

log_info "Verifying Performance Dashboard install (3 tiers)..."

# --- Tier 1: Vitals GNOME extension --------------------------------------
# gnome-extensions is absent on non-GNOME sessions. That is a legitimately
# absent prerequisite, not a module failure -> warn and skip the whole tier.
if command -v gnome-extensions &>/dev/null; then
  check "Tier 1: Vitals extension installed" \
    bash -c "gnome-extensions list 2>/dev/null | grep -qx '$VITALS_UUID'"
  check "Tier 1: Vitals extension enabled" \
    bash -c "gnome-extensions list --enabled 2>/dev/null | grep -qx '$VITALS_UUID'"
else
  log_warn "Tier 1: gnome-extensions not available — not a GNOME session, skipping"
fi

# --- Tier 2: Conky --------------------------------------------------------
check "Tier 2: conky binary present" command -v conky
check "Tier 2: conkyrc deployed" test -f "$HOME/.config/conky/perf-dashboard.conkyrc"
check "Tier 2: widgets.lua deployed" test -f "$HOME/.config/conky/widgets.lua"
check "Tier 2: conky-helpers.sh deployed and executable" \
  test -x "$HOME/.config/conky/conky-helpers.sh"

# Conky only draws under X11. Wayland is a legitimately different session
# type, not a broken install -> warn and skip.
if [ "${XDG_SESSION_TYPE:-}" = "x11" ]; then
  check "Tier 2: conky is running" pgrep -x conky
else
  log_warn "Tier 2: session is '${XDG_SESSION_TYPE:-unset}', not x11 — skipping the running check"
fi

# --- Tier 3: Netdata ------------------------------------------------------
check "Tier 3: netdata reachable on loopback" \
  curl -sf --connect-timeout 2 http://127.0.0.1:19999/api/v1/info

echo
if [[ "$fails" -eq 0 ]]; then
  log_ok "All checks passed. All three tiers are installed and running."
  log_info "Netdata dashboard: http://127.0.0.1:19999/"
  log_info "For drift, security and resource-budget checks: bash $SCRIPT_DIR/doctor.sh"
  exit 0
else
  log_error "$fails check(s) failed."
  log_warn "Re-run: bash $SCRIPT_DIR/install.sh && bash $SCRIPT_DIR/configure.sh"
  log_warn "For detail on which tier drifted: bash $SCRIPT_DIR/doctor.sh"
  exit 1
fi
