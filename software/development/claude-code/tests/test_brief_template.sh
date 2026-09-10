#!/usr/bin/env bash
# Description: The canonical dispatch-brief template carries the board-discipline clauses the convention requires (AI_ST-99) — the bookend carve-out naming the helper, the per-bookend-step re-check that INFRA-86 failed without, and the never-revert rule.
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

TPL="${TPL:-$MODULE_DIR/canonical/templates/dispatch-brief.md}"

t_begin "dispatch-brief template: board-discipline clauses (convention S6)"

# Every brief the EA writes is instantiated from this file, so a clause that
# is not here is a clause someone has to remember. All three below were
# learned from a recorded failure, not from design:
#   MEDIA-5, AI_ST-56, INFRA-86, INFRA-72 (four bookend/board collisions)
body=$(cat "$TPL")

assert_contains "the single-writer rule is stated" \
    "The EA owns every Plane write" "$body"
assert_contains "the bookend carve-out names the helper (AI_ST-87)" \
    "cc-plane-sync.sh" "$body"
assert_contains "the carve-out names both write subcommands" \
    'start`/`finish' "$body"
assert_contains "the per-bookend-step re-check is stated (INFRA-86)" \
    "Re-check this clause at each bookend step" "$body"
assert_contains "the per-step clause cites the run that failed without it" \
    "INFRA-86" "$body"
assert_contains "the never-revert rule is stated" \
    "never revert it" "$body"
assert_contains "a landed bookend write is named in the completion event" \
    "completion event" "$body"

t_finish
