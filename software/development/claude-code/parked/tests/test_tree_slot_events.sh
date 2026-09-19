#!/usr/bin/env bash
# Description: Behavioral tests for the tree-slot writers' event emission (AI_ST-74) — spawned and completion events route through cc-event-emit.sh: epoch-monotonic names in mixed-era dirs, emitter identity, enriched mechanical completion, rich-completion dedupe.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, coreutils

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

WRITE_SH="$MODULE_DIR/canonical/shell/cc-tree-slot-write.sh"
UPDATE_SH="$MODULE_DIR/canonical/shell/cc-tree-slot-update.sh"

t_begin "tree-slot writers route events through cc-event-emit.sh"

# =========================================================================
# WHY THIS FILE EXISTS (AI_ST-74)
#
# cc-tree-slot-write.sh's sequential NNNN- names were HALF of the live
# specimen: a parent dir mixing 0001..0030 with children's epoch names,
# which poisons the session-start numeric read marker (once it holds an
# epoch, every NNNN- event is 'read' forever). Both writers now emit via
# cc-event-emit.sh; these tests pin the naming in a dir seeded with BOTH
# eras, the dedupe guards, and the enriched mechanical completion body.
# =========================================================================

CHILD="abcdefabcdefabcdefabcd"
PARENT="1234561234561234561234"

mk_home() {  # fake $HOME with a vault tree; parent events dir mixes both eras
    FH=$(t_tmpdir) || return 1
    TREE="$FH/vault/20-surface/company/tree/sessions"
    PEV="$TREE/${PARENT}.events"
    mkdir -p "$PEV"
    printf -- '---\nverb: spawned\n---\n' > "$PEV/0030-spawned.md"
    printf -- '---\nverb: completion\n---\n' > "$PEV/1788466246-completion.md"
    mkdir -p "$FH/wt"
    printf 'mode=branched\nslug=T-99\nstarted_at=2026-09-03T18:00:00-04:00\nparent_repo=/tmp/x\nsession_id=%s\nparent_id=%s\n' \
        "$CHILD" "$PARENT" > "$FH/wt/.cc-mode"
}

# --- 1. spawned event: epoch-named, monotonic, child-stamped --------------

mk_home || exit 1
before=$(date +%s)
out=$(HOME="$FH" bash "$WRITE_SH" --mode-file "$FH/wt/.cc-mode" --session-id "$CHILD" 2>&1)
assert_eq "slot write exits 0" 0 $?
assert_contains "spawned event reported" "spawned event:" "$out"
sp=$(find "$PEV" -name '*-spawned.md' ! -name '0030-*' | head -1)
assert_eq "a new spawned event exists" "yes" "$( [ -n "$sp" ] && [ -f "$sp" ] && echo yes || echo no )"
lead=$(basename "$sp"); lead=${lead%%-*}
if [ "$lead" -ge "$before" ] && [ "$lead" -gt 1788466246 ]; then
    t_pass "spawned event named by epoch, above BOTH naming eras ($lead)"
else
    t_fail "spawned event named by epoch, above BOTH naming eras" "got $lead"
fi
assert_contains "spawned event stamped with the EMITTER (child) id" \
    "session_id: $CHILD" "$(cat "$sp")"
assert_contains "spawned body carries slug and mode" "slug=T-99 mode=branched" "$(cat "$sp")"

# Dedupe: re-running session-start must not spawn the child twice.
out=$(HOME="$FH" bash "$WRITE_SH" --mode-file "$FH/wt/.cc-mode" --session-id "$CHILD" 2>&1)
assert_contains "re-run dedupes the spawned event" "not appending a duplicate" "$out"
assert_eq "still exactly one new spawned event" "1" \
    "$(find "$PEV" -name '*-spawned.md' ! -name '0030-*' | wc -l | tr -d ' ')"

# --- 2. completion event: epoch-named, enriched mechanical body -----------

# Give the child a slot (written by step 1) and a task-folder report.
mkdir -p "$FH/vault/20-surface/company/tasks/T-99"
printf 'the report\n' > "$FH/vault/20-surface/company/tasks/T-99/report.md"

out=$(HOME="$FH" bash "$UPDATE_SH" --mode-file "$FH/wt/.cc-mode" --session-id "$CHILD" 2>&1)
assert_eq "slot update exits 0" 0 $?
assert_contains "slot completed" "tree slot updated" "$out"
co=$(find "$PEV" -name '*-completion.md' ! -name '1788466246-*' | head -1)
assert_eq "a new completion event exists" "yes" "$( [ -n "$co" ] && [ -f "$co" ] && echo yes || echo no )"
lead=$(basename "$co"); lead=${lead%%-*}
if [ "$lead" -ge "$before" ]; then
    t_pass "completion event epoch-named ($lead)"
else
    t_fail "completion event epoch-named" "got $lead"
fi
assert_contains "mechanical completion names the slot" "slot: $TREE/${CHILD}.md" "$(cat "$co")"
assert_contains "mechanical completion names the report AND its size" \
    "tasks/T-99/report.md (11 bytes)" "$(cat "$co")"

# Dedupe: closing again must not double-report.
out=$(HOME="$FH" bash "$UPDATE_SH" --mode-file "$FH/wt/.cc-mode" --session-id "$CHILD" 2>&1)
assert_contains "re-close dedupes the completion event" "not appending a duplicate" "$out"

# --- 3. a child-authored rich completion suppresses the mechanical notice --

mk_home || exit 1
HOME="$FH" bash "$WRITE_SH" --mode-file "$FH/wt/.cc-mode" --session-id "$CHILD" >/dev/null 2>&1
# The child emits its own completion per the dispatch-brief protocol,
# stamped with its own session id by cc-event-emit.sh.
bash "$MODULE_DIR/canonical/shell/cc-event-emit.sh" --dir "$PEV" --session-id "$CHILD" \
    --verb completion --title "T-99 done" \
    --body $'outcome: shipped\nEA action: none\nreport: ~/vault/.../report.md' >/dev/null
out=$(HOME="$FH" bash "$UPDATE_SH" --mode-file "$FH/wt/.cc-mode" --session-id "$CHILD" 2>&1)
assert_contains "rich child completion suppresses the mechanical notice" \
    "not appending a duplicate" "$out"
assert_eq "exactly one completion for this child" "1" \
    "$(grep -l "^session_id: $CHILD" "$PEV"/*-completion.md 2>/dev/null | wc -l | tr -d ' ')"

# --- 4. missing report: the mechanical notice says so, loudly -------------

mk_home || exit 1
HOME="$FH" bash "$WRITE_SH" --mode-file "$FH/wt/.cc-mode" --session-id "$CHILD" >/dev/null 2>&1
HOME="$FH" bash "$UPDATE_SH" --mode-file "$FH/wt/.cc-mode" --session-id "$CHILD" >/dev/null 2>&1
co=$(grep -l "^session_id: $CHILD" "$PEV"/*-completion.md 2>/dev/null | head -1)
assert_contains "no report: completion flags it" "report: NONE" "$(cat "$co")"

t_finish
