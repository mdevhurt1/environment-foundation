#!/usr/bin/env bash
# Description: Behavioural tests for cc-ring-scan.sh — the ring-maintenance surveyor whose AUTO tier writes the session-injected memory index.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, gawk, python3, coreutils

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

SCAN_UNDER_TEST="${SCAN_UNDER_TEST:-$MODULE_DIR/canonical/shell/cc-ring-scan.sh}"
REGEN_UNDER_TEST="${REGEN_UNDER_TEST:-$MODULE_DIR/canonical/shell/cc-memory-index-regen.sh}"

t_begin "cc-ring-scan.sh"

# =========================================================================
# WHY THIS FILE EXISTS
#
# INFRA-78. The ring-maintenance pass of 2026-09-04 came one confirmation
# away from corrupting MEMORY.md. Remit 1 of the skill is AUTO -- applied
# without asking -- and the scanner proposed adding all 471 memory files to
# an index that already contained all 471, because it tested "stem.md"
# against an index that had been compacted to extensionless [[stem]] links
# under AI_ST-69. It was caught only because the metrics contradicted
# themselves.
#
# Until this file existed the script had NO behavioural coverage at all:
# test_configure.sh checked that its symlink was created and nothing more.
# Three separate checks in it were structurally incapable of returning a
# non-zero count, so three "clean" metrics were false cleans.
#
# The load-bearing test here is the fail-closed guard. It does not encode
# the 2026-09-04 format drift; it encodes the SHAPE of that class of bug --
# metrics that cannot simultaneously be true -- so it still fires for the
# NEXT format change, which by definition nobody has thought of yet.
# =========================================================================

# --- fixture helpers ------------------------------------------------------

# mk_vault -- print a fresh fake $HOME holding an empty but complete surface
# ring. The scanner derives every path from $HOME/vault, so an overridden
# HOME isolates it totally: no test here can read or touch the real vault.
mk_vault() {
    local h
    h=$(t_tmpdir) || return 1
    mkdir -p "$h/vault/20-surface/claude-memory" \
             "$h/vault/20-surface/company/tree/sessions" \
             "$h/vault/20-surface/company/tasks" \
             "$h/vault/20-surface/company/_command-center/state" \
             "$h/vault/00-core" "$h/vault/10-middle" "$h/vault/40-journal"
    printf '%s\n' "$h"
}

# mk_mem <home> <stem> <description> [body]
mk_mem() {
    local h="$1" stem="$2" desc="$3" body="${4:-body text}"
    cat > "$h/vault/20-surface/claude-memory/$stem.md" <<MEMEOF
---
name: $stem
description: $desc
metadata:
  type: reference
---

$body
MEMEOF
}

# mk_index <home> <stem>... -- write MEMORY.md in the CURRENT compacted
# format (the shape cc-memory-index-regen.sh emits).
mk_index() {
    local h="$1"; shift
    local out="$h/vault/20-surface/claude-memory/MEMORY.md" s
    printf '# Project Memory Index\n\n' > "$out"
    for s in "$@"; do printf -- '- [[%s]] — hook for %s\n' "$s" "$s" >> "$out"; done
}

# metric <output> <key>
metric() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

# section <output> <name> -- the rows under a "## name" heading.
section() {
    printf '%s\n' "$1" | awk -v s="## $2" '$0==s {f=1; next} /^## / {f=0} f'
}

# =========================================================================
# 1. THE FAIL-CLOSED GUARD  (INFRA-78, the item that matters most)
#
# missing > 0 && missing == files && indexed == files says every memory file
# is BOTH absent from the index and counted in it. No real index is in that
# state; it is the signature of the scanner and the index disagreeing about
# format. The scanner must abort loudly rather than emit an AUTO action.
#
# The fixture reaches the state honestly -- three files, and an index of
# three well-formed entries that happen to name three OTHER stems -- so the
# guard is proved by the metrics themselves, not by a test-only backdoor.
# =========================================================================

GH=$(mk_vault) || exit 1
mk_mem "$GH" alpha "first memory"
mk_mem "$GH" beta  "second memory"
mk_mem "$GH" gamma "third memory"
mk_index "$GH" xray yankee zulu

t_run env HOME="$GH" bash "$SCAN_UNDER_TEST"
guard_out="$T_OUT"; guard_err="$T_ERR"; guard_rc="$T_RC"

assert_ne "impossible metrics abort rather than exit 0" "0" "$guard_rc"
assert_eq "impossible metrics abort with the dedicated status 3" "3" "$guard_rc"
assert_contains "the abort is loud on stderr" "FAIL" "$guard_err"
assert_contains "the abort names the self-consistency check" "self-consistency" "$guard_err"
assert_contains "the abort shows the contradicting counts" "memory.missing=3" "$guard_err"
assert_contains "the abort points at the format authority" \
    "cc-memory-index-regen.sh" "$guard_err"
assert_not_contains "no auto.index_add section is emitted when the guard fires" \
    "auto.index_add" "$guard_out"
assert_not_contains "no index row reaches stdout when the guard fires" \
    "[[alpha]]" "$guard_out"

# The guard must fire BEFORE the expensive dead-link phase, so a scanner in
# this state fails in a second rather than after a 46-minute survey.
assert_not_contains "the guard aborts before the dead-link phase runs" \
    "links.unresolved" "$guard_out"

# A one-file vault where that one file is genuinely unindexed is the honest
# case with the same arithmetic shape ONLY if indexed == files; with an
# empty index indexed=0, so the guard must NOT fire and the row must emit.
SH=$(mk_vault) || exit 1
mk_mem "$SH" solo "the only memory"
printf '# Project Memory Index\n\n' > "$SH/vault/20-surface/claude-memory/MEMORY.md"
t_run env HOME="$SH" bash "$SCAN_UNDER_TEST"
assert_eq "a genuinely empty index is not an impossible state" "0" "$T_RC"
assert_eq "  ... and reports the one file missing" "1" "$(metric "$T_OUT" memory.missing)"
assert_eq "  ... with indexed=0, which is what makes it possible" \
    "0" "$(metric "$T_OUT" memory.indexed)"

# =========================================================================
# 2. THE COMPACTED FORMAT IS READ CORRECTLY  (INFRA-78 items 2 and 4)
# =========================================================================

CH=$(mk_vault) || exit 1
mk_mem "$CH" alpha "first memory"
mk_mem "$CH" beta  "second memory"
mk_mem "$CH" gamma "third memory"
mk_index "$CH" alpha beta gamma

t_run env HOME="$CH" bash "$SCAN_UNDER_TEST"
assert_eq "a compacted-format index exits 0" "0" "$T_RC"
assert_eq "a compacted-format index reports 0 missing" \
    "0" "$(metric "$T_OUT" memory.missing)"
assert_eq "  ... counts every file" "3" "$(metric "$T_OUT" memory.files)"
assert_eq "  ... counts every index entry" "3" "$(metric "$T_OUT" memory.indexed)"
assert_eq "  ... and proposes no AUTO additions" "" "$(section "$T_OUT" auto.index_add | tr -d '\n')"

# Reconciliation with the format authority, end to end: an index BUILT by
# cc-memory-index-regen.sh must read back as fully in sync. This is the
# assertion that would have failed on 2026-09-04, and it cannot drift out of
# date, because it regenerates rather than hard-coding the format.
RH=$(mk_vault) || exit 1
mk_mem "$RH" alpha "first memory"
mk_mem "$RH" beta  "second memory"
mk_mem "$RH" gamma "a description long enough that the generator must cut it at a clause boundary; this trailing part is dropped"
bash "$REGEN_UNDER_TEST" "$RH/vault/20-surface/claude-memory" >/dev/null 2>&1
t_run env HOME="$RH" bash "$SCAN_UNDER_TEST"
assert_eq "an index written by cc-memory-index-regen.sh reports 0 missing" \
    "0" "$(metric "$T_OUT" memory.missing)"
assert_eq "  ... and 0 dead" "0" "$(metric "$T_OUT" memory.dead)"
# The generator writes a header comment that documents the format with a
# literal "[[name]] — hook" example. A whole-file scrape for [[...]] adopts
# `name` as an index entry and then proposes deleting it, so entries are read
# from "- [[...]]" lines only.
assert_not_contains "the index's own format example is not read as an entry" \
    "name" "$(section "$T_OUT" auto.index_drop)"

# Hook parity: the row the scanner proposes for an unindexed file must be
# byte-identical to the line the generator would write for it. This is the
# assertion that keeps "current compacted format" from drifting into "some
# format with double brackets in it" -- it compares against the authority's
# real output rather than against a hard-coded expectation.
PH=$(mk_vault) || exit 1
LONGDESC="a description well past seventy-two characters; the generator cuts it at a clause boundary and drops the rest"
mk_mem "$PH" alpha "first memory"
mk_mem "$PH" gamma "$LONGDESC"
mk_index "$PH" alpha                      # gamma unindexed -> scanner proposes it
t_run env HOME="$PH" bash "$SCAN_UNDER_TEST"
scanner_row=$(section "$T_OUT" auto.index_add | grep 'gamma' || true)
bash "$REGEN_UNDER_TEST" "$PH/vault/20-surface/claude-memory" >/dev/null 2>&1
regen_row=$(grep 'gamma' "$PH/vault/20-surface/claude-memory/MEMORY.md" || true)
assert_ne "the generator produced a gamma line to compare against" "" "$regen_row"
assert_eq "the proposed row is byte-identical to the generator's line" \
    "$regen_row" "$scanner_row"

# =========================================================================
# 3. A GENUINELY MISSING FILE IS STILL DETECTED, IN THE CURRENT FORMAT
#
# Fixing a false positive is worthless if it silences the true positive too.
# =========================================================================

MH=$(mk_vault) || exit 1
mk_mem "$MH" alpha "first memory"
mk_mem "$MH" beta  "second memory"
mk_mem "$MH" gamma "third memory"
mk_index "$MH" alpha beta          # gamma deliberately absent

t_run env HOME="$MH" bash "$SCAN_UNDER_TEST"
assert_eq "a genuinely unindexed file is reported missing" \
    "1" "$(metric "$T_OUT" memory.missing)"
add_rows=$(section "$T_OUT" auto.index_add)
assert_contains "the missing file is the one named" "gamma" "$add_rows"
assert_not_contains "an indexed file is not named" "alpha" "$add_rows"
# The emitted row must be the line to append, in the compacted format --
# an AUTO fix written in the superseded format would reintroduce the drift
# it is supposed to repair.
assert_contains "the row is emitted as a compacted wiki-link entry" \
    "- [[gamma]] — " "$add_rows"
assert_not_contains "the row carries no .md extension" "gamma.md" "$add_rows"
assert_not_contains "the row is not a markdown link" "](" "$add_rows"

# A file with no description: frontmatter cannot be auto-added -- nothing
# synthesises a description -- so it is reported, not proposed.
ND=$(mk_vault) || exit 1
mk_mem "$ND" alpha "first memory"
printf -- '---\nname: nodesc\n---\n\nno description line\n' \
    > "$ND/vault/20-surface/claude-memory/nodesc.md"
mk_index "$ND" alpha
t_run env HOME="$ND" bash "$SCAN_UNDER_TEST"
assert_eq "a description-less file counts as no_description" \
    "1" "$(metric "$T_OUT" memory.no_description)"
assert_contains "  ... and is reported" "nodesc" "$(section "$T_OUT" report.no_description)"
assert_not_contains "  ... not auto-added" "nodesc" "$(section "$T_OUT" auto.index_add)"

# =========================================================================
# 4. DEAD INDEX ENTRIES  (INFRA-78 item 3)
#
# MEM_DEAD extracted markdown-link "](file.md)" targets from a file that has
# contained none since AI_ST-69, so memory.dead=0 was a false clean: the
# check could not return anything else.
# =========================================================================

DH=$(mk_vault) || exit 1
mk_mem "$DH" alpha "first memory"
mk_mem "$DH" beta  "second memory"
mk_index "$DH" alpha beta ghost    # ghost.md does not exist

t_run env HOME="$DH" bash "$SCAN_UNDER_TEST"
assert_eq "an index entry with no file behind it is dead" \
    "1" "$(metric "$T_OUT" memory.dead)"
assert_contains "the dead entry is named for dropping" \
    "ghost" "$(section "$T_OUT" auto.index_drop)"
assert_not_contains "a live entry is not proposed for dropping" \
    "alpha" "$(section "$T_OUT" auto.index_drop)"

# =========================================================================
# 5. LINK NORMALISATION  (INFRA-77 items 5 and 6)
#
# 2,209 of 2,719 links on the live vault were falsely unresolved because the
# link text was looked up verbatim -- alias, anchor, path and all -- against
# a set of bare basenames.
# =========================================================================

LH=$(mk_vault) || exit 1
mk_mem "$LH" alpha "first memory"
mk_mem "$LH" beta  "second memory"
mk_index "$LH" alpha beta
cat > "$LH/vault/20-surface/links.md" <<'LINKEOF'
plain             [[alpha]]
aliased           [[alpha|call it alpha]]
path-bearing      [[20-surface/claude-memory/beta]]
path and alias    [[20-surface/claude-memory/beta|beta]]
anchored          [[alpha#some heading]]
block ref         [[beta^blockid]]
with extension    [[alpha.md]]
escaped bracket   [[MEMORY\]]
escaped pipe      [[20-surface/claude-memory/alpha\|`alpha`]]
escaped pipe deep [[20-surface/claude-memory/beta\|beta]]
LINKEOF

t_run env HOME="$LH" bash "$SCAN_UNDER_TEST"
assert_eq "every normalisable link form resolves" \
    "0" "$(metric "$T_OUT" links.unresolved)"
dead_rows=$(section "$T_OUT" report.dead_links)
assert_eq "  ... so no dead links are reported" "" "$(printf '%s' "$dead_rows" | tr -d '\n')"
assert_not_contains "an alias never reaches the lookup" "call it alpha" "$dead_rows"
assert_not_contains "a path never reaches the lookup" "20-surface/" "$dead_rows"
assert_not_contains "an escaped bracket does not survive as a backslash" \
    'MEMORY\' "$dead_rows"
# The vault's _index.md files write [[path/note\|`display`]] -- an ESCAPED
# PIPE. The backslash only becomes trailing once the alias has been split off,
# so a strip that runs before the split misses it entirely.
assert_not_contains "an escaped pipe does not leave a trailing backslash" \
    'alpha\' "$dead_rows"

# =========================================================================
# 6. A REAL NEAR-MISS IS STILL REPORTED
#
# The contract: an unresolved [[link]] is a deliberate future-memory marker,
# NOT an error. Only near-misses are typos. Normalisation must not swallow
# the typo it exists to surface.
# =========================================================================

NH=$(mk_vault) || exit 1
mk_mem "$NH" alpha "first memory"
mk_index "$NH" alpha
printf 'a typo: [[alphb]]\n' > "$NH/vault/20-surface/typo.md"

t_run env HOME="$NH" bash "$SCAN_UNDER_TEST"
assert_eq "the typo is counted unresolved" "1" "$(metric "$T_OUT" links.unresolved)"
near=$(section "$T_OUT" report.dead_links)
assert_contains "the typo is reported" "alphb" "$near"
assert_contains "  ... with the note it probably meant" "alpha" "$near"

# A distant link is unresolved but NOT reported: it is a future-memory
# marker, and reporting it would make the section noise.
FH=$(mk_vault) || exit 1
mk_mem "$FH" alpha "first memory"
mk_index "$FH" alpha
printf 'a deliberate marker: [[something-entirely-different]]\n' \
    > "$FH/vault/20-surface/marker.md"
t_run env HOME="$FH" bash "$SCAN_UNDER_TEST"
assert_eq "a distant link is counted unresolved" "1" "$(metric "$T_OUT" links.unresolved)"
assert_not_contains "  ... but is not reported as a typo" \
    "something-entirely-different" "$(section "$T_OUT" report.dead_links)"

# =========================================================================
# 7. ORPHAN DETECTION  (the THIRD defect of the same class)
#
# The orphan check grepped "[[stem]]" recursively across $MEM -- but
# MEMORY.md LIVES in $MEM and carries [[stem]] for every indexed file, so
# every indexed memory looked linked and report.orphans was structurally
# always empty. It also could not see the 102 aliased or path-bearing links
# that the live memory corpus actually uses.
# =========================================================================

OH=$(mk_vault) || exit 1
mk_mem "$OH" hub    "the linker" "see [[20-surface/claude-memory/target|target]] for more"
mk_mem "$OH" target "the linked" "no outbound links here"
mk_mem "$OH" lonely "the lonely" "nothing links to me"
mk_index "$OH" hub target lonely

t_run env HOME="$OH" bash "$SCAN_UNDER_TEST"
orphans=$(section "$T_OUT" report.orphans)
assert_ne "report.orphans is no longer structurally always empty" "" "$(printf '%s' "$orphans" | tr -d '\n')"
assert_contains "a memory nothing links to is an orphan" "lonely" "$orphans"
assert_not_contains "a memory linked only via an alias+path is NOT an orphan" \
    "target" "$orphans"
# MEMORY.md lists all three, and lives inside $MEM. If the index counted as an
# inbound link -- as it used to -- nothing here could ever be an orphan.
assert_contains "being named in the index does not rescue a file from orphanhood" \
    "hub" "$orphans"

# =========================================================================
# 8. PROGRESS AND SAFETY
# =========================================================================

# Reusing the completed orphan run above: a run that prints nothing for 46
# minutes is indistinguishable from a hang.
assert_contains "the scanner traces its progress on stderr" "ring-scan:" "$T_ERR"
assert_contains "  ... naming the dead-link phase, the slow one" "links" "$T_ERR"
assert_eq "the trace stays off stdout, which is parsed" \
    "" "$(printf '%s\n' "$T_OUT" | grep '^ring-scan:' || true)"

# The read-only property is what makes the scanner safe to run at any time.
RO=$(mk_vault) || exit 1
mk_mem "$RO" alpha "first memory"
mk_index "$RO" alpha
before=$(find "$RO/vault" -type f -printf '%p %s %T@\n' | sort)
t_run env HOME="$RO" bash "$SCAN_UNDER_TEST"
after=$(find "$RO/vault" -type f -printf '%p %s %T@\n' | sort)
assert_eq "the scanner writes nothing to the vault" "$before" "$after"

# Vault absent is a distinct, documented status, not the guard's.
NV=$(t_tmpdir) || exit 1
t_run env HOME="$NV" bash "$SCAN_UNDER_TEST"
assert_eq "a missing vault still exits 2" "2" "$T_RC"
assert_contains "  ... and says so" "vault not mounted" "$T_ERR"

# =========================================================================
# 9. THE EMIT TAIL  (INFRA-88)
#
# The 2026-09-05 pass read as "the emitter drops report.canon_leak and
# ## anomalies". The emitter was innocent: the EA's capture pipeline
# (`scan 2>&1 | tee file | head -100`) truncated the tail — head exited,
# tee died of SIGPIPE, the scanner died of SIGPIPE mid-emit, and head's
# exit 0 hid all of it. These tests pin the two sections' behaviour so the
# "emitter drops them" hypothesis stays refuted, and section 10 covers the
# real defect: a truncated report was indistinguishable from a complete one.
# =========================================================================

# canon leak: a file under a protected ring newer than the last-run marker
# is reported, ring-relative, with its mtime.
CK=$(mk_vault) || exit 1
mk_mem "$CK" alpha "first memory"
mk_index "$CK" alpha
CK_MARKER="$CK/vault/20-surface/company/_command-center/state/.ring-maintenance-last-run"
touch -d '3 days ago' "$CK_MARKER"
printf 'core edit\n'    > "$CK/vault/00-core/core-note.md"
printf 'canon edit\n'   > "$CK/vault/10-middle/canon-note.md"
printf 'journal edit\n' > "$CK/vault/40-journal/journal-note.md"
printf 'old canon\n'    > "$CK/vault/10-middle/untouched-note.md"
touch -d '10 days ago' "$CK/vault/10-middle/untouched-note.md"

t_run env HOME="$CK" bash "$SCAN_UNDER_TEST"
leak_rows=$(section "$T_OUT" report.canon_leak)
assert_contains "a 00-core file newer than the marker is a canon leak" \
    "00-core/core-note.md" "$leak_rows"
assert_contains "a 10-middle file newer than the marker is a canon leak" \
    "10-middle/canon-note.md" "$leak_rows"
assert_contains "a 40-journal file newer than the marker is a canon leak" \
    "40-journal/journal-note.md" "$leak_rows"
assert_contains "  ... each row carries a tab-separated mtime" \
    "$(printf '10-middle/canon-note.md\t')" "$leak_rows"
assert_not_contains "a file older than the marker is not a leak" \
    "untouched-note.md" "$leak_rows"

# anomalies: a missing marker is the documented baseline anomaly, and it must
# actually reach the report — this is the scanner's self-report channel.
AN=$(mk_vault) || exit 1
mk_mem "$AN" alpha "first memory"
mk_index "$AN" alpha
t_run env HOME="$AN" bash "$SCAN_UNDER_TEST"
anom_rows=$(section "$T_OUT" anomalies)
assert_contains "a missing last-run marker is reported in ## anomalies" \
    "no last-run marker" "$anom_rows"

# The terminator. A report is complete IFF its last line is "## end"; without
# it, the 2026-09-05 truncation was undetectable — 11 sections look exactly
# like a scan that had nothing to say in the last two.
assert_eq "a complete report ends with the ## end terminator" \
    "## end" "$(printf '%s\n' "$T_OUT" | tail -1)"
assert_eq "  ... and carries all 13 sections plus the terminator" \
    "14" "$(printf '%s\n' "$T_OUT" | grep -c '^## ')"

# =========================================================================
# 10. TRUNCATION IS DETECTABLE AND SIGPIPE IS LOUD  (INFRA-88)
# =========================================================================

# The incident invocation, verbatim shape: the tee'd "full copy" is NOT a
# full copy once a downstream head exits. The saved file must be detectably
# incomplete — no terminator — rather than a plausible-looking report.
TH=$(mk_vault) || exit 1
mk_mem "$TH" alpha "first memory"
mk_index "$TH" alpha
env HOME="$TH" bash -c 'bash "$0" 2>&1 | tee "$1" | head -3 >/dev/null' \
    "$SCAN_UNDER_TEST" "$TH/saved.txt"
saved=$(cat "$TH/saved.txt" 2>/dev/null || true)
assert_not_contains "a head-truncated capture lacks the terminator" \
    "## end" "$saved"
assert_not_contains "  ... so the missing canon-leak section is detectable" \
    "## report.canon_leak" "$saved"

# A consumer that vanishes must produce a LOUD death with a dedicated status,
# not the default silent 141. stderr is kept separate here, as a correct
# invocation would keep it.
SD=$(mk_vault) || exit 1
mk_mem "$SD" alpha "first memory"
mk_index "$SD" alpha
sig_rc=$(env HOME="$SD" bash -c 'bash "$0" 2>"$1" | :; echo "${PIPESTATUS[0]}"' \
    "$SCAN_UNDER_TEST" "$SD/err.txt")
assert_eq "a scan whose consumer vanished exits with the dedicated status 4" \
    "4" "$sig_rc"
assert_contains "  ... and says TRUNCATED on stderr" \
    "TRUNCATED" "$(cat "$SD/err.txt" 2>/dev/null || true)"

# =========================================================================
# 11. WALKED PROMOTION SECTIONS ARE NOT RE-PROPOSED  (AI_ST-94)
#
# The 2026-09-04 pass re-queued six already-walked marker candidates — two
# of which were re-drafted into canon, silently reversing rulings an earlier
# walk had made — because nothing marks a source section as processed. The
# fix: Phase 2 stamps walked headings `## Promotion candidates
# [WALKED YYYY-MM-DD]`, and the marker grep skips stamped lines.
# =========================================================================

WK=$(mk_vault) || exit 1
mk_mem "$WK" alpha "first memory"
mk_mem "$WK" walked_mem "memory with a walked section" \
    $'## Promotion candidates [WALKED 2026-08-20]\n- already dispositioned'
mk_index "$WK" alpha walked_mem
WK_TASKS="$WK/vault/20-surface/company/tasks"
mkdir -p "$WK_TASKS/demo"
printf '## Promotion candidates\n- an unwalked candidate\n' \
    > "$WK_TASKS/demo/fresh-notes.md"
printf '## Promotion candidates [WALKED 2026-09-04]\n- a walked candidate\n' \
    > "$WK_TASKS/demo/walked-notes.md"

t_run env HOME="$WK" bash "$SCAN_UNDER_TEST"
marker_rows=$(section "$T_OUT" propose.markers)
assert_contains "an unstamped promotion section is still proposed" \
    "fresh-notes.md" "$marker_rows"
assert_not_contains "a [WALKED]-stamped task section is not re-proposed" \
    "walked-notes.md" "$marker_rows"
assert_not_contains "a [WALKED]-stamped memory section is not re-proposed" \
    "walked_mem" "$marker_rows"

# =========================================================================
# 12. THE MARKER GREP SKIPS ITS OWN EXHAUST  (AI_ST-94)
#
# Of 37 marker rows on the 2026-09-02 pass, ~31 were self-referential:
# saved copies of previous scan output, MEMORY.md backups and conflict
# copies, archived task folders. An 84% noise rate is what made the six
# real duplicates invisible.
# =========================================================================

EX=$(mk_vault) || exit 1
mk_mem "$EX" alpha "first memory"
mk_index "$EX" alpha
EX_TASKS="$EX/vault/20-surface/company/tasks"
EX_MEM="$EX/vault/20-surface/claude-memory"
mkdir -p "$EX_TASKS/prep" "$EX_TASKS/_archive/old" \
         "$EX_MEM/obsidian-conflicts" "$EX_MEM/memory-loop"
printf '## Promotion candidates\n- real\n'            > "$EX_TASKS/prep/real.md"
printf '## Promotion candidates\n- prior scan copy\n' > "$EX_TASKS/prep/scan-output.txt"
printf '## Promotion candidates\n- backup\n'          > "$EX_TASKS/prep/session.md.bak"
printf '## Promotion candidates\n- archived\n'        > "$EX_TASKS/_archive/old/session.md"
printf 'hook mentioning promotion candidates\n'       > "$EX_MEM/obsidian-conflicts/MEMORY-conflict.md"
printf 'hook mentioning promotion candidates\n'       > "$EX_MEM/memory-loop/MEMORY-backup.md"

t_run env HOME="$EX" bash "$SCAN_UNDER_TEST"
exhaust_rows=$(section "$T_OUT" propose.markers)
assert_contains "a live task file's marker is still proposed" \
    "real.md" "$exhaust_rows"
assert_not_contains "a saved scan-output copy is exhaust, not a candidate" \
    "scan-output.txt" "$exhaust_rows"
assert_not_contains "a .bak file is exhaust, not a candidate" \
    ".bak" "$exhaust_rows"
assert_not_contains "an _archive/ hit is exhaust, not a candidate" \
    "_archive" "$exhaust_rows"
assert_not_contains "a preserved conflict copy of the index is exhaust" \
    "obsidian-conflicts" "$exhaust_rows"
assert_not_contains "a memory-loop backup of the index is exhaust" \
    "memory-loop" "$exhaust_rows"

t_finish
