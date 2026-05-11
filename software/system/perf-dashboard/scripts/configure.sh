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

fail() { log_error "$*"; exit 1; }

apply_vitals_dconf() {
  log_info "Applying Vitals dconf settings..."
  local f="$CANONICAL/tier1-vitals/dconf-vitals.ini"
  if [[ ! -f "$f" ]]; then
    fail "Canonical Vitals dconf not found at $f — run Task 3.1 to capture it."
  fi
  dconf load /org/gnome/shell/extensions/vitals/ < "$f"
  log_ok "Vitals settings applied (effective at next GNOME session login)."
}

detect_amd_card() {
  local c
  for c in /sys/class/drm/card[0-9]; do
    [[ -r "$c/device/vendor" ]] || continue
    if [[ "$(cat "$c/device/vendor")" == "0x1002" ]]; then
      basename "$c"
      return 0
    fi
  done
  log_warn "no AMD GPU detected — iGPU section will show 'n/a'"
  printf "card_none"
}

place_conky_configs() {
  log_info "Placing Conky configs in ~/.config/conky/..."
  mkdir -p "$HOME/.config/conky"
  local amd_card
  amd_card=$(detect_amd_card)
  log_info "Templating AMD card token: __AMD_CARD__ → $amd_card"
  sed "s|__AMD_CARD__|$amd_card|g" \
    "$CANONICAL/tier2-conky/perf-dashboard.conkyrc" \
    > "$HOME/.config/conky/perf-dashboard.conkyrc"
  cp "$CANONICAL/tier2-conky/widgets.lua" "$HOME/.config/conky/widgets.lua"
  install -m 0755 "$CANONICAL/tier2-conky/conky-helpers.sh" \
    "$HOME/.config/conky/conky-helpers.sh"
}

register_conky_autostart() {
  if [[ "${XDG_SESSION_TYPE:-}" != "x11" ]]; then
    log_warn "session is not X11 (got '${XDG_SESSION_TYPE:-unknown}') — skipping Conky autostart"
    rm -f "$HOME/.config/autostart/perf-dashboard-conky.desktop"
    return 0
  fi
  log_info "Registering Conky autostart..."
  mkdir -p "$HOME/.config/autostart"
  cp "$CANONICAL/tier2-conky/perf-dashboard-conky.desktop" \
     "$HOME/.config/autostart/perf-dashboard-conky.desktop"
}

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
