#!/usr/bin/env bash
# Description: The canonical staged-commands template carries the host-guard shapes AI_ST-100 requires — hostname pin, staging-time sha256 check, both-ends checksum echo around cross-machine copies — and the templates README registers it with its usage contract.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, coreutils

set -uo pipefail   # NOT -e: every assertion must run and report.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=./harness.sh
# shellcheck disable=SC1091
. "$TESTS_DIR/harness.sh"

require_not_root

TPL="${TPL:-$MODULE_DIR/canonical/templates/staged-commands.md}"
RDM="${RDM:-$MODULE_DIR/canonical/templates/README.md}"

t_begin "staged-commands template: host-guard shapes (AI_ST-100)"

# The 2026-09-11 wrong-host incident (AI_ST-100 / MONIT-17): staged '!'
# deploy commands ran on the wrong machine, shipped a stale file to prod,
# and every command exited 0. The guard's job is to make that loud. Each
# assertion below pins one shape the convention requires; a template that
# drops one silently reverts to the incident's preconditions.
if [ ! -f "$TPL" ]; then
    t_fail "staged-commands.md exists beside dispatch-brief.md" "missing: $TPL"
    t_finish; exit 1
fi
t_pass "staged-commands.md exists beside dispatch-brief.md"
body=$(cat "$TPL")

assert_contains "the hostname pin is the exact guard shape" \
    '[ "$(hostname)" = "{{expected_hostname}}" ] || { echo WRONG-MACHINE; exit 1; }' "$body"
assert_contains "the hash check verifies against a staging-time hash" \
    'sha256sum -c -' "$body"
assert_contains "a failed hash check is loud and fatal" \
    'STALE-OR-WRONG-FILE; exit 1' "$body"
assert_contains "the hash is probed at staging time, not recalled" \
    "The hash is probed, not recalled" "$body"
assert_contains "cross-machine copies echo checksums on both ends" \
    "echo checksums on both ends" "$body"
assert_contains "the both-ends echo names the sending end" \
    "# sending end" "$body"
assert_contains "the both-ends echo names the receiving end" \
    "# receiving end" "$body"
assert_contains "guard and mutations travel as one block" \
    "travel as one block" "$body"
assert_contains "a guard failure means re-stage, never override" \
    "never to be overridden by hand" "$body"
assert_contains "the template cites its incident ticket" \
    "AI_ST-100" "$body"
assert_contains "the template scopes itself to mutation/copy sequences" \
    "Read-only command sequences need no guard" "$body"
assert_contains "the no-copied-constants rule is restated for staging time" \
    "NO copied environment constants" "$body"

# README registration: the usage contract lives beside the template, same
# as dispatch-brief.md's.
readme=$(cat "$RDM")
assert_contains "README registers staged-commands.md by name" \
    "staged-commands.md" "$readme"
assert_contains "README states who instantiates it" \
    "Who instantiates it" "$readme"
assert_contains "README states when the guard is mandatory" \
    "When it is mandatory" "$readme"
assert_contains "README states hashes are probed at staging time" \
    "at staging time" "$readme"
assert_contains "README registers the brief's fork negative-scope clause" \
    "fork/subagent negative-scope clause" "$readme"

t_finish
