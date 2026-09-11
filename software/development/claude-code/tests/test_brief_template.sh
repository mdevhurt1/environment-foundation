#!/usr/bin/env bash
# Description: The canonical dispatch-brief template carries the standing clauses the conventions require — board discipline (AI_ST-99: bookend carve-out, per-step re-check, never-revert), fork/subagent negative scope (AI_ST-101), and the staged-command host-guard pointer (AI_ST-100).
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

# Fork/subagent negative-scope clause (AI_ST-101 item 3). Learned from the
# 2026-09-11 enpm703-review incident: two read-only forks redid the whole
# task, bypassed a Write refusal via Bash heredoc, and emitted completion
# events under the dispatcher's identity.
assert_contains "the fork clause states the full negative scope" \
    "no writes, no memory edits, no event emission" "$body"
assert_contains "the fork clause reserves the dispatcher's identity" \
    "dispatcher's identity is not yours to stamp" "$body"
assert_contains "a Write refusal is never re-attempted via another tool" \
    "never to be" "$body"
assert_contains "the refusal rule names the bypass route it forbids" \
    "re-attempted through Bash" "$body"
assert_contains "the fork clause cites its incident ticket" \
    "AI_ST-101" "$body"
assert_contains "the fork clause requires a post-completion side-effect check" \
    "check for side effects" "$body"

# Staged-command host-guard pointer (AI_ST-100): one sentence + pointer,
# not a duplicate of the guard block — the block lives in
# staged-commands.md (linted by test_staged_commands_template.sh).
assert_contains "the staged-commands section points at the guard template" \
    "templates/staged-commands.md" "$body"
assert_contains "the pointer covers cross-machine copy or mutation staging" \
    "stages cross-machine copy or" "$body"
assert_contains "the pointer names the guard's two checks" \
    "hostname pin plus" "$body"
assert_contains "the pointer cites its incident ticket" \
    "AI_ST-100" "$body"
assert_not_contains "the brief does not duplicate the guard block itself" \
    'echo WRONG-MACHINE; exit 1' "$body"

t_finish
