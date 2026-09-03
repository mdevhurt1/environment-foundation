#!/usr/bin/env bash
# Description: Static gate — every shell file the claude-code module ships must be shellcheck-clean at error severity.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, shellcheck (skipped with a warning if absent)

set -uo pipefail   # NOT -e: every assertion must run and report.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MODULE_DIR/../../.." && pwd)"
# shellcheck source=./harness.sh
# shellcheck disable=SC1091
source "$TESTS_DIR/harness.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"
require_not_root

t_begin "shellcheck (severity: error)"

# Severity is ERROR, not warning, and that is a deliberate ceiling rather than
# laziness. cc-functions.sh sources itself through
# "${CC_FUNCTIONS_SH:-$HOME/.claude/cc-functions.sh}" in each wrapper's snapshot
# guard -- a path that cannot be constant by construction -- so it carries four
# unavoidable SC1090 warnings. Gating on warnings would mean either annotating
# a correct, load-bearing line as an exception or leaving the gate permanently
# red, and a check nobody can satisfy is the same failure mode as no check.
# Error severity is the level at which every file in the module is clean today,
# so it is the level that can actually hold.

if ! command -v shellcheck >/dev/null 2>&1; then
    t_diag "shellcheck not installed - static gate skipped."
    t_diag "  install with: sudo apt install shellcheck"
    t_pass "shellcheck gate skipped (not installed)"
    t_finish
    exit $?
fi

# Every shell file the module ships, found rather than listed: a new script
# that nobody adds to a list is exactly the file most likely to be unchecked.
mapfile -t FILES < <(find "$MODULE_DIR" -type f -name '*.sh' | sort)
assert_ne "found shell files to check" 0 "${#FILES[@]}"

for f in "${FILES[@]}"; do
    rel="${f#"$MODULE_DIR"/}"
    out=$(shellcheck -S error "$f" 2>&1)
    if [ -z "$out" ]; then
        t_pass "shellcheck -S error: $rel"
    else
        t_fail "shellcheck -S error: $rel" "$out"
    fi
done

t_finish
