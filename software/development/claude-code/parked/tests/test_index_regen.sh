#!/usr/bin/env bash
# Description: Behavioural tests for cc-index-regen.sh — the generator that rebuilds the five surface-ring _index.md files so archive moves cannot strand notes (INFRA-91).
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, python3, coreutils

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

REGEN_UNDER_TEST="${REGEN_UNDER_TEST:-$MODULE_DIR/canonical/shell/cc-index-regen.sh}"

t_begin "cc-index-regen.sh"

# =========================================================================
# WHY THIS FILE EXISTS
#
# INFRA-91. The five surface-ring indexes were written by hand on 2026-09-03
# and never regenerated. Two ring-maintenance passes then moved 241 notes
# into _archive/ directories, leaving 1,092 dead path links in the indexes
# and 471 notes with no incoming link at all. The fix is a generator that
# rebuilds the indexes from disk, so the property under test is coverage:
# every note file under the five roots gets exactly one link, event files
# get none, and the generator cannot touch anything but its five outputs.
# =========================================================================

# --- fixture helpers ------------------------------------------------------

# mk_vault -- print a fresh fake $HOME holding a small but complete surface
# ring. The generator derives every path from $HOME/vault, so an overridden
# HOME isolates it totally: no test here can read or touch the real vault.
mk_vault() {
    local h c
    h=$(t_tmpdir) || return 1
    c="$h/vault/20-surface/company"
    mkdir -p "$c/tree/sessions/_archive" \
             "$c/tasks/_archive" \
             "$c/_command-center/state/_archive" \
             "$c/_command-center/state/netmon" \
             "$c/_command-center/inbox" \
             "$h/vault/20-surface/claude-memory"
    printf '# company\n' > "$c/_index.md"
    printf '# tree schema\n' > "$c/tree/README.md"
    printf '%s\n' "$h"
}

# mk_slot <home> <live|archive> <session_id> <task_id> <status> [started]
mk_slot() {
    local h="$1" where="$2" sid="$3" tid="$4" st="$5" started="${6:-2026-09-01T10:00:00-04:00}"
    local dir="$h/vault/20-surface/company/tree/sessions"
    [ "$where" = archive ] && dir="$dir/_archive"
    local tline="task_id: $tid"
    [ "$tid" = "-" ] && tline="task_id:"
    cat > "$dir/$sid.md" <<SLOTEOF
---
session_id: $sid
parent_id: 0000000000000000000000
$tline
slug: $tid
mode: branched
status: $st
started_at: $started
ended_at:
---

# Session $sid
SLOTEOF
}

# mk_events <home> <live|archive> <session_id> <n> -- an .events/ dir with
# n event notes and the .read-up-to marker the bookends leave behind.
mk_events() {
    local h="$1" where="$2" sid="$3" n="$4" i
    local dir="$h/vault/20-surface/company/tree/sessions"
    [ "$where" = archive ] && dir="$dir/_archive"
    mkdir -p "$dir/$sid.events"
    for ((i = 1; i <= n; i++)); do
        printf -- '---\nverb: status\n---\n\nevent %d\n' "$i" > "$dir/$sid.events/17896000$i-status.md"
    done
    printf '0\n' > "$dir/$sid.events/.read-up-to"
}

# mk_note <home> <vault-relative path under company/> [title]
mk_note() {
    local h="$1" rel="$2" title="${3:-}"
    local p="$h/vault/20-surface/company/$rel"
    mkdir -p "$(dirname "$p")"
    if [ -n "$title" ]; then
        printf -- '---\ntitle: %s\n---\n\nbody\n' "$title" > "$p"
    else
        printf '# heading of %s\n\nbody\n' "$(basename "$rel" .md)" > "$p"
    fi
}

# populate <home> -- the standard fixture every section shares.
populate() {
    local h="$1"
    # live slots: two on one task, one with events; one with no task_id
    mk_slot "$h" live aaaa000000000000000001 INFRA-1 running
    mk_slot "$h" live aaaa000000000000000002 INFRA-1 completed
    mk_slot "$h" live aaaa000000000000000003 - abandoned
    mk_events "$h" live aaaa000000000000000001 3
    # archived slots, one with events
    mk_slot "$h" archive bbbb000000000000000001 SENT-2 completed 2026-08-01T09:00:00-04:00
    mk_slot "$h" archive bbbb000000000000000002 INFRA-1 abandoned 2026-08-02T09:00:00-04:00
    mk_events "$h" archive bbbb000000000000000001 2
    # live task folders: nested notes, a basename collision on report.md,
    # and a non-markdown file that must not be linked
    mk_note "$h" tasks/INFRA-1/brief.md
    mk_note "$h" tasks/INFRA-1/report.md "INFRA-1 report"
    mk_note "$h" tasks/INFRA-1/staged/commands.md
    mk_note "$h" tasks/adhoc/report.md "adhoc report"
    printf 'not a note\n' > "$h/vault/20-surface/company/tasks/INFRA-1/scan.txt"
    # archived task folders, including a nested .events/ fixture like the
    # real tree-slot-fixes archive carries
    mk_note "$h" tasks/_archive/SENT-2/brief.md
    mk_note "$h" tasks/_archive/SENT-2/report.md "SENT-2 report"
    mk_note "$h" tasks/_archive/old-slug/notes.md
    mkdir -p "$h/vault/20-surface/company/tasks/_archive/old-slug/fixture/x.events"
    printf 'fixture event\n' > "$h/vault/20-surface/company/tasks/_archive/old-slug/fixture/x.events/1-spawned.md"
    # command-center: root, state/, state/_archive/, netmon/
    mk_note "$h" _command-center/CLAUDE.md
    mk_note "$h" _command-center/state/promotion-queue.md
    mk_note "$h" _command-center/state/ring-health-2026-09-16.md
    mk_note "$h" _command-center/state/_archive/old-brief.md
    mk_note "$h" _command-center/state/netmon/README.md
    printf '#!/bin/sh\n' > "$h/vault/20-surface/company/_command-center/state/watch.sh"
    # a memory file: outside the five roots, must never be linked
    printf -- '---\ndescription: x\n---\nmem\n' > "$h/vault/20-surface/claude-memory/ref_x.md"
}

# all_index_text <home> -- the five outputs concatenated (missing ones empty).
all_index_text() {
    local c="$1/vault/20-surface/company"
    cat "$c/tree/_index.md" "$c/tree/sessions/_archive/_index.md" \
        "$c/tasks/_index.md" "$c/tasks/_archive/_index.md" \
        "$c/_command-center/_index.md" 2>/dev/null
}

# link_count <text> <vault-relative stem> -- how many wikilinks target the
# stem by its full vault-relative path (with or without an alias).
link_count() {
    printf '%s\n' "$1" | grep -oF "[[$2" | grep -c . || true
}

# snapshot <home> -- sha256 of every file under the fake HOME, sorted, so a
# before/after diff shows exactly which paths a run touched.
snapshot() {
    (cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum)
}

# =========================================================================
# 1. REFUSES AN UNMOUNTED VAULT
# =========================================================================

NOV=$(t_tmpdir) || exit 1
t_run env HOME="$NOV" bash "$REGEN_UNDER_TEST"
assert_eq "unmounted vault: exits 2" "2" "$T_RC"
assert_contains "unmounted vault: says so on stderr" "not mounted" "$T_ERR"
assert_eq "unmounted vault: creates nothing" "" "$(find "$NOV" -type f)"

t_run env HOME="$NOV" bash "$REGEN_UNDER_TEST" --dry-run
assert_eq "unmounted vault: --dry-run also exits 2" "2" "$T_RC"

# =========================================================================
# 2. DRY RUN WRITES NOTHING
# =========================================================================

DH=$(mk_vault) || exit 1
populate "$DH"
before=$(snapshot "$DH")
t_run env HOME="$DH" bash "$REGEN_UNDER_TEST" --dry-run
assert_eq "dry-run: exits 0" "0" "$T_RC"
assert_eq "dry-run: no file under HOME changed or appeared" "$before" "$(snapshot "$DH")"
assert_contains "dry-run: names each index it would write" "tasks/_index.md" "$T_OUT"
assert_contains "dry-run: says it would write, not that it wrote" "would" "$T_OUT"

# =========================================================================
# 3. COVERAGE: EVERY NOTE GETS EXACTLY ONE LINK, EVENT FILES GET NONE
# =========================================================================

GH=$(mk_vault) || exit 1
populate "$GH"
before=$(snapshot "$GH")
t_run env HOME="$GH" bash "$REGEN_UNDER_TEST"
assert_eq "real run: exits 0" "0" "$T_RC"
C="$GH/vault/20-surface/company"
for idx in tree/_index.md tree/sessions/_archive/_index.md tasks/_index.md tasks/_archive/_index.md _command-center/_index.md; do
    [ -f "$C/$idx" ] && t_pass "real run: wrote $idx" || t_fail "real run: wrote $idx" "missing: $C/$idx"
done
ALL=$(all_index_text "$GH")

# Every note file under the five roots, excluding .events/ dirs and the five
# index files themselves, computed from disk so the list cannot drift from
# the fixture.
mapfile -t NOTES < <(cd "$GH/vault" && find 20-surface/company/tree 20-surface/company/tasks 20-surface/company/_command-center \
    -type f -name '*.md' -not -path '*.events/*' -not -name '_index.md' | sort)
assert_ne "fixture holds notes to cover" "0" "${#NOTES[@]}"
for n in "${NOTES[@]}"; do
    stem="${n%.md}"
    assert_eq "exactly one link to $stem" "1" "$(link_count "$ALL" "$stem")"
done

mapfile -t EVENTS < <(cd "$GH/vault" && find 20-surface/company -type f -path '*.events/*' | sort)
assert_ne "fixture holds event files to skip" "0" "${#EVENTS[@]}"
for e in "${EVENTS[@]}"; do
    assert_eq "event file not linked: $e" "0" "$(link_count "$ALL" "${e%.md}")"
done
assert_not_contains "no .events/ path appears anywhere in the indexes" ".events/" "$ALL"
assert_not_contains "non-markdown files are not linked" "scan.txt" "$ALL"
assert_not_contains "shell scripts under state/ are not linked" "watch.sh" "$ALL"
assert_not_contains "memory files are outside scope" "claude-memory" "$ALL"

# Path-bearing links: both report.md files resolve to their own folder.
assert_eq "basename collision: INFRA-1/report linked by path" "1" "$(link_count "$ALL" 20-surface/company/tasks/INFRA-1/report)"
assert_eq "basename collision: adhoc/report linked by path" "1" "$(link_count "$ALL" 20-surface/company/tasks/adhoc/report)"
assert_eq "no bare [[report]] link is emitted" "0" "$(printf '%s\n' "$ALL" | grep -c '\[\[report[]|]' || true)"

# Grouping by task_id.
assert_contains "tree index groups slots under their task_id" "INFRA-1" "$(cat "$C/tree/_index.md")"
assert_contains "tree index has a group for slots with no task_id" "no task_id" "$(cat "$C/tree/_index.md")"
assert_contains "archive tree index groups by task_id" "SENT-2" "$(cat "$C/tree/sessions/_archive/_index.md")"

# =========================================================================
# 4. FRONTMATTER AND WRITE BOUNDARY
# =========================================================================

today=$(date +%F)
for idx in tree/_index.md tree/sessions/_archive/_index.md tasks/_index.md tasks/_archive/_index.md _command-center/_index.md; do
    fm=$(sed -n '2,/^---$/p' "$C/$idx")
    assert_contains "$idx: type: index" "type: index" "$fm"
    assert_contains "$idx: generated_by names this script" "generated_by: cc-index-regen.sh" "$fm"
    assert_contains "$idx: generated is today" "generated: $today" "$fm"
    assert_contains "$idx: has a title" "title:" "$fm"
done

# The only paths that changed under HOME are the five indexes.
after=$(snapshot "$GH")
changed=$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed -n 's/^> [0-9a-f]*  \.\///p' | sort)
expected=$(printf '%s\n' \
    vault/20-surface/company/_command-center/_index.md \
    vault/20-surface/company/tasks/_archive/_index.md \
    vault/20-surface/company/tasks/_index.md \
    vault/20-surface/company/tree/_index.md \
    vault/20-surface/company/tree/sessions/_archive/_index.md | sort)
assert_eq "real run: the five indexes are the only paths written" "$expected" "$changed"

# =========================================================================
# 5. IDEMPOTENCE
# =========================================================================

t_run env HOME="$GH" bash "$REGEN_UNDER_TEST"
assert_eq "second run: exits 0" "0" "$T_RC"
assert_eq "second run: byte-identical output, nothing rewritten" "$after" "$(snapshot "$GH")"
assert_contains "second run: reports the indexes as unchanged" "unchanged" "$T_OUT"

# A stale generated: date is NOT refreshed when the content did not change;
# the date is "when the listing last changed", not "when the script last ran".
sed -i 's/^generated: .*/generated: 2000-01-01/' "$C/tasks/_index.md"
t_run env HOME="$GH" bash "$REGEN_UNDER_TEST"
assert_eq "stable stamp: unchanged content keeps its old generated date" "generated: 2000-01-01" "$(grep '^generated:' "$C/tasks/_index.md")"

# A new note changes the listing, so that index — and only that index — is
# rewritten, with a fresh stamp.
mk_note "$GH" tasks/adhoc/second.md
t_run env HOME="$GH" bash "$REGEN_UNDER_TEST"
assert_eq "new note: the affected index is restamped" "generated: $today" "$(grep '^generated:' "$C/tasks/_index.md")"
assert_eq "new note: it gains exactly one link" "1" "$(link_count "$(all_index_text "$GH")" 20-surface/company/tasks/adhoc/second)"
assert_contains "new note: run output says which index changed" "tasks/_index.md" "$T_OUT"

# =========================================================================
# 6. A MISSING ARCHIVE DIRECTORY IS SKIPPED, NOT CREATED
# =========================================================================

FH=$(mk_vault) || exit 1
populate "$FH"
rm -rf "$FH/vault/20-surface/company/tasks/_archive"
t_run env HOME="$FH" bash "$REGEN_UNDER_TEST"
assert_eq "absent tasks/_archive: exits 0" "0" "$T_RC"
[ -d "$FH/vault/20-surface/company/tasks/_archive" ] \
    && t_fail "absent tasks/_archive: not created by the generator" "directory appeared" \
    || t_pass "absent tasks/_archive: not created by the generator"
assert_contains "absent tasks/_archive: the skip is reported" "skip" "$T_OUT"

# =========================================================================
# 7. --measure IS READ-ONLY AND COUNTS DISCONNECTED NOTES
# =========================================================================

MH=$(mk_vault) || exit 1
populate "$MH"
before=$(snapshot "$MH")
t_run env HOME="$MH" bash "$REGEN_UNDER_TEST" --measure
assert_eq "measure: exits 0" "0" "$T_RC"
assert_eq "measure: writes nothing" "$before" "$(snapshot "$MH")"
assert_contains "measure: reports a disconnected count" "disconnected=" "$T_OUT"
pre=$(printf '%s\n' "$T_OUT" | sed -n 's/.*disconnected=\([0-9]*\).*/\1/p' | head -1)
assert_ne "measure: before regeneration, notes are disconnected" "0" "$pre"
t_run env HOME="$MH" bash "$REGEN_UNDER_TEST"
t_run env HOME="$MH" bash "$REGEN_UNDER_TEST" --measure --list
post=$(printf '%s\n' "$T_OUT" | grep -cE '^ +20-surface/company/(tree|tasks|_command-center)/' || true)
assert_eq "measure: after regeneration, no note under the five roots is disconnected" "0" "$post"
assert_contains "measure --list: the out-of-scope memory file is still reported" "claude-memory/ref_x" "$T_OUT"

t_finish
