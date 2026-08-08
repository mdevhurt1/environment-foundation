#!/usr/bin/env bash
# Description: Removes OBS Studio and its PPA. Dry run by default; --yes to proceed. Never touches scene collections, profiles or recordings, and leaves ffmpeg in place.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: apt, add-apt-repository (obs-studio installed by install.sh)
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

PPA="ppa:obsproject/obs-studio"
PPA_MATCH="obsproject/obs-studio"

ASSUME_YES=0
case "${1:-}" in
  --yes) ASSUME_YES=1 ;;
  "")    ASSUME_YES=0 ;;
  *)     log_error "Unknown argument: $1 (only --yes is accepted)"; exit 2 ;;
esac

plan() { printf '  - %s\n' "$*"; }
keep() { printf '  . %s\n' "$*"; }

log_info "OBS Studio uninstall would REMOVE:"
plan "apt package: obs-studio"
plan "apt source: $PPA"

log_info "and would deliberately KEEP:"
keep "~/.config/obs-studio — scene collections, profiles, hotkeys (user data)"
keep "any recordings or captures on disk (user data)"
keep "ffmpeg — a shared codec dependency other software relies on"

if [ "$ASSUME_YES" -ne 1 ]; then
  log_warn "Dry run — nothing was removed. Re-run with --yes to proceed."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive

if dpkg -s obs-studio &>/dev/null; then
  log_info "Removing obs-studio..."
  sudo -E apt-get remove -y obs-studio
  sudo -E apt-get autoremove -y
  log_ok "obs-studio removed."
else
  log_ok "obs-studio is not installed — skipping."
fi

if grep -Rqs "$PPA_MATCH" /etc/apt/sources.list.d/ 2>/dev/null; then
  log_info "Removing the OBS Studio PPA..."
  sudo add-apt-repository -y -r "$PPA"
  sudo -E apt-get update -y
  log_ok "PPA removed."
else
  log_ok "OBS Studio PPA is not configured — skipping."
fi

log_ok "OBS Studio uninstall complete."
log_info "Your scenes and profiles are still at ~/.config/obs-studio."
