#!/usr/bin/env bash
# Description: Installs the Obsidian desktop application from the official .deb
#              release if no Obsidian is already present. Deploys no vault or
#              plugin configuration — the Self-hosted LiveSync settings are
#              per-device mutable state that this module verifies, never ships.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: curl, python3, apt, dpkg-deb
# Idempotent. Detects an existing Obsidian of any provenance and skips.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root
require_command curl    "install curl: sudo apt-get install -y curl"
require_command python3 "install python3: sudo apt-get install -y python3"

export DEBIAN_FRONTEND=noninteractive

# Obsidian ships no apt repository. The official Linux artifact is a .deb
# attached to each GitHub release of obsidianmd/obsidian-releases.
RELEASES_API="https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest"

# --- Detection -----------------------------------------------------------------
# Capability, not provenance (docs/module-contract.md): a deb, a flatpak, a snap
# and an AppImage are all "Obsidian is installed" and none of them should be
# stacked on top of another.
detect_obsidian() {
  if [ -x /opt/Obsidian/obsidian ]; then
    echo "deb/tarball at /opt/Obsidian/obsidian"; return 0
  fi
  if flatpak info md.obsidian.Obsidian &>/dev/null; then
    echo "flatpak md.obsidian.Obsidian"; return 0
  fi
  if snap list obsidian &>/dev/null; then
    echo "snap obsidian"; return 0
  fi
  # Last: a binary named `obsidian` on PATH. Deliberately last — on a machine
  # with Obsidian's optional CLI helper installed this name resolves to the
  # helper, which talks to a *running* app and is not the app itself.
  if command -v obsidian &>/dev/null; then
    echo "binary on PATH at $(command -v obsidian)"; return 0
  fi
  return 1
}

# --- Release resolution --------------------------------------------------------
# Prints "<version> <url>" for the amd64 .deb of the latest release.
resolve_deb_url() {
  curl -fsSL -H 'Accept: application/vnd.github+json' "$RELEASES_API" | python3 -c '
import json, sys
try:
    rel = json.load(sys.stdin)
except Exception as exc:
    sys.exit("could not parse the GitHub releases response: %s" % exc)
tag = str(rel.get("tag_name", "")).lstrip("v")
for asset in rel.get("assets", []):
    name = asset.get("name", "")
    if name.endswith("_amd64.deb") and not name.endswith("-arm64.deb"):
        print(tag, asset["browser_download_url"])
        break
else:
    sys.exit("release %s has no amd64 .deb asset" % (tag or "<unknown>"))
'
}

install_obsidian() {
  local found version url tmpdir deb
  if found="$(detect_obsidian)"; then
    log_ok "Obsidian is already installed ($found) — skipping."
    log_info "This script never upgrades in place; update Obsidian from within the app."
    return
  fi

  log_info "No Obsidian found. Resolving the latest official release..."
  read -r version url < <(resolve_deb_url)
  log_info "Latest release is $version"

  tmpdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN
  deb="$tmpdir/obsidian_${version}_amd64.deb"

  log_info "Downloading $url"
  curl -fsSL "$url" -o "$deb"

  # Sanity-check the payload before handing it to apt, so a redirect to an
  # error page never reaches dpkg. Same discipline as the signal module.
  if ! dpkg-deb -I "$deb" &>/dev/null; then
    log_error "Downloaded file is not a valid Debian package — aborting."
    exit 1
  fi
  log_ok "Downloaded package verified as a Debian archive."

  log_info "Installing..."
  sudo -E apt-get install -y "$deb"
  log_ok "Obsidian $version installed."
}

main() {
  install_obsidian

  cat <<'EOF'

[INFO]  Obsidian is installed. Sync is NOT configured by this module.

        Self-hosted LiveSync is per-device state: its settings carry the CouchDB
        endpoint, credentials and an E2E passphrase, so they are configured in
        the app and are never version-controlled here. See the module README.

        To finish setup on a new device:
          1. Open the vault, then Settings -> Community plugins -> Browse
             -> "Self-hosted LiveSync" -> Install -> Enable.
          2. Apply the setup URI from your password manager (LiveSync ->
             "Use the copied setup URI"). Never paste it into this repo.
          3. Enable at least one auto-sync trigger. A device with every trigger
             off is fully configured and silently never replicates.
          4. Run scripts/verify.sh — it fails on exactly that state.
EOF
  log_info "Verify the install with: bash $SCRIPT_DIR/verify.sh"
}

main "$@"
