#!/usr/bin/env bash
# Description: Bisection helper for systematic-debugging — runs a suite's test files one at a time and stops at the first one that creates a named file or directory.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, coreutils, findutils
#
# Usage: find-polluter.sh <path_to_check> <test_pattern>
#   <path_to_check>  file or directory whose appearance marks the polluter
#   <test_pattern>   find(1) -path pattern for the test files, e.g. 'tests/test_*.sh'
#
# Example (this module):
#   ./find-polluter.sh /tmp/cc-leftover 'tests/test_*.sh'
#
# The runner defaults to `bash <file>`, which is how this repo's suite invokes
# each test file. Override for another stack:
#   POLLUTER_TEST_CMD='npm test'    ./find-polluter.sh .git 'src/**/*.test.ts'
#   POLLUTER_TEST_CMD='python3 -m pytest' ./find-polluter.sh out 'tests/test_*.py'
# The test file path is appended to POLLUTER_TEST_CMD as its final argument.

set -uo pipefail   # NOT -e: a failing test file is expected and must not abort the bisect.

if [ $# -ne 2 ]; then
    echo "usage: $0 <path_to_check> <test_pattern>" >&2
    echo "example: $0 /tmp/cc-leftover 'tests/test_*.sh'" >&2
    exit 2
fi

POLLUTION_CHECK="$1"
TEST_PATTERN="${2#./}"
TEST_CMD="${POLLUTER_TEST_CMD:-bash}"

echo "searching for the test that creates: $POLLUTION_CHECK"
echo "test pattern: $TEST_PATTERN"
echo "runner:       $TEST_CMD <file>"
echo

if [ -e "$POLLUTION_CHECK" ]; then
    echo "REFUSING: $POLLUTION_CHECK already exists before any test ran." >&2
    echo "Remove it first — otherwise every file looks like the polluter." >&2
    exit 1
fi

# find -path cannot match '**/' against zero directory levels, so a pattern
# like src/**/*.test.ts would skip src/top.test.ts. Try the pattern as written
# and with '**/' collapsed, then de-duplicate.
mapfile -t TEST_FILES < <(
    find . \( -path "./$TEST_PATTERN" -o -path "./${TEST_PATTERN//\*\*\//}" \) -type f | sort -u
)

TOTAL=${#TEST_FILES[@]}
if [ "$TOTAL" -eq 0 ]; then
    echo "no files matched: $TEST_PATTERN" >&2
    exit 2
fi
echo "found $TOTAL test file(s)"
echo

COUNT=0
for TEST_FILE in "${TEST_FILES[@]}"; do
    COUNT=$((COUNT + 1))
    printf '[%d/%d] %s\n' "$COUNT" "$TOTAL" "$TEST_FILE"

    # shellcheck disable=SC2086  # TEST_CMD is a user-supplied command line, word-split on purpose
    $TEST_CMD "$TEST_FILE" >/dev/null 2>&1

    if [ -e "$POLLUTION_CHECK" ]; then
        echo
        echo "FOUND POLLUTER"
        echo "  test:    $TEST_FILE"
        echo "  created: $POLLUTION_CHECK"
        echo
        ls -la "$POLLUTION_CHECK"
        echo
        echo "next:"
        echo "  $TEST_CMD $TEST_FILE   # run just this file"
        echo "  \$EDITOR $TEST_FILE    # read what it does on the way out"
        exit 1
    fi
done

echo
echo "no polluter found — all $TOTAL file(s) ran clean."
echo "If the pollution still appears in a full run, suspect ordering or"
echo "concurrency between files rather than any single file. See"
echo "condition-based-waiting.md."
exit 0
