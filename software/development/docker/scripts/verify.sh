#!/usr/bin/env bash
# Description: Post-install acceptance test for the docker module — checks the CLI, the compose plugin, the daemon service, and that the current user can reach the daemon without sudo. Tests capability, not package provenance.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04
# Dependencies: docker engine + compose plugin (installed by install.sh), user in the docker group (configure.sh)

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

log_info "Verifying Docker install..."

# Checks target capability, never package names. Docker Engine legitimately
# arrives either as docker-ce/containerd.io/docker-compose-plugin from Docker's
# own repo (what install.sh does) or as docker.io/containerd/docker-compose-v2
# from the Ubuntu archive. Both are working installs; asserting on package
# names would fail a perfectly good machine.

# 1. CLI on PATH.
check "docker CLI on PATH" command -v docker

# 2. CLI runs and reports a version.
check "docker --version runs" docker --version

# 3. Compose v2 available as a docker subcommand.
check "docker compose plugin available" docker compose version

# 4. Daemon enabled at boot and currently running.
check "docker service enabled at boot" systemctl is-enabled docker
check "docker service active" systemctl is-active docker

# 5. The group membership configure.sh grants. Requires a re-login to take
#    effect, so a failure here usually means "you have not logged out yet".
check "$USER in the docker group" \
  bash -c 'id -nG "$USER" | tr " " "\n" | grep -qx docker'

# 6. The check that actually matters: can this user talk to the daemon
#    without sudo? This is what the group membership buys.
check "docker info succeeds without sudo" docker info

echo

# Informational only — provenance, not a pass/fail criterion.
if [ -f /etc/apt/sources.list.d/docker.list ]; then
  log_info "Provenance: Docker's official apt repository (docker-ce)."
else
  log_info "Provenance: no /etc/apt/sources.list.d/docker.list — Docker Engine"
  log_info "  came from the Ubuntu archive (docker.io). Both are supported."
fi

if [[ "$fails" -eq 0 ]]; then
  log_ok "All checks passed. Versions:"
  docker --version
  docker compose version
  log_info "Smoke-test container execution when you have network:"
  log_info "  docker run --rm hello-world"
  exit 0
else
  log_error "$fails check(s) failed."
  log_warn "If only the group or 'docker info' check failed, log out and back in."
  log_warn "Otherwise re-run: bash $SCRIPT_DIR/install.sh && bash $SCRIPT_DIR/configure.sh"
  exit 1
fi
