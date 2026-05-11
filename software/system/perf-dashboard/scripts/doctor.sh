#!/usr/bin/env bash
# Description: Runs all acceptance criteria from the spec. Exits non-zero on any failure.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: curl, jq, gnome-extensions, dconf, pgrep, systemctl, ss

# NOTE: does NOT use `set -e` — we want all checks to run even if some fail.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
MODULE_ROOT="$(dirname "$SCRIPT_DIR")"
CANONICAL="$MODULE_ROOT/canonical"
source "$REPO_ROOT/shared/logging.sh"

require_not_root

PASS_COUNT=0
FAIL_COUNT=0

pass()    { log_ok    "$*"; PASS_COUNT=$((PASS_COUNT+1)); }
fail()    { log_error "$*"; FAIL_COUNT=$((FAIL_COUNT+1)); }
section() { printf '\n=== %s ===\n' "$*"; }

check_tier1() {
  section "Tier 1 — Vitals"

  if ! command -v gnome-extensions >/dev/null 2>&1; then
    fail "gnome-extensions CLI missing — install gnome-shell"
    return 0
  fi

  local uuid="Vitals@CoreCoding.com"

  if gnome-extensions list 2>/dev/null | grep -q "^$uuid$"; then
    pass "Vitals extension is installed"
  else
    fail "Vitals extension not installed — run scripts/install.sh"
    return 0
  fi

  if gnome-extensions list --enabled 2>/dev/null | grep -q "^$uuid$"; then
    pass "Vitals extension is enabled"
  else
    fail "Vitals extension installed but not enabled — log out/in, or: gnome-extensions enable $uuid"
  fi

  local canonical="$CANONICAL/tier1-vitals/dconf-vitals.ini"
  if [[ -f "$canonical" ]]; then
    local diff_out
    diff_out=$(diff <(dconf dump /org/gnome/shell/extensions/vitals/ | sort) \
                    <(sort "$canonical") || true)
    if [[ -z "$diff_out" ]]; then
      pass "Vitals dconf matches canonical"
    else
      fail "Vitals dconf drifts from canonical — run scripts/configure.sh. Diff:"
      printf "%s\n" "$diff_out" | sed 's/^/        /'
    fi
  else
    fail "Canonical Vitals dconf missing at $canonical"
  fi
}

check_tier2() {
  section "Tier 2 — Conky"

  if command -v conky >/dev/null 2>&1; then
    pass "conky binary present"
  else
    fail "conky not installed"
    return 0
  fi

  if command -v powerprofilesctl >/dev/null 2>&1; then
    pass "powerprofilesctl present (Power section will populate)"
  else
    fail "power-profiles-daemon not installed"
  fi

  if [[ -f "$HOME/.config/conky/perf-dashboard.conkyrc" ]]; then
    pass "conkyrc placed in ~/.config/conky/"
  else
    fail "~/.config/conky/perf-dashboard.conkyrc missing — run scripts/configure.sh"
  fi
  if [[ -f "$HOME/.config/conky/widgets.lua" ]]; then
    pass "widgets.lua placed in ~/.config/conky/"
  else
    fail "~/.config/conky/widgets.lua missing — run scripts/configure.sh"
  fi
  if [[ -x "$HOME/.config/conky/conky-helpers.sh" ]]; then
    pass "conky-helpers.sh placed and executable in ~/.config/conky/"
  else
    fail "~/.config/conky/conky-helpers.sh missing or not executable — run scripts/configure.sh"
  fi

  if [[ -f "$HOME/.config/conky/perf-dashboard.conkyrc" ]] && \
       grep -q '__AMD_CARD__' "$HOME/.config/conky/perf-dashboard.conkyrc"; then
    fail "conkyrc still contains the __AMD_CARD__ placeholder — re-run configure.sh"
  elif [[ -f "$HOME/.config/conky/perf-dashboard.conkyrc" ]]; then
    pass "AMD card token has been substituted in deployed conkyrc"
  fi

  if [[ "${XDG_SESSION_TYPE:-}" == "x11" ]]; then
    if [[ -f "$HOME/.config/autostart/perf-dashboard-conky.desktop" ]]; then
      pass "Conky autostart entry registered"
    else
      fail "Conky autostart entry missing — run scripts/configure.sh"
    fi
  else
    pass "Skipping autostart check (session is not X11)"
  fi

  if [[ "${XDG_SESSION_TYPE:-}" == "x11" ]]; then
    if pgrep -x conky >/dev/null; then
      pass "Conky is running"
      local pid rss
      pid=$(pgrep -x conky | head -1)
      rss=$(ps -o rss= -p "$pid" | tr -d ' ')
      # Budget accounts for Lua module, ARGB visual, font cache, and ~5
      # rotating ${execi} subshell helpers. 50MB is a regression ceiling,
      # not a target — steady-state lives ~25-30MB on the validated machine.
      if [[ "$rss" -lt 50000 ]]; then
        pass "Conky RSS within budget (${rss}KB < 50000KB)"
      else
        fail "Conky RSS over budget: ${rss}KB"
      fi
    else
      fail "Conky not running — start manually: conky -c ~/.config/conky/perf-dashboard.conkyrc &"
    fi
  fi
}

check_tier3() {
  section "Tier 3 — Netdata"

  if curl -sf "http://127.0.0.1:19999/api/v1/info" >/dev/null 2>&1; then
    pass "Netdata reachable on http://127.0.0.1:19999/"
  else
    fail "Netdata not reachable on loopback"
    return 0   # remaining checks depend on it being up; skip them
  fi

  # Parse the Local Address column only. Peer Address for any TCP LISTEN is
  # always 0.0.0.0:* / [::]:* regardless of bind, so we cannot grep the line.
  local local_addrs bad=""
  local_addrs=$(ss -tlnH "( sport = :19999 )" 2>/dev/null | awk '{print $4}')
  if [[ -z "$local_addrs" ]]; then
    fail "Nothing listening on port 19999"
  else
    while IFS= read -r addr; do
      case "$addr" in
        127.0.0.1:19999|"[::1]:19999") ;;
        *) bad="$bad $addr" ;;
      esac
    done <<< "$local_addrs"
    if [[ -z "$bad" ]]; then
      pass "Netdata bound to loopback only ($(echo "$local_addrs" | paste -sd, -))"
    else
      fail "SECURITY: Netdata bound to non-loopback:$bad"
    fi
  fi

  local lan_ip
  lan_ip=$(ip -4 addr show 2>/dev/null | awk '/inet / && !/127\.0\.0\.1/ {print $2}' | cut -d/ -f1 | head -1)
  if [[ -n "$lan_ip" ]]; then
    if curl -sf --connect-timeout 2 "http://${lan_ip}:19999/api/v1/info" >/dev/null 2>&1; then
      fail "SECURITY: Netdata reachable on LAN IP $lan_ip — should NOT be"
    else
      pass "Netdata correctly NOT reachable on LAN IP $lan_ip"
    fi
  else
    pass "(no LAN IP detected — skipping off-loopback reachability check)"
  fi

  # /api/v1/info no longer carries update_every; /api/v1/charts does.
  local update_every
  update_every=$(curl -s "http://127.0.0.1:19999/api/v1/charts" 2>/dev/null | jq -r '.update_every // "n/a"')
  if [[ "$update_every" == "60" ]]; then
    pass "Netdata update_every is 60s"
  else
    fail "Netdata update_every is '$update_every' (expected 60)"
  fi

  if [[ -d /var/cache/netdata/dbengine ]]; then
    pass "dbengine directory exists at /var/cache/netdata/dbengine"
  else
    fail "dbengine directory not found"
  fi
}

main() {
  check_tier3   # security-critical first
  check_tier2
  check_tier1
  printf '\n=== Summary: %d passed, %d failed ===\n' "$PASS_COUNT" "$FAIL_COUNT"
  [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
