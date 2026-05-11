#!/usr/bin/env bash
# Description: Installs system-level components for the perf-dashboard module (Netdata, Conky, lm-sensors, GNOME Vitals).
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: curl, gnome-shell 46+, apt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
MODULE_ROOT="$(dirname "$SCRIPT_DIR")"
CANONICAL="$MODULE_ROOT/canonical"
source "$REPO_ROOT/shared/logging.sh"

require_not_root

fail() { log_error "$*"; exit 1; }

require_x11_or_warn() {
  if [[ "${XDG_SESSION_TYPE:-}" != "x11" ]]; then
    log_warn "session is '${XDG_SESSION_TYPE:-unknown}'. Tier 2 (Conky) requires X11."
    log_warn "conky-all will install but configure.sh will skip its autostart."
  fi
}

require_gnome() {
  require_command gnome-shell "install GNOME desktop — this module requires GNOME 46+"
  local gnome_ver
  gnome_ver=$(gnome-shell --version | awk '{print $3}' | cut -d. -f1)
  if [[ "$gnome_ver" -lt 46 ]]; then
    log_error "GNOME Shell 46+ required (found $gnome_ver) — upgrade GNOME or use Ubuntu 24.04+"
    exit 1
  fi
}

# Tier-specific functions are added below by later tasks.
# install_apt_packages   — Task 2.4
# run_sensors_detect     — Task 2.4
# install_vitals         — Task 3.2

install_netdata() {
  if command -v netdata >/dev/null 2>&1 && systemctl is-enabled --quiet netdata; then
    log_info "Netdata already installed — skipping kickstart"
  else
    log_info "Installing Netdata (official kickstart, telemetry disabled)..."
    bash <(curl -SsL https://my-netdata.io/kickstart.sh) \
      --stable-channel --disable-telemetry --no-updates --non-interactive
  fi

  log_info "Applying canonical Netdata config..."
  sudo cp "$CANONICAL/tier3-netdata/netdata.conf" /etc/netdata/netdata.conf
  sudo chown root:netdata /etc/netdata/netdata.conf
  sudo chmod 0644 /etc/netdata/netdata.conf

  # Copy any custom alert overrides (initially empty).
  if [[ -d "$CANONICAL/tier3-netdata/health.d" ]]; then
    sudo mkdir -p /etc/netdata/health.d
    # Copy non-dotfiles only (.gitkeep is a repo marker, not a Netdata file).
    find "$CANONICAL/tier3-netdata/health.d" -maxdepth 1 -type f ! -name '.*' -exec sudo cp {} /etc/netdata/health.d/ \;
  fi

  log_info "Restarting Netdata..."
  sudo systemctl restart netdata
}

verify_netdata_bind() {
  log_info "Waiting up to 15s for Netdata to come up..."
  local attempt
  for attempt in $(seq 1 15); do
    if curl -sf "http://127.0.0.1:19999/api/v1/info" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  log_info "Verifying Netdata bind..."
  # Parse the Local Address column only. For LISTEN sockets the Peer Address
  # is always 0.0.0.0:* (v4) or [::]:* (v6) regardless of bind interface, so
  # we must not grep the whole line.
  local local_addrs
  local_addrs=$(ss -tlnH "( sport = :19999 )" 2>/dev/null | awk '{print $4}')
  if [[ -z "$local_addrs" ]]; then
    fail "Nothing listening on port 19999 — Netdata may have failed to start. Check: journalctl -u netdata"
  fi
  while IFS= read -r addr; do
    case "$addr" in
      127.0.0.1:19999|"[::1]:19999") ;;
      *) fail "SECURITY: Netdata bound to non-loopback address — refusing. Found: $addr" ;;
    esac
  done <<< "$local_addrs"
  log_ok "Netdata bound to loopback only ($(echo "$local_addrs" | paste -sd, -))"
}

main() {
  require_x11_or_warn
  require_gnome
  # Tier 3 first (security-critical bind verification).
  install_netdata
  verify_netdata_bind
  # Tier 2 next (apt packages used by Tier 2's userspace bits).
  # install_apt_packages    # added in Task 2.4
  # run_sensors_detect      # added in Task 2.4
  # Tier 1 last (requires user action to log out / log in).
  # install_vitals          # added in Task 3.2
  log_ok "Install complete. Next: bash scripts/configure.sh, then log out and back in."
}

main "$@"
