#!/usr/bin/env bash
# Description: Tests for __cc_write_sandbox_settings and __cc_find_sandbox_settings — the fragment that decides what a sandboxed session may write, and the upward walk that finds it.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, jq, canonical/shell/cc-functions.sh

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

CC_FUNCTIONS_UNDER_TEST="${CC_FUNCTIONS_UNDER_TEST:-$MODULE_DIR/canonical/shell/cc-functions.sh}"
# shellcheck source=../canonical/shell/cc-functions.sh
# shellcheck disable=SC1091
source "$CC_FUNCTIONS_UNDER_TEST"

t_begin "__cc_write_sandbox_settings / __cc_find_sandbox_settings"

if ! command -v jq >/dev/null 2>&1; then
    t_fail "jq is available" "jq is a hard dependency of these assertions"
    t_finish; exit $?
fi

# t_sandbox_env is not optional here, it is a SAFETY device. The writer does
# `mkdir -p "$HOME/vault/20-surface/company/tasks/<id>"`, so a run with the
# operator's real HOME would create directories in the live vault -- including,
# on the traversal cases below, outside tasks/ entirely.
t_sandbox_env || { t_fail "sandbox env"; t_finish; exit 1; }

FRAG=.cc-sandbox-settings.json
TASKS="$HOME/vault/20-surface/company/tasks"

# aw <file> -- the allowWrite array, one entry per line.
aw()    { jq -r '.sandbox.filesystem.allowWrite[]' "$1" 2>/dev/null; }
awn()   { jq -r '.sandbox.filesystem.allowWrite | length' "$1" 2>/dev/null; }

# =========================================================================
# 1. Shape. --settings REPLACES the sandbox object wholesale, so anything the
#    fragment omits is not inherited from settings.json -- it is GONE for the
#    session. The six base carveouts are therefore asserted individually and
#    by count: a silent drop is the failure mode with no symptom until a
#    bookend cannot write its own transcript.
# =========================================================================
D1=$(t_tmpdir) || { t_fail "fixture dir"; t_finish; exit 1; }
t_run __cc_write_sandbox_settings "$D1"
assert_eq "writer returns 0 with no task id" 0 "$T_RC"

if [ ! -f "$D1/$FRAG" ]; then
    t_fail "fragment written to <dir>/$FRAG" "not found in $D1"
    t_finish; exit $?
fi
t_pass "fragment written to <dir>/$FRAG"

assert_rc "the fragment is valid JSON" 0 jq -e . "$D1/$FRAG"
assert_eq "sandbox is enabled"        "true" "$(jq -r '.sandbox.enabled'          "$D1/$FRAG")"
assert_eq "failIfUnavailable is true" "true" "$(jq -r '.sandbox.failIfUnavailable' "$D1/$FRAG")"

BASE1=$(aw "$D1/$FRAG")
for want in \
    "~/vault/20-surface/claude-memory" \
    "~/vault/20-surface/claude-transcripts" \
    "~/vault/20-surface/claude-specs" \
    "~/vault/20-surface/claude-plans" \
    "~/vault/20-surface/company/tree/sessions" \
    "~/vault/20-surface/company/_command-center/state/promotion-queue.md" ; do
    assert_contains "base carveout present: $want" "$want" "$BASE1"
done
assert_eq "no task id means exactly the six base entries" 6 "$(awn "$D1/$FRAG")"

# The promotion queue is granted as a FILE. Granting its parent would hand the
# session the EA's whole operational state dir, which is the scoping mistake
# this entry is deliberately written to avoid.
assert_not_contains "the queue's parent state/ dir is NOT granted" \
    '"~/vault/20-surface/company/_command-center/state"' "$(cat "$D1/$FRAG")"

# =========================================================================
# 2. The INFRA-54 per-session task folder: exactly one entry, for THIS task.
# =========================================================================
D2=$(t_tmpdir) || { t_fail "fixture dir"; t_finish; exit 1; }
t_run __cc_write_sandbox_settings "$D2" "INFRA-54"
assert_eq "writer returns 0 with a task id" 0 "$T_RC"
assert_eq "a task id adds exactly one entry" 7 "$(awn "$D2/$FRAG")"
assert_contains "the task folder is granted" \
    "~/vault/20-surface/company/tasks/INFRA-54" "$(aw "$D2/$FRAG")"

# THE SCOPING ASSERTION. A blanket tasks/ entry would give every EXPLORE
# session write access to every other task's spec, plan and report. Compare
# entries EXACTLY: `assert_not_contains` on the parent path would also match
# the legitimate child entry and pass for the wrong reason.
leak=""
while IFS= read -r e; do
    case "$e" in
        "~/vault/20-surface/company/tasks"|"~/vault/20-surface/company/tasks/") leak="$e" ;;
        "~/vault/20-surface/company"|"~/vault/20-surface"|"~/vault"|"~"|"~/") leak="$e" ;;
    esac
done <<<"$(aw "$D2/$FRAG")"
assert_eq "no entry grants the tasks/ parent or any ancestor" "" "$leak"

# The carveout is INERT unless the directory exists -- creating it would itself
# be a write to tasks/, which stays denied. So the launcher must create it.
assert_rc "the task folder is created by the launching (unsandboxed) shell" 0 \
    test -d "$TASKS/INFRA-54"

# A sibling's folder is neither granted nor created.
assert_not_contains "a sibling task folder is not granted" \
    "tasks/INFRA-25" "$(aw "$D2/$FRAG")"

# =========================================================================
# 3. Rejected task ids. The value reaches BOTH a JSON string and a mkdir path,
#    and cc-continue reads it back out of a file a human can edit -- so the
#    validation is a security boundary, not tidiness. A rejected id must drop
#    the ENTRY (never emit a broken fragment) and must not create anything.
# =========================================================================
reject_case() {  # reject_case <label> <task-id> [<path that must not exist>]
    local label="$1" id="$2" ghost="${3:-}" d err
    d=$(t_tmpdir) || { t_fail "$label fixture"; return; }
    t_run __cc_write_sandbox_settings "$d" "$id"
    # Snapshot stderr NOW: assert_rc runs t_run itself and would overwrite it.
    err="$T_ERR"
    assert_eq "$label: writer still returns 0" 0 "$T_RC"
    assert_rc "$label: fragment is still valid JSON" 0 jq -e . "$d/$FRAG"
    assert_eq "$label: entry dropped, six base entries remain" 6 "$(awn "$d/$FRAG")"
    assert_contains "$label: warns on stderr" "not [a-zA-Z0-9_-]+" "$err"
    assert_not_contains "$label: no tasks/ entry at all" "company/tasks" "$(aw "$d/$FRAG")"
    if [ -n "$ghost" ]; then
        assert_rc "$label: created nothing at $ghost" 1 test -e "$ghost"
    fi
}

# Path traversal: the id is interpolated into `mkdir -p $HOME/vault/.../tasks/$id`.
reject_case "traversal id"      "../../../../pwned"  "$HOME/pwned"
reject_case "slash in id"       "INFRA-54/etc"       "$TASKS/INFRA-54/etc"
# Command substitution: the id also lands in a JSON string the sandbox reads.
reject_case "command sub in id" 'a$(touch /tmp/cc-pwned)b'
reject_case "quote in id"       'a"b'
reject_case "space in id"       'my task'
reject_case "empty-ish id"      ' '

# An id of "" is not a rejection -- it is the "no task id" call, which must
# stay silent rather than warn about a value nobody supplied.
D3=$(t_tmpdir) || { t_fail "fixture dir"; t_finish; exit 1; }
t_run __cc_write_sandbox_settings "$D3" ""
assert_eq "an empty task id is the no-task call, not a rejection" 6 "$(awn "$D3/$FRAG")"
assert_not_contains "  ... and it does not warn" "not [a-zA-Z0-9_-]+" "$T_ERR"

# =========================================================================
# 4. Idempotence and overwrite. cc-continue REGENERATES the fragment in place
#    on every resume; if the writer appended, or left a stale wider grant
#    behind, a resumed session would drift from the one it resumed.
# =========================================================================
D4=$(t_tmpdir) || { t_fail "fixture dir"; t_finish; exit 1; }
__cc_write_sandbox_settings "$D4" "harness-coverage" 2>/dev/null
first=$(cat "$D4/$FRAG")
__cc_write_sandbox_settings "$D4" "harness-coverage" 2>/dev/null
assert_eq "rewriting with the same task id is byte-identical" "$first" "$(cat "$D4/$FRAG")"
assert_eq "  ... and does not accumulate entries" 7 "$(awn "$D4/$FRAG")"

__cc_write_sandbox_settings "$D4" "other-task" 2>/dev/null
assert_contains "a rewrite adopts the new task" "tasks/other-task" "$(aw "$D4/$FRAG")"
assert_not_contains "  ... and DROPS the previous task's grant" \
    "tasks/harness-coverage" "$(aw "$D4/$FRAG")"
assert_eq "  ... still exactly one task entry" 7 "$(awn "$D4/$FRAG")"

# =========================================================================
# 5. __cc_find_sandbox_settings -- the reader half. cc-continue writes the
#    regenerated fragment AT THE PATH THIS WALK RETURNS, so a wrong answer
#    strands a second fragment in a subdirectory and the session keeps
#    launching under the stale one.
# =========================================================================
W=$(t_tmpdir) || { t_fail "fixture dir"; t_finish; exit 1; }
# The walk runs to /, so an ancestor fragment would make the "not found" case
# pass for the wrong reason. Same hazard t_tmpdir guards for .cc-mode.
probe=$W
while [ "$probe" != "/" ] && [ -n "$probe" ]; do
    probe=$(dirname "$probe")
    [ -f "$probe/$FRAG" ] && { t_fail "no ancestor fragment shadows the fixture" "found $probe/$FRAG"; break; }
done
mkdir -p "$W/root/mid/leaf"

( cd "$W/root/mid/leaf" && __cc_find_sandbox_settings >/dev/null 2>&1 )
assert_eq "no fragment anywhere: returns non-zero" 1 "$?"
assert_eq "no fragment anywhere: prints nothing" "" \
    "$(cd "$W/root/mid/leaf" && __cc_find_sandbox_settings 2>/dev/null)"

__cc_write_sandbox_settings "$W/root" "outer" 2>/dev/null
assert_eq "found by walking up from a deep subdir" "$W/root/$FRAG" \
    "$(cd "$W/root/mid/leaf" && __cc_find_sandbox_settings 2>/dev/null)"
assert_eq "found in cwd itself" "$W/root/$FRAG" \
    "$(cd "$W/root" && __cc_find_sandbox_settings 2>/dev/null)"

# NEAREST wins, not outermost: cc-continue must regenerate the one the session
# actually launches under.
__cc_write_sandbox_settings "$W/root/mid" "inner" 2>/dev/null
assert_eq "the nearest fragment wins on the upward walk" "$W/root/mid/$FRAG" \
    "$(cd "$W/root/mid/leaf" && __cc_find_sandbox_settings 2>/dev/null)"

t_finish
