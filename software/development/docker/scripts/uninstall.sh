#!/usr/bin/env bash
# Description: Removes Docker Engine, the compose plugin, Docker's apt source and keyring, and the docker group membership. Dry run by default; --yes to proceed. NEVER removes /var/lib/docker, volumes or images.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04
# Dependencies: apt, systemctl, gpasswd (docker installed by install.sh / configure.sh)
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

APT_SOURCE="/etc/apt/sources.list.d/docker.list"
APT_KEYRING="/etc/apt/keyrings/docker.gpg"

# Docker Engine legitimately arrives two ways. install.sh fetches the first
# set from Docker's own repository; a machine provisioned from the Ubuntu
# archive carries the second. Detect which is present and remove only that.
DOCKER_CE_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
DOCKER_IO_PKGS=(docker.io docker-compose-v2 containerd)

installed_pkgs=()
for pkg in "${DOCKER_CE_PKGS[@]}" "${DOCKER_IO_PKGS[@]}"; do
  if dpkg -s "$pkg" &>/dev/null; then
    installed_pkgs+=("$pkg")
  fi
done

ASSUME_YES=0
case "${1:-}" in
  --yes) ASSUME_YES=1 ;;
  "")    ASSUME_YES=0 ;;
  *)     log_error "Unknown argument: $1 (only --yes is accepted)"; exit 2 ;;
esac

plan() { printf '  - %s\n' "$*"; }
keep() { printf '  . %s\n' "$*"; }

log_info "Docker uninstall would REMOVE:"
if [ "${#installed_pkgs[@]}" -eq 0 ]; then
  plan "(no Docker packages are installed — nothing to remove)"
else
  plan "apt packages: ${installed_pkgs[*]}"
fi
[ -f "$APT_SOURCE" ]  && plan "apt source: $APT_SOURCE"
[ -f "$APT_KEYRING" ] && plan "keyring: $APT_KEYRING"
if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
  plan "$USER's membership of the docker group (configure.sh added it)"
fi

log_info "and would deliberately KEEP:"
keep "/var/lib/docker — ALL images, containers, volumes and build cache"
keep "any bind-mounted host directories your containers used (user data)"
keep "the docker group itself — removing it could orphan other accounts"

log_warn "Nothing in /var/lib/docker is touched. If you want images and volumes"
log_warn "gone too, do it deliberately BEFORE running this with --yes:"
log_warn "  docker system prune -a --volumes"

if [ "$ASSUME_YES" -ne 1 ]; then
  log_warn "Dry run — nothing was removed. Re-run with --yes to proceed."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive

if systemctl is-active --quiet docker; then
  log_info "Stopping and disabling the docker service..."
  sudo systemctl stop docker || true
  sudo systemctl disable docker || true
  log_ok "docker service stopped and disabled."
else
  log_ok "docker service is not active — skipping."
fi

if [ "${#installed_pkgs[@]}" -gt 0 ]; then
  log_info "Removing: ${installed_pkgs[*]}"
  sudo -E apt-get remove -y "${installed_pkgs[@]}"
  sudo -E apt-get autoremove -y
  log_ok "Docker packages removed."
else
  log_ok "No Docker packages installed — skipping."
fi

if [ -f "$APT_SOURCE" ]; then
  sudo rm -f "$APT_SOURCE"
  log_ok "removed $APT_SOURCE"
else
  log_ok "$APT_SOURCE already absent (Ubuntu-archive provenance) — skipping."
fi

if [ -f "$APT_KEYRING" ]; then
  sudo rm -f "$APT_KEYRING"
  log_ok "removed $APT_KEYRING"
else
  log_ok "$APT_KEYRING already absent — skipping."
fi

if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
  log_info "Removing $USER from the docker group..."
  sudo gpasswd -d "$USER" docker
  log_ok "$USER removed from the docker group."
  log_warn "Log out and back in for the group change to take effect."
else
  log_ok "$USER is not in the docker group — skipping."
fi

log_info "Refreshing apt..."
sudo -E apt-get update -y

log_ok "Docker uninstall complete."
log_warn "/var/lib/docker was NOT touched — images, containers and volumes remain."
log_warn "Remove it by hand only if you are certain: sudo rm -rf /var/lib/docker"
