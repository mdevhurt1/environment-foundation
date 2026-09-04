#!/usr/bin/env bash
# Description: Behavioral tests for cc-scrub-outbound.sh - the outbound-text arm: register/typography rules the CEO ruling made blocking for drafts, the bare 22-hex session id cc-scrub's session_ rule cannot see, the delegated F1 class, outbound package completeness, and the calibration that refuses to report CLEAN unproven.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, git, grep with -P (PCRE), file, coreutils

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

SUBJECT="$MODULE_DIR/canonical/scripts/cc-scrub-outbound.sh"
F1="$MODULE_DIR/canonical/scripts/cc-scrub.sh"

t_begin "cc-scrub-outbound: outbound-text arm (register + delegated F1)"

# =========================================================================
# WHY THIS FILE EXISTS (Plane INFRA-62; CEO ruling 2026-09-04)
#
# Scrub surfaces are three, not one. Tracked file content was always
# covered; commit messages were added under RESEARCH-1. The third is
# outbound PR/issue/comment text, and it leaks BOTH classes independently:
#
#   * F1 disclosure -- the LiteLLM draft was swept for this by hand.
#   * AI register   -- it was NOT, and BerriAI/litellm#39724 went out with
#                      em-dashes in it.
#
# Retro-editing a posted text does not remove the fingerprint: the edit
# history stays visible and edit-churn is itself a signal. So the sweep has
# to happen BEFORE the first post, which makes this a pre-flight gate and
# not a report.
#
# WHY A SIBLING TOOL AND NOT A RULE ADDED TO cc-scrub
#
# cc-scrub parks the register class (F3) on an undecided policy question
# and warns that shipping it early "would block 81% of this repo's text
# files on a taste call". Measured on this checkout while writing these
# tests: 86 files in this module alone carry an em-dash. The CEO ruling
# resolves that taste call for OUTBOUND DRAFTS ONLY -- it says nothing
# about repo prose. A separate tool whose corpus is an outbound package
# cannot be pointed at the tracked tree by accident; a mode flag on
# cc-scrub could be, and `cc-scrub --audit` would start failing on this
# repo's own README the day the rules landed there.
#
# The F1 class is therefore DELEGATED to cc-scrub rather than restated:
# section 5 exists to prove the delegation is real, so that the four
# range-checked F1 rules keep living in exactly one file.
# =========================================================================

# --- plants and baits ----------------------------------------------------
#
# ASSEMBLED FROM FRAGMENTS, NEVER WRITTEN OUT -- the same discipline
# test_cc_scrub.sh follows, for the same two reasons: this file is tracked
# in a PUBLIC repo, and section 8 below points the tool at a copy of
# itself. A literal 22-hex session id or a literal assistant trailer here
# would make the test suite a specimen of the class it proves the tool
# catches. No fragment below matches a rule on its own.
#
# The typographic characters are written as \u escapes for the same
# reason: the file must stay free of the literal characters so that the
# self-sweep in section 8 is a real assertion and not a tautology.
EM=$'\u2014'          # em dash
EN=$'\u2013'          # en dash
LDQ=$'\u201C'; RDQ=$'\u201D'   # curly double quotes
RSQ=$'\u2019'                  # curly apostrophe
NBSP=$'\u00A0'        # no-break space
ELL=$'\u2026'         # horizontal ellipsis

SID_A="a1b2c3d4e5f6"; SID_B="0718293a4b"
PLANT_SID="${SID_A}${SID_B}"                     # 22 lowercase hex, the minted shape
BAIT_SHA40="6efe32c9e2dd002d0c394e861e0529675d1ab32e"   # a real git sha: 40, not 22
BAIT_SHA7="6efe32c"
BAIT_UUID32="550e8400e29b41d4a716446655440000"          # a dashless uuid: 32, not 22

COAUTH_KEY="Co-Authored-By"; ASSISTANT="Claude"
PLANT_TRAILER="${COAUTH_KEY}: ${ASSISTANT} <noreply@example.invalid>"
PLANT_SESSION_URL="https://claude.ai/code/${SID_A}${SID_B}"
BAIT_HUMAN_TRAILER="${COAUTH_KEY}: Marcus <someone@example.invalid>"

# F1 fragments, so section 5 can prove the delegate really ran.
Q192="192.168"; SEG_HOME="home"
PLANT_IP="${Q192}.44.44"
PLANT_HOMEPATH="/${SEG_HOME}/plantuser/vault"
BAIT_DECIMALS="tolerance 10.033 mm, span 10.287, ratio 10.0, 10.5, 10.6"

VAULT_OUTBOUND="$HOME/vault/20-surface/company/tasks/litellm-pr-prep/outbound"

# --- helpers -------------------------------------------------------------

# body_with <line>... -- a scratch dir holding one outbound package whose
# body carries the given lines. Returns the dir path.
body_with() {
    local d
    d=$(t_tmpdir) || return 1
    printf 'a title\n' > "$d/sample.title"
    printf 'https://example.invalid/owner/repo/compare/main...fork:repo:branch\n' > "$d/sample.target"
    printf '%s\n' "$@" > "$d/sample.body.md"
    printf '%s\n' "$d"
}

# scan_body <line>... -- run the tool over a package whose body holds those
# lines. Sets T_OUT/T_ERR/T_RC.
scan_body() {
    local d
    d=$(body_with "$@") || return 1
    t_run bash "$SUBJECT" "$d"
}

# =========================================================================
# 1. CALIBRATION -- the instrument proves itself before it sweeps anything
#
# Inherited wholesale from the F1 arm's hardest-won lesson: an
# uncalibrated scrubber is WORSE than no scrubber, because it converts
# "unmeasured" into "verified clean". This arm has a second way to be
# silently useless that cc-scrub does not: its F1 half lives in another
# process, so a delegate that failed to calibrate must not be reported as
# a clean F1 sweep.
# =========================================================================

t_diag "--- calibration ---"

t_run bash "$SUBJECT" --calibrate-only
assert_eq "--calibrate-only exits 0 on a working instrument" 0 "$T_RC"
assert_contains "calibration reports plants caught" "plants caught" "$T_OUT"
assert_contains "calibration passes" "PASS" "$T_OUT"
assert_contains "calibration reports the negative-control sample size" "negative control" "$T_OUT"
assert_not_contains "a passing calibration names no missed plant" "missed plant" "$T_OUT"

CAL_LINE=$(printf '%s\n' "$T_OUT" | grep -m1 'plants caught')
CAL_N=$(printf '%s' "$CAL_LINE" | grep -oP '(?<=^calibration: )[0-9]+(?=/)')
assert_eq "every plant was caught (N/N)" "$CAL_N/$CAL_N" \
    "$(printf '%s' "$CAL_LINE" | grep -oP '[0-9]+/[0-9]+' | head -1)"
if [ -n "${CAL_N:-}" ] && [ "$CAL_N" -ge 5 ]; then
    t_pass "at least one plant per enabled rule (>=5 plants), not a vacuous control"
else
    t_fail "at least one plant per enabled rule (>=5 plants), not a vacuous control" \
           "calibration line: $CAL_LINE"
fi
BAIT_N=$(printf '%s' "$CAL_LINE" | grep -oP '(?<=over )[0-9]+(?= baits)')
if [ -n "${BAIT_N:-}" ] && [ "$BAIT_N" -ge 10 ]; then
    t_pass "negative control carries the documented baits (>=10)"
else
    t_fail "negative control carries the documented baits (>=10)" "calibration line: $CAL_LINE"
fi

# --- calibration has teeth -----------------------------------------------
#
# Break exactly one detector and the tool must refuse to sweep, and must
# name which plant it missed. An assertion that has never been seen to
# fail is decoration; this is the one that keeps the rest honest.

D_MUT=$(t_tmpdir) || exit 1
sed "s|^RE_EMDASH=.*|RE_EMDASH='ZZNEVERMATCHESZZ'|" "$SUBJECT" > "$D_MUT/broken-detector.sh"
assert_ne "mutant differs from the original (the sed anchor still exists)" \
    "$(md5sum < "$SUBJECT")" "$(md5sum < "$D_MUT/broken-detector.sh")"
cp "$F1" "$D_MUT/cc-scrub.sh"
t_run bash "$D_MUT/broken-detector.sh" --calibrate-only
assert_eq "a broken detector fails calibration with exit 2" 2 "$T_RC"
assert_contains "the broken run names the missed plant" "missed plant" "$T_OUT"
assert_contains "the broken run names the rule that missed it" "em-dash" "$T_OUT"
assert_not_contains "a broken instrument never prints PASS" "-- PASS" "$T_OUT"

# An over-broad detector must fail the negative control, not sail through
# it. The bait here is the ASCII hyphen: a rule that treated "-" as a
# typographic tell would fire on every hyphenated word in every draft.
sed "s|^RE_EMDASH=.*|RE_EMDASH='-'|" "$SUBJECT" > "$D_MUT/naive-detector.sh"
t_run bash "$D_MUT/naive-detector.sh" --calibrate-only
assert_eq "an over-broad detector fails the negative control with exit 2" 2 "$T_RC"
assert_contains "the over-broad run names the false positive" "negative control" "$T_OUT"

# --- the DELEGATE must be calibrated too ---------------------------------
#
# The failure this catches: cc-scrub's own calibration fails (a detector
# rots, grep loses -P), it exits 2 having swept nothing, and this tool
# reads an empty finding list as "no F1 problems". That is the false-zero
# shape one process removed. A delegate that could not prove itself makes
# the whole run INCOMPLETE.

D_BADF1=$(t_tmpdir) || exit 1
cp "$SUBJECT" "$D_BADF1/cc-scrub-outbound.sh"
sed "s|^RE_HOMEPATH=.*|RE_HOMEPATH='ZZNEVERMATCHESZZ'|" "$F1" > "$D_BADF1/cc-scrub.sh"
D_CLEAN=$(body_with "an ordinary sentence with nothing wrong in it") || exit 1
t_run bash "$D_BADF1/cc-scrub-outbound.sh" "$D_CLEAN"
assert_eq "a delegate that fails calibration makes the run INCOMPLETE (exit 2)" 2 "$T_RC"
assert_not_contains "...and never prints CLEAN" "VERDICT: CLEAN" "$T_OUT"
assert_contains "...naming the F1 arm as the reason" "F1" "$T_OUT$T_ERR"

# A missing delegate is not a clean F1 sweep either.
D_NOF1=$(t_tmpdir) || exit 1
cp "$SUBJECT" "$D_NOF1/cc-scrub-outbound.sh"
t_run bash "$D_NOF1/cc-scrub-outbound.sh" "$D_CLEAN"
assert_eq "a missing delegate makes the run INCOMPLETE (exit 2)" 2 "$T_RC"
assert_not_contains "...and never prints CLEAN" "VERDICT: CLEAN" "$T_OUT"

# =========================================================================
# 2. RULE: em-dash -- the rule the LiteLLM filing needed
#
# BLOCK tier, and that is the CEO ruling rather than this tool's opinion.
# The correct response to an em-dash in an unposted draft is "stop and
# rewrite the sentence", which is the criterion cc-scrub sets for BLOCK.
# =========================================================================

t_diag "--- rule: em-dash ---"

scan_body "the fix is simple ${EM} it warns once per model"
assert_eq "an em-dash in a body is a finding (exit 1)" 1 "$T_RC"
assert_contains "...reported under rule em-dash" "em-dash" "$T_OUT"
assert_contains "...at BLOCK tier" "BLOCK" "$T_OUT"
assert_contains "...with file:line:col" "sample.body.md:1:" "$T_OUT"

scan_body "a title line" "" "the second paragraph ${EM} here"
assert_contains "...reporting the real line number, not the offset in the file it scanned" \
    "sample.body.md:3:" "$T_OUT"

# The tool sweeps the whole package, not just the body: a title is posted
# text too, and it is the line a reviewer is least likely to re-read.
D_T=$(t_tmpdir) || exit 1
printf 'fix(ollama): warn once %s and only once\n' "$EM" > "$D_T/sample.title"
printf 'nothing wrong here\n' > "$D_T/sample.body.md"
t_run bash "$SUBJECT" "$D_T"
assert_eq "an em-dash in the .title is a finding too" 1 "$T_RC"
assert_contains "...naming the title file" "sample.title:1:" "$T_OUT"

# --- baits: the ASCII forms a draft is SUPPOSED to use -------------------
scan_body "the fix is simple - it warns once, and costs nothing"
assert_eq "an ASCII hyphen is not an em-dash" 0 "$T_RC"
assert_not_contains "...and is not reported at all" "em-dash" "$T_OUT"

scan_body "a range of 10--20 and a flag --staged and a bullet -- like this"
assert_eq "double hyphens and long options are not em-dashes" 0 "$T_RC"

# =========================================================================
# 3. RULE: curly-quote and the quieter typographic tells
# =========================================================================

t_diag "--- rule: curly-quote and typography ---"

scan_body "it returns ${LDQ}content${RDQ} unchanged"
assert_eq "curly double quotes are a finding (exit 1)" 1 "$T_RC"
assert_contains "...reported under rule curly-quote" "curly-quote" "$T_OUT"
assert_contains "...at BLOCK tier" "BLOCK" "$T_OUT"

scan_body "the model${RSQ}s own chat template"
assert_eq "a curly apostrophe is a finding" 1 "$T_RC"
assert_contains "...reported under rule curly-quote" "curly-quote" "$T_OUT"

scan_body 'it returns "content" unchanged and the model'"'"'s template stays'
assert_eq "straight quotes and an ASCII apostrophe are not findings" 0 "$T_RC"
assert_not_contains "...and are not reported at all" "curly-quote" "$T_OUT"

# The quieter tells are ADVISORY: they are invisible in a diff and a
# reviewer should be told, but none of them alone is worth halting a post
# that a human is standing over.
scan_body "the proxy logs${NBSP}now say what happened"
assert_eq "a no-break space does not block" 0 "$T_RC"
assert_contains "...but it is reported" "nbsp" "$T_OUT"
assert_contains "...at ADVISORY tier" "ADVISORY" "$T_OUT"

scan_body "it warns once${ELL}and then stays quiet"
assert_eq "an ellipsis character does not block" 0 "$T_RC"
assert_contains "...but it is reported" "ellipsis" "$T_OUT"

scan_body "it warns once... and then stays quiet"
assert_eq "three ASCII dots are not an ellipsis character" 0 "$T_RC"
assert_not_contains "...and are not reported" "ellipsis" "$T_OUT"

# An en dash between digits is a numeric range and ordinary typography in
# a version table; flanked by spaces it is a clause dash doing an em
# dash's job, which is the tell.
scan_body "supported on versions 10${EN}20 of the proxy"
assert_eq "an en-dash in a numeric range is not reported" 0 "$T_RC"
assert_not_contains "...and is not reported at all" "en-dash" "$T_OUT"

scan_body "the fix is simple ${EN} it warns once per model"
assert_eq "a space-flanked en-dash does not block" 0 "$T_RC"
assert_contains "...but it is reported as a clause dash" "en-dash" "$T_OUT"

# =========================================================================
# 4. RULE: session-id-bare -- the gap cc-scrub structurally cannot see
#
# cc-scrub's session-id rule is `session_` followed by a token. The ids
# this company actually mints are BARE: __cc_mint_session_id returns 22
# lowercase hex characters with no prefix, and that is what names every
# tree slot, stamps every event, and gets pasted into a brief. Nothing in
# the F1 arm matches one, so a draft quoting a session id would sweep
# clean through cc-scrub today.
# =========================================================================

t_diag "--- rule: session-id-bare ---"

scan_body "dispatched by session ${PLANT_SID} this morning"
assert_eq "a bare 22-hex session id is a finding (exit 1)" 1 "$T_RC"
assert_contains "...reported under rule session-id-bare" "session-id-bare" "$T_OUT"
assert_contains "...at BLOCK tier" "BLOCK" "$T_OUT"
assert_contains "...quoting the offending text" "$PLANT_SID" "$T_OUT"

# The hex runs a real draft is full of. A 40-char sha contains no
# alnum-delimited 22-char run, and neither does a dashless uuid.
scan_body "upstream sha ${BAIT_SHA40} is the merge base"
assert_eq "a 40-hex git sha is not a session id" 0 "$T_RC"
assert_not_contains "...and is not reported at all" "session-id-bare" "$T_OUT"

scan_body "before (${BAIT_SHA7}) and after (d10c2333be)"
assert_eq "short git shas are not session ids" 0 "$T_RC"

scan_body "the request id was ${BAIT_UUID32}"
assert_eq "a 32-hex dashless uuid is not a session id" 0 "$T_RC"

# =========================================================================
# 5. RULE: ai-trailer, and THE DELEGATION IS REAL
# =========================================================================

t_diag "--- rule: ai-trailer ---"

scan_body "thanks for the review" "" "$PLANT_TRAILER"
assert_eq "an assistant co-author trailer in outbound text is a finding" 1 "$T_RC"
assert_contains "...reported under rule ai-trailer" "ai-trailer" "$T_OUT"
assert_contains "...at BLOCK tier" "BLOCK" "$T_OUT"

scan_body "resumed from ${PLANT_SESSION_URL}"
assert_eq "an assistant session URL in outbound text is a finding" 1 "$T_RC"
assert_contains "...reported under rule ai-trailer" "ai-trailer" "$T_OUT"

scan_body "$BAIT_HUMAN_TRAILER"
assert_eq "a co-author trailer naming a human is not a finding" 0 "$T_RC"
assert_not_contains "...and is not reported at all" "ai-trailer" "$T_OUT"

t_diag "--- the F1 class is delegated, not restated ---"

# These three assertions are the delegation contract. They fail if the
# tool ever stops calling cc-scrub -- including the tempting failure where
# somebody re-implements the RFC1918 pattern here and drops the octet
# range checks that make it precise.

scan_body "reachable at ${PLANT_IP} on the lab network"
assert_eq "an RFC1918 host literal in a body is a finding (exit 1)" 1 "$T_RC"
assert_contains "...reported under cc-scrub's rule name, not a local copy" "rfc1918-host" "$T_OUT"
assert_contains "...at BLOCK tier" "BLOCK" "$T_OUT"

# A delegated finding has to arrive WHOLE. cc-scrub's report carries an
# often-empty note column between the match and the fix, and `read` with a
# tab IFS collapses a run of tabs into one delimiter -- so an empty note
# silently shifts every later column left and the operator is told to stop
# without being told what to do about it.
F1FIX=$(printf '%s\n' "$T_OUT" | grep -A1 'rfc1918-host' | grep -m1 'fix:' | sed 's/.*fix: *//')
assert_ne "...carrying the delegate's fix guidance, not an empty column" "" "$F1FIX"

scan_body "the vault lives at ${PLANT_HOMEPATH}"
assert_eq "an absolute home path in a body is a finding" 1 "$T_RC"
assert_contains "...reported under cc-scrub's rule name" "home-path" "$T_OUT"

# The delegate's octet range checks have to survive the delegation. A
# local re-implementation would almost certainly use the naive pattern,
# which reports every one of these decimals as an address.
scan_body "$BAIT_DECIMALS"
assert_eq "decimal measurements are not IP literals through the delegate" 0 "$T_RC"
assert_not_contains "...and are not reported at all" "rfc1918-host" "$T_OUT"

# =========================================================================
# 6. OUTBOUND PACKAGE SHAPE AND CORPUS HONESTY
#
# The false zero specific to THIS surface: the operator runs the sweep
# over the outbound folder, it says CLEAN, and the body that actually gets
# posted was never in the folder. A stem with a .title or a .target but no
# .body.md is exactly that state, so it is INCOMPLETE rather than clean.
# =========================================================================

t_diag "--- outbound package shape ---"

D_PKG=$(t_tmpdir) || exit 1
printf 'a title\n'             > "$D_PKG/pr1.title"
printf 'a body\n'              > "$D_PKG/pr1.body.md"
printf 'https://example.invalid/x\n' > "$D_PKG/pr1.target"
printf 'another title\n'       > "$D_PKG/pr2.title"
printf 'another body\n'        > "$D_PKG/pr2.body.md"
printf 'https://example.invalid/y\n' > "$D_PKG/pr2.target"
t_run bash "$SUBJECT" "$D_PKG"
assert_eq "two complete packages sweep clean" 0 "$T_RC"
assert_contains "...reporting the package count beside the verdict" "packages: 2" "$T_OUT"
assert_contains "...naming the packages it swept" "pr1" "$T_OUT"
assert_contains "...printing the corpus size" "6 swept" "$T_OUT"

D_HALF=$(t_tmpdir) || exit 1
printf 'a title\n'             > "$D_HALF/pr9.title"
printf 'https://example.invalid/z\n' > "$D_HALF/pr9.target"
t_run bash "$SUBJECT" "$D_HALF"
assert_eq "a package with no .body.md is INCOMPLETE (exit 2)" 2 "$T_RC"
assert_contains "...naming the package that is missing one" "pr9" "$T_OUT"
assert_not_contains "...and never printing CLEAN" "VERDICT: CLEAN" "$T_OUT"

# A body with no target is a comment draft, which is a legitimate shape:
# the target is not posted text, so its absence leaves nothing unswept.
D_COMMENT=$(t_tmpdir) || exit 1
printf 'just a comment body\n' > "$D_COMMENT/c1.body.md"
t_run bash "$SUBJECT" "$D_COMMENT"
assert_eq "a body with no target is a legitimate comment package" 0 "$T_RC"

# Explicit files are swept exactly as handed over: the operator asked for
# these files, so completeness is their call and not the tool's.
t_run bash "$SUBJECT" "$D_HALF/pr9.title"
assert_eq "an explicit file is swept without a completeness gate" 0 "$T_RC"
assert_contains "...counting exactly one file" "1 swept" "$T_OUT"

t_diag "--- corpus honesty ---"

D_EMPTY=$(t_tmpdir) || exit 1
t_run bash "$SUBJECT" "$D_EMPTY"
assert_eq "a sweep over an EMPTY corpus refuses to report CLEAN (exit 2)" 2 "$T_RC"
assert_contains "...and says so" "INCOMPLETE" "$T_OUT"
assert_not_contains "...never printing CLEAN" "VERDICT: CLEAN" "$T_OUT"

D_UNS=$(body_with "harmless") || exit 1
printf 'unreadable\n' > "$D_UNS/opaque.bin"
chmod 000 "$D_UNS/opaque.bin"
t_run bash "$SUBJECT" "$D_UNS"
chmod 644 "$D_UNS/opaque.bin"
assert_eq "an unclassifiable file makes the run INCOMPLETE (exit 2)" 2 "$T_RC"
assert_not_contains "...never printing CLEAN" "VERDICT: CLEAN" "$T_OUT"

t_run bash "$SUBJECT" "$D_EMPTY/no-such-file.md"
assert_eq "a path that does not exist is a usage error (exit 3)" 3 "$T_RC"

t_run bash "$SUBJECT"
assert_eq "no paths at all is a usage error (exit 3)" 3 "$T_RC"

# =========================================================================
# 7. THE REAL STAGED PACKAGES (the clean case this tool exists to certify)
#
# The two LiteLLM drafts were swept for F1 by hand and are known clean of
# typographic tells. If this tool cannot report them CLEAN it is unusable
# on the corpus it was built for, and every future false positive lands
# here first.
# =========================================================================

t_diag "--- the real staged outbound packages ---"

if [ -d "$VAULT_OUTBOUND" ]; then
    t_run bash "$SUBJECT" "$VAULT_OUTBOUND"
    assert_eq "the staged LiteLLM packages sweep CLEAN (exit 0)" 0 "$T_RC"
    assert_contains "...reporting a real corpus, not a silently empty one" "6 swept" "$T_OUT"
    assert_contains "...as two complete packages" "packages: 2" "$T_OUT"
    assert_contains "...and saying CLEAN" "VERDICT: CLEAN" "$T_OUT"
else
    t_diag "staged outbound packages not present in this checkout - skipped"
    t_pass "real-package sweep skipped ($VAULT_OUTBOUND absent)"
fi

# =========================================================================
# 8. SELF-LIMITS, AND THE TOOL IS NOT ITS OWN SPECIMEN
#
# cc-scrub keeps the F2 provenance vocabulary out of this public repo
# because that pattern set IS the disclosure it hunts. This arm inherits
# the same boundary and must say so, so that a CLEAN verdict is never read
# as "swept for AI-isms".
# =========================================================================

t_diag "--- stated limits ---"

D_OK=$(body_with "an ordinary sentence") || exit 1
t_run bash "$SUBJECT" "$D_OK"
assert_contains "a CLEAN verdict states it is a lower bound" "lower bound" "$T_OUT"
assert_contains "...naming lexical AI-isms as NOT covered" "vocabulary" "$T_OUT"
assert_contains "...naming F2 provenance as uncovered" "F2" "$T_OUT"

# The tool's own output gets pasted into review threads and task
# reports, so it is an outbound surface in its own right. A scrubber that
# prints the operator's home directory while reporting CLEAN is a
# specimen of the class it hunts -- and this line is the whole reason the
# delegate's path is abbreviated rather than printed raw.
t_run bash "$SUBJECT" "$D_OK"
if printf '%s' "$T_OUT" | grep -qP '(?<![A-Za-z0-9_])/home/[a-z_][a-z0-9_.-]*'; then
    t_fail "the tool's own report carries no absolute home path" \
           "output: $(printf '%s' "$T_OUT" | grep -m1 -P '/home/[a-z_]')"
else
    t_pass "the tool's own report carries no absolute home path"
fi

t_diag "--- the tool is not its own disclosure ---"

D_SELF=$(t_tmpdir) || exit 1
cp "$SUBJECT" "$D_SELF/subject.body.md"
cp "${BASH_SOURCE[0]}" "$D_SELF/subject-tests.body.md"
t_run bash "$SUBJECT" "$D_SELF"
assert_eq "the tool and its tests carry no blocking tell of their own" 0 "$T_RC"

# =========================================================================
# 9. REPORT AND USAGE
# =========================================================================

t_diag "--- report and usage ---"

t_run bash "$SUBJECT" --help
assert_eq "--help exits 0" 0 "$T_RC"
assert_contains "--help names the calibrate-only mode" "--calibrate-only" "$T_OUT"

t_run bash "$SUBJECT" --no-such-flag "$D_OK"
assert_eq "an unknown flag is a usage error (exit 3)" 3 "$T_RC"

# BLOCK-tier findings are never auto-fixed here either: choosing between a
# comma, a colon, a parenthesis and a rewrite is the taste call the whole
# rule exists to route to a human.
t_run bash "$SUBJECT" --fix "$D_OK"
assert_eq "--fix is refused (exit 3)" 3 "$T_RC"
assert_contains "...explaining that findings are never auto-fixed" "never auto-fixed" "$T_ERR$T_OUT"

D_REP=$(t_tmpdir) || exit 1
D_HIT=$(body_with "the fix is simple ${EM} it warns once") || exit 1
bash "$SUBJECT" "$D_HIT" --report "$D_REP/report.tsv" >/dev/null 2>&1
assert_eq "--report writes a file" "yes" \
    "$( [ -s "$D_REP/report.tsv" ] && echo yes || echo no )"
assert_contains "...with a column header" "rule" "$(head -c 4096 "$D_REP/report.tsv" 2>/dev/null)"
assert_contains "...and the finding's rule" "em-dash" "$(cat "$D_REP/report.tsv" 2>/dev/null)"
assert_contains "...and its tier" "BLOCK" "$(cat "$D_REP/report.tsv" 2>/dev/null)"

t_finish
