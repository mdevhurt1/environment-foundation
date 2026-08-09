#!/usr/bin/env bash
# Description: Installs OBS Studio from the official OBS Project PPA (ppa:obsproject/obs-studio), with ffmpeg as the recommended companion.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: software-properties-common (add-apt-repository), apt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
source "$REPO_ROOT/shared/logging.sh"

require_not_root
require_command add-apt-repository "install software-properties-common: sudo apt-get install -y software-properties-common"

export DEBIAN_FRONTEND=noninteractive

# The OBS Project publishes a first-party PPA (ppa:obsproject/obs-studio) with
# current builds. add-apt-repository writes a deb822 source under
# /etc/apt/sources.list.d/ whose URI points at Launchpad's obsproject/obs-studio
# archive, regardless of the Ubuntu codename or file-name format.
PPA="ppa:obsproject/obs-studio"
# Guard token that appears in the generated source file's URI on every release.
PPA_MATCH="obsproject/obs-studio"

# --- 1. Add the OBS PPA -------------------------------------------------------
# Guard on the *source already being present*, not on the package: a fresh box
# has neither, but a re-run must not add the PPA twice. We match the Launchpad
# archive path so the guard is codename- and file-format-independent.
add_ppa() {
  if grep -Rqs "$PPA_MATCH" /etc/apt/sources.list.d/ 2>/dev/null; then
    log_ok "OBS Studio PPA already configured in /etc/apt/sources.list.d — skipping."
    return
  fi
  log_info "Adding OBS Studio PPA ($PPA)..."
  sudo add-apt-repository -y "$PPA"
  log_ok "OBS Studio PPA added."
}

# --- 2. Install obs-studio ----------------------------------------------------
# Guard on dpkg state, not mere presence of a launcher: dpkg is the source of
# truth for whether apt manages this package.
install_obs() {
  if dpkg -s obs-studio &>/dev/null; then
    log_ok "obs-studio already installed — skipping."
    return
  fi
  log_info "Updating apt and installing obs-studio..."
  sudo -E apt-get update -y
  sudo -E apt-get install -y obs-studio
  log_ok "obs-studio installed."
}

# --- 3. Install ffmpeg (recommended companion) --------------------------------
# OBS recommends ffmpeg for its encoders/muxers; it is guarded independently so
# a box that has OBS but not ffmpeg still gets it on a re-run.
install_ffmpeg() {
  if dpkg -s ffmpeg &>/dev/null; then
    log_ok "ffmpeg already installed — skipping."
    return
  fi
  log_info "Installing ffmpeg (recommended for OBS encoding/muxing)..."
  sudo -E apt-get install -y ffmpeg
  log_ok "ffmpeg installed."
}

main() {
  add_ppa
  install_obs
  install_ffmpeg
  log_ok "OBS Studio install complete."
  log_info "Launch it from the application menu or run: obs"
  log_info "Verify the install with: bash $SCRIPT_DIR/verify.sh"
}

main "$@"
