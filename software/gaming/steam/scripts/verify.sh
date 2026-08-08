#!/usr/bin/env bash
# Description: Post-install acceptance test for the steam module — checks the launcher is on PATH, i386 multiarch is enabled, and the desktop entry exists. Tests capability, not package provenance.
# Profiles:    gaming, workstation
# Platforms:   ubuntu-24.04, ubuntu-22.04
# Dependencies: a working Steam launcher (installed by install.sh; may arrive as steam-installer, Valve's own .deb, or the flatpak)

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

# Checks target capability, never a specific package name. Steam legitimately
# arrives from Ubuntu's multiverse archive (steam-installer, what's on this
# machine), from Valve's own .deb, or as the com.valvesoftware.Steam flatpak.
# All three produce a fully working Steam; asserting on a package name would
# fail two of the three.
#
# There is no safe capability probe beyond "on PATH" here: the launcher
# script execs straight into the proprietary client (downloading and
# installing it on first run) regardless of arguments, so invoking it —
# even with something that looks like a --version flag — risks launching
# Steam or triggering a network install. Unlike docker's `docker --version`,
# no genuinely safe no-op invocation exists across all three provenances, so
# the check set below is kept to presence and integration checks rather than
# inventing a risky one.

# 1. Launcher on PATH (/usr/games/steam on 24.04).
check "steam launcher on PATH" command -v steam

# 2. i386 multiarch enabled — most of the Steam runtime and many titles are
#    32-bit. Without it Steam installs but games fail to launch.
check "i386 foreign architecture enabled" \
  bash -c 'dpkg --print-foreign-architectures | grep -qx i386'

# 3. Desktop entry present (application-menu integration).
check "desktop entry present" test -f /usr/share/applications/steam.desktop

echo

# Informational only — provenance, not a pass/fail criterion.
if dpkg -s steam-installer &>/dev/null; then
  log_info "Provenance: Ubuntu multiverse archive (steam-installer)."
elif dpkg -s steam-launcher &>/dev/null || dpkg -s steam &>/dev/null; then
  log_info "Provenance: Valve's own steam .deb."
elif command -v flatpak &>/dev/null && flatpak info com.valvesoftware.Steam &>/dev/null; then
  log_info "Provenance: flatpak (com.valvesoftware.Steam)."
else
  log_info "Provenance: unknown — steam is on PATH but none of the known"
  log_info "  package/flatpak sources were detected."
fi

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
