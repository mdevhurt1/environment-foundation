#!/usr/bin/env bash
# Description: Removes the Obsidian desktop application. Dry run by default;
#              --yes to proceed. Never touches the vault, the app's own data,
#              or the LiveSync settings — those carry the CouchDB endpoint,
#              credentials and the E2E passphrase, and are irreplaceable.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: apt/dpkg (or flatpak/snap, whichever provided Obsidian)
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

VAULT_DIR="${VAULT_DIR:-$HOME/vault}"
FLATPAK_ID="md.obsidian.Obsidian"

ASSUME_YES=0
case "${1:-}" in
  --yes) ASSUME_YES=1 ;;
  "")    ASSUME_YES=0 ;;
  *)     log_error "Unknown argument: $1 (only --yes is accepted)"; exit 2 ;;
esac

plan() { printf '  - %s\n' "$*"; }
keep() { printf '  . %s\n' "$*"; }

have_deb=0;     dpkg -s obsidian &>/dev/null && have_deb=1
have_flatpak=0; flatpak info "$FLATPAK_ID" &>/dev/null && have_flatpak=1
have_snap=0;    snap list obsidian &>/dev/null && have_snap=1

log_info "Obsidian uninstall would REMOVE:"
[ "$have_deb"     -eq 1 ] && plan "apt package: obsidian"
[ "$have_flatpak" -eq 1 ] && plan "flatpak app: $FLATPAK_ID"
[ "$have_snap"    -eq 1 ] && plan "snap: obsidian"
if [ "$have_deb" -eq 0 ] && [ "$have_flatpak" -eq 0 ] && [ "$have_snap" -eq 0 ]; then
  plan "(nothing — no Obsidian package is installed)"
fi

log_info "and would deliberately KEEP:"
keep "$VAULT_DIR — the vault itself. User data; never touched by this module."
keep "$VAULT_DIR/.obsidian/ — workspace, themes, and every community plugin."
keep "$VAULT_DIR/.obsidian/plugins/obsidian-livesync/data.json — the LiveSync"
keep "    settings, holding the encrypted CouchDB connection and E2E passphrase."
keep "    Deleting this costs you the setup URI, not just a preference."
keep "~/.config/obsidian/ — application state (open vaults, window layout)."
keep "~/.local/bin/obsidian — Obsidian's optional CLI helper, if you installed it."

if [ "$ASSUME_YES" -ne 1 ]; then
  log_warn "Dry run — nothing was removed. Re-run with --yes to proceed."
  exit 0
fi

if [ "$have_deb" -eq 1 ]; then
  log_info "Removing the obsidian apt package..."
  sudo DEBIAN_FRONTEND=noninteractive apt-get remove -y obsidian
  log_ok "apt package removed."
fi
if [ "$have_flatpak" -eq 1 ]; then
  log_info "Removing $FLATPAK_ID..."
  sudo flatpak uninstall -y "$FLATPAK_ID"
  log_ok "flatpak removed."
fi
if [ "$have_snap" -eq 1 ]; then
  log_info "Removing the obsidian snap..."
  sudo snap remove obsidian
  log_ok "snap removed."
fi
if [ "$have_deb" -eq 0 ] && [ "$have_flatpak" -eq 0 ] && [ "$have_snap" -eq 0 ]; then
  log_ok "No Obsidian package was installed — nothing to do."
fi

log_ok "Obsidian uninstall complete."
log_info "Your vault at $VAULT_DIR is untouched, sync settings included."
log_warn "Nothing replicates while Obsidian is uninstalled: LiveSync runs inside"
log_warn "the app. Any edit made to the vault from the shell meanwhile will not"
log_warn "sync, and may be reverted the next time Obsidian opens."
