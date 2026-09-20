#!/usr/bin/env bash
# Description: The Plane reference is resolved by ONE rule (AI_ST-99) — cc-tree-slot-write.sh stamps it into the slot, and its answer must equal cc-plane-sync.sh's for every case in a shared table, so the two identity rules cannot drift apart again.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, python3, coreutils

set -uo pipefail   # NOT -e: every assertion must run and report.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=./harness.sh
# shellcheck disable=SC1091
. "$TESTS_DIR/harness.sh"

require_not_root

SLOT_SH="${SLOT_SH:-$MODULE_DIR/canonical/shell/cc-tree-slot-write.sh}"
SYNC_SH="${SYNC_SH:-$MODULE_DIR/canonical/shell/cc-plane-sync.sh}"

t_begin "plane_issue: one resolution rule, two helpers, identical answers"

# =========================================================================
# WHY THIS FILE EXISTS
#
# cc-plane-sync.sh resolves a Plane reference through four precedences.
# cmd_health implemented only the fourth, via task_id, so board health was
# blind to every session linked by .cc-mode plane_issue= or by a task
# folder's plane.md -- and to every launcher that does not name the worktree
# after the issue (cc-build, the command-center, any descriptive slug).
# Measured 2026-09-10: health reported `1 live session(s)` out of 2 running.
#
# The fix was to resolve ONCE, in cc-tree-slot-write.sh, and have health read
# the result. That leaves two implementations of one rule in two files, which
# is exactly the shape that drifted the first time. This file is the guard:
# every case below is answered by BOTH and the answers are compared.
# =========================================================================

FIX=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
export HOME="$FIX/home"
mkdir -p "$HOME" "$FIX/tasks" "$FIX/wt"

# case: <name>|<slug>|<mode plane_issue>|<plane.md ref or ->|<expected ref or empty>
CASES='
issue-shaped slug|AI_ST-99||-|AI_ST-99
descriptive slug, no folder|plane-system-of-record||-|
descriptive slug, folder knows|descriptive-slug||INFRA-41|INFRA-41
mode field wins over folder|descriptive-slug|MEDIA-5|INFRA-41|MEDIA-5
mode field wins over slug|AI_ST-99|INFRA-41|-|INFRA-41
repo-name slug|environment-foundation||-|
lowercase is not a reference|ai_st-99||-|
trailing letter is not a reference|AI_ST-99a||-|
'

while IFS='|' read -r name slug modev folder want; do
    [ -n "${name:-}" ] || continue
    rm -rf "$FIX/tasks" "$FIX/wt" "$HOME/vault"
    mkdir -p "$FIX/tasks/$slug" "$FIX/wt"
    [ "$folder" != "-" ] && printf 'plane: %s\n' "$folder" > "$FIX/tasks/$slug/plane.md"
    printf 'mode=branched\nslug=%s\nstarted_at=x\nparent_repo=/r\nsession_id=aaaaaaaaaaaaaaaaaaaaaa\nparent_id=\nmodel=\nmodel_source=\nperm_mode=\nperm_mode_source=\nplane_issue=%s\n' \
        "$slug" "$modev" > "$FIX/wt/.cc-mode"

    # env -u CC_SESSION_ID: the slot writer refuses to write a slot whose
    # session_id disagrees with an ambient CC_SESSION_ID, so this file would
    # pass outside a live session and fail inside one. Same guard as
    # test_tree_slot_write_loud.sh.

    # Side A: the slot writer. Reads the field out of the slot it wrote.
    env -u CC_SESSION_ID CC_PLANE_TASKS_DIR="$FIX/tasks" \
        bash "$SLOT_SH" --mode-file "$FIX/wt/.cc-mode" >/dev/null 2>&1
    got_slot=$(awk -F': *' '/^plane_issue:/ { print $2; exit }' \
        "$HOME/vault/20-surface/company/tree/sessions/aaaaaaaaaaaaaaaaaaaaaa.md" 2>/dev/null)

    # Side B: cc-plane-sync's own chain, via --print-ref.
    #
    # `resolve` cannot serve as side B: its identity report lives in the
    # python block BELOW the auth gate, so with no API key (which is the
    # case here, HOME being a fixture) it prints nothing at all and every
    # comparison would trivially read "". --print-ref exits before any HTTP
    # work and prints the very variable the four-precedence chain produced,
    # so it reports that chain rather than re-implementing it -- a guard that
    # reimplements what it guards proves nothing.
    got_sync=$(env -u CC_SESSION_ID CC_PLANE_TASKS_DIR="$FIX/tasks" \
        bash "$SYNC_SH" resolve --print-ref --mode-file "$FIX/wt/.cc-mode" 2>/dev/null)

    assert_eq "slot writer: $name" "$want" "${got_slot:-}"
    assert_eq "resolvers agree: $name" "${got_slot:-}" "${got_sync:-}"
done <<< "$CASES"

t_finish
