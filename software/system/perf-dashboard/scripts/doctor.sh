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
# check_tier3   — Task 1.2

main() {
  check_tier3   # security-critical first
  check_tier2
  check_tier1
  printf '\n=== Summary: %d passed, %d failed ===\n' "$PASS_COUNT" "$FAIL_COUNT"
  [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
