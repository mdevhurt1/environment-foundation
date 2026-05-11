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

# Tier-specific check functions added below by later tasks:
# check_tier1   — Task 3.4
# check_tier2   — Task 2.6

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

  local update_every
  update_every=$(curl -s "http://127.0.0.1:19999/api/v1/info" 2>/dev/null | jq -r '.update_every // "n/a"')
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
