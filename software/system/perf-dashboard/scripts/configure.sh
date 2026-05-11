#!/usr/bin/env bash
# Description: Per-user configuration for perf-dashboard (dconf, Conky autostart, AMD card detection).
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: dconf-cli, conky-all, lm-sensors (installed by install.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
MODULE_ROOT="$(dirname "$SCRIPT_DIR")"
CANONICAL="$MODULE_ROOT/canonical"
source "$REPO_ROOT/shared/logging.sh"

require_not_root

# Tier-specific functions added below by later tasks:
# apply_vitals_dconf      — Task 3.3
# detect_amd_card         — Task 2.5
# place_conky_configs     — Task 2.5
# register_conky_autostart — Task 2.5

main() {
  apply_vitals_dconf
  place_conky_configs
  register_conky_autostart
  log_ok  "Configure complete."
  log_info "  Vitals: log out and back in to activate."
  log_info "  Conky:  starts on next login (or run: conky -c ~/.config/conky/perf-dashboard.conkyrc &)."
  log_info "  Netdata: http://127.0.0.1:19999/"
}

main "$@"
