#!/usr/bin/env bash
# Description: Round-trip fidelity tests for __cc_write_mode_file / __cc_read_mode against all three real readers of .cc-mode, including the shell-sourcing reader that makes free-text values unsafe.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, canonical/shell/cc-functions.sh

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

# The file under test is a variable so tests/mutate.sh can point the suite at a
# deliberately broken copy and confirm the assertions actually bite. It defaults
# to the checked-in file, so an ordinary run needs no environment at all.
CC_FUNCTIONS_UNDER_TEST="${CC_FUNCTIONS_UNDER_TEST:-$MODULE_DIR/canonical/shell/cc-functions.sh}"
# shellcheck source=../canonical/shell/cc-functions.sh
# shellcheck disable=SC1091
source "$CC_FUNCTIONS_UNDER_TEST"

t_begin "__cc_write_mode_file / __cc_read_mode round-trip"

# =========================================================================
# WHY THIS FILE EXISTS
#
# .cc-mode has THREE readers, and they do not agree on what the format is:
#
#   A. anything that SOURCES it as shell. Until INFRA-45 that was
#      canonical/statusline-command.sh, on every repaint of every session; it
#      now parses instead, so reader A no longer has a caller in this repo.
#      It is still tested, and tested hardest, because "no value in this file
#      can execute" is a property of the WRITER and has to hold whether or not
#      a sourcing reader exists today. A file this writer produced must stay
#      inert in anyone's hands.
#   B. cc-functions.sh (cc-continue)        while IFS='=' read -r key val
#      Splits on the FIRST '=' only; val keeps everything after it, and is
#      then decoded with __cc_mode_unquote.
#   C. the session-start skill and cc-tree-slot-write.sh
#      grep '^key=' | cut -d= -f2-  -- same first-'=' semantics as B, without
#      the decode. Safe because the encoding is conditional: every value these
#      readers look up is a bare token in practice, so what they read is what
#      was written. Section 9d pins that.
#
# Reader A was the strict one and the one whose failures were silent: a bad
# value did not error a command anybody was watching, it printed
# "<word>: command not found" into a statusline nobody reads and blanked every
# field after the offending line.
#
# Sections 3-6 were written when __cc_write_mode_file scrubbed six of its nine
# value fields and left mode, slug and parent_repo untouched. They said, in
# the file, that they were "expected to fail the day the gap is closed, which
# is the signal wanted". INFRA-45 closed it; they are restated below against
# the quoting contract, keeping their original fixtures so the before/after is
# readable. Section 9 states and enforces the contract itself.
# =========================================================================

# Positional contract of __cc_write_mode_file, for reading the calls below:
#   1 dir  2 mode  3 slug  4 parent_repo  5 session_id  6 parent_id
#   7 model  8 model_source  9 perm_mode  10 perm_mode_source
EXPECTED_KEYS='mode slug started_at parent_repo session_id parent_id model model_source perm_mode perm_mode_source'

# read_by_source <file> -- source the file in a clean subprocess; print the
# fields as "key=<value>" lines on stdout, and let the subprocess's own stderr
# through so a broken parse is observable.
#
# It runs with its cwd in a scratch directory, and that is not tidiness. This
# helper deliberately sources files containing shell metacharacters, and it is
# pointed at deliberately broken writers by tests/mutate.sh -- so a fixture
# holding `a>b` really does create a file named `b` in whatever directory this
# process happens to be sitting in. It did, once, in the repository working
# tree, which is as clear a demonstration of defect 3 as anyone could ask for
# and not a thing a test should do twice.
READ_BY_SOURCE_CWD=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
read_by_source() {
    ( cd "$READ_BY_SOURCE_CWD" || exit 1
      bash -c '
        set +u
        . "$1"; __src_rc=$?
        for k in mode slug started_at parent_repo session_id parent_id \
                 model model_source perm_mode perm_mode_source; do
            eval "printf %s=%s\\\\n \"\$k\" \"\${$k}\""
        done
        printf "__rc=%s\\n" "$__src_rc"
      ' _ "$1" )
}

# read_by_ifs <file> <key> -- cc-continue's exact parser, for one key.
read_by_ifs() {
    local want="$2" key val
    while IFS='=' read -r key val; do
        [ "$key" = "$want" ] && { printf '%s\n' "$val"; return 0; }
    done < "$1"
    return 1
}

# read_by_cut <file> <key> -- the session-start / tree-slot parser.
read_by_cut() { grep "^$2=" "$1" | cut -d= -f2- ; }

# =========================================================================
# 1. Structure. One writer, three readers: the key set is the contract
#    between them, so it is pinned rather than inferred.
# =========================================================================
D=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
__cc_write_mode_file "$D" branched INFRA-39 /home/u/repo sess001 par001 \
    opus policy:branched-worker "" settings-default

assert_eq "writes exactly 10 lines" 10 "$(wc -l < "$D/.cc-mode")"
assert_eq "writes exactly the expected keys, in order" \
    "$EXPECTED_KEYS" "$(cut -d= -f1 < "$D/.cc-mode" | tr '\n' ' ' | sed 's/ $//')"

# started_at is the one field the writer computes. date -Iseconds never emits a
# space, but nothing asserts that anywhere else, and a space here would break
# reader A for every session on the machine at once.
started=$(read_by_cut "$D/.cc-mode" started_at)
assert_not_contains "started_at contains no space (reader A would break)" " " "$started"
case "$started" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*)
        t_pass "started_at is ISO-8601 to the second" ;;
    *) t_fail "started_at is ISO-8601 to the second" "got: $started" ;;
esac

# =========================================================================
# 2. Clean values round-trip identically through all three readers.
# =========================================================================
src=$(read_by_source "$D/.cc-mode" 2>/dev/null)
assert_contains "reader A: mode"             "mode=branched"                  "$src"
assert_contains "reader A: slug"             "slug=INFRA-39"                  "$src"
assert_contains "reader A: parent_repo"      "parent_repo=/home/u/repo"       "$src"
assert_contains "reader A: session_id"       "session_id=sess001"             "$src"
assert_contains "reader A: parent_id"        "parent_id=par001"               "$src"
assert_contains "reader A: model"            "model=opus"                     "$src"
assert_contains "reader A: model_source"     "model_source=policy:branched-worker" "$src"
assert_contains "reader A: perm_mode empty"  "perm_mode="                     "$src"
assert_contains "reader A: perm_mode_source" "perm_mode_source=settings-default"   "$src"

srcerr=$(read_by_source "$D/.cc-mode" 2>&1 >/dev/null)
assert_eq "reader A: sourcing a clean file is silent" "" "$srcerr"

assert_eq "reader B: slug"          "INFRA-39"  "$(read_by_ifs "$D/.cc-mode" slug)"
assert_eq "reader B: perm_mode is empty, not absent" "" "$(read_by_ifs "$D/.cc-mode" perm_mode; echo)"
assert_eq "reader C: session_id"    "sess001"   "$(read_by_cut "$D/.cc-mode" session_id)"

# A value that legitimately contains ':' must survive readers B and C, which
# split on '=' -- model_source is "policy:<role>" on every policy-resolved
# launch, so this is the common case, not an edge one.
assert_eq "reader B: model_source keeps its colon" \
    "policy:branched-worker" "$(read_by_ifs "$D/.cc-mode" model_source)"
assert_eq "reader C: model_source keeps its colon" \
    "policy:branched-worker" "$(read_by_cut "$D/.cc-mode" model_source)"

# =========================================================================
# 3. Key injection, and what replaced the scrub.
#
#    The old writer defended against key injection by DELETING '=' and
#    newlines from the id fields, and whitespace from the model/perm fields.
#    Deletion defended the file at the cost of the value: what was read back
#    was not what was written, and nothing said so.
#
#    The contract keeps the defence and drops the cost. '=' and whitespace are
#    PRESERVED and the value is quoted, so it is still one line, still one
#    key, and still inert -- and it is still the value the caller passed.
#    Newline remains the single exception, because a line-oriented format
#    cannot hold one.
#
#    The stated purpose is unchanged: $CC_PARENT_ID is an environment
#    variable, so it is the least-trusted input that reaches this file.
# =========================================================================
D2=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
__cc_write_mode_file "$D2" branched ok /repo 'sid=injected' 'pid=also=injected' \
    opus policy:x "" settings-default
assert_eq "'=' in a value: still exactly 10 lines" 10 "$(wc -l < "$D2/.cc-mode")"
assert_eq "'=' in a value: no key was injected" \
    "$EXPECTED_KEYS" "$(cut -d= -f1 < "$D2/.cc-mode" | tr '\n' ' ' | sed 's/ $//')"
# The value survives now instead of being deleted through. A '=' is only
# dangerous because it is this format's separator, and quoting settles that
# without touching the bytes.
assert_eq "'=' in a value: session_id round-trips instead of being mangled" \
    'sid=injected' "$(__cc_mode_unquote "$(read_by_cut "$D2/.cc-mode" session_id)")"
assert_eq "'=' in a value: parent_id keeps BOTH of its '=' characters" \
    'pid=also=injected' "$(__cc_mode_unquote "$(read_by_cut "$D2/.cc-mode" parent_id)")"

D3=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
__cc_write_mode_file "$D3" branched ok /repo "$(printf 'sid\nmode=build')" \
    "$(printf 'pid\nparent_repo=/elsewhere')" opus policy:x "" settings-default
assert_eq "newline scrub: still exactly 10 lines" 10 "$(wc -l < "$D3/.cc-mode")"
assert_eq "newline scrub: mode was not overwritten" "branched" "$(read_by_cut "$D3/.cc-mode" mode)"
assert_eq "newline scrub: parent_repo was not overwritten" "/repo" "$(read_by_cut "$D3/.cc-mode" parent_repo)"

D4=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
__cc_write_mode_file "$D4" branched ok /repo sid pid \
    'op us' 'policy: x' 'accept Edits' 'settings default'
# Under the old scrub these four read back as opus / policy:x / acceptEdits /
# settingsdefault -- the space deleted and the value silently altered. They now
# keep the space, because quoting makes it representable.
assert_eq "space in a value: model round-trips"            'op us'            "$(__cc_mode_unquote "$(read_by_cut "$D4/.cc-mode" model)")"
assert_eq "space in a value: model_source round-trips"     'policy: x'        "$(__cc_mode_unquote "$(read_by_cut "$D4/.cc-mode" model_source)")"
assert_eq "space in a value: perm_mode round-trips"        'accept Edits'     "$(__cc_mode_unquote "$(read_by_cut "$D4/.cc-mode" perm_mode)")"
assert_eq "space in a value: perm_mode_source round-trips" 'settings default' "$(__cc_mode_unquote "$(read_by_cut "$D4/.cc-mode" perm_mode_source)")"
assert_eq "space in a value: reader A stays silent" "" "$(read_by_source "$D4/.cc-mode" 2>&1 >/dev/null)"

D5=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
__cc_write_mode_file "$D5" branched ok /repo "$(printf 'sid\ta')" pid \
    "$(printf 'op\tus')" policy:x "" settings-default
# The old writer scrubbed the tab out of model but left it in session_id --
# an asymmetry with no reason behind it beyond which tr call each field
# happened to get. Both now round-trip, which is the point of having ONE rule.
assert_eq "tab round-trips in model" \
    "$(printf 'op\tus')"  "$(__cc_mode_unquote "$(read_by_cut "$D5/.cc-mode" model)")"
assert_eq "tab round-trips in session_id, same as everywhere else" \
    "$(printf 'sid\ta')" "$(__cc_mode_unquote "$(read_by_cut "$D5/.cc-mode" session_id)")"

# =========================================================================
# 4. FIXED (INFRA-45) -- values containing a space, in the three fields that
#    used to be written with no scrubbing at all.
#
#    Reachable, and reachable by accident: cc-build passes basename
#    "$repo_root" as the slug with no validation, and ALL FOUR wrappers pass
#    "$repo_root" as parent_repo with no validation. A repository checked out
#    at a path containing a space therefore wrote a .cc-mode that reader A
#    could not parse. cc-explore (^[a-zA-Z0-9_-]+$) and cc-branch
#    (^[a-zA-Z0-9_./-]+$) validate their own slug argument, so they were
#    covered by their callers rather than by the writer.
#
#    The fixture below is the one section 4 has always used. What changed is
#    the expectation: the space is no longer a defect to be characterised, it
#    is a value to be carried.
#
#    Note which fix was NOT chosen. Scrubbing spaces the way the model fields
#    did would have silently mangled a filesystem path, which is worse than
#    the symptom -- and it is what the pre-INFRA-45 version of this comment
#    said, before there was a contract to point at.
# =========================================================================
D6=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
__cc_write_mode_file "$D6" branched 'my feature' '/home/u/my repo' sid pid \
    opus policy:x "" settings-default

assert_eq "a space in slug is quoted, not written through raw" \
    "slug='my feature'" "$(grep '^slug=' "$D6/.cc-mode")"
assert_eq "reader A no longer errors on the space in slug" \
    "" "$(read_by_source "$D6/.cc-mode" 2>&1 >/dev/null)"
# The old behaviour was not a truncation but a TOTAL loss: `slug=my feature`
# parsed as the assignment `slug=my` PREFIXED to the command `feature`, and a
# prefix assignment is scoped to that command's environment only. The
# statusline therefore reported the field as EMPTY rather than shortened,
# which is why this never looked like a quoting bug to anyone reading it.
assert_eq "reader A recovers slug in full (was: empty, via prefix assignment)" \
    "slug=my feature" "$(read_by_source "$D6/.cc-mode" 2>/dev/null | grep '^slug=')"
assert_eq "reader A recovers parent_repo in full" \
    "parent_repo=/home/u/my repo" "$(read_by_source "$D6/.cc-mode" 2>/dev/null | grep '^parent_repo=')"
# Readers B and C were never affected by the space -- they split on '=', not on
# whitespace -- so the decode has to give them back exactly what they had.
assert_eq "reader B still returns the path, now via the decode" \
    "/home/u/my repo" "$(__cc_mode_unquote "$(read_by_ifs "$D6/.cc-mode" parent_repo)")"
assert_eq "reader C still returns the path, now via the decode" \
    "/home/u/my repo" "$(__cc_mode_unquote "$(read_by_cut "$D6/.cc-mode" parent_repo)")"

# =========================================================================
# 5. FIXED (INFRA-45) -- an unbalanced quote used to abort the ENTIRE source.
#
#    Worse than the space case: bash gave up at the unterminated quote, so
#    every field on that line and BELOW it was lost. session_id is line 5, so
#    a single stray '"' blanked parent_id, model, model_source, perm_mode and
#    perm_mode_source -- the whole model/permission display the statusline
#    exists to show -- while mode and slug, written above it, survived. A
#    partially-correct statusline is a worse failure than a blank one, and the
#    fields that broke were never the field that was malformed.
#
#    The neighbour assertions are the ones that matter here. A test that only
#    checked the malformed field would have passed against the old code for
#    four of these five values.
# =========================================================================
D7=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
__cc_write_mode_file "$D7" branched ok /repo 'sid"unbalanced' pid \
    opus policy:x "" settings-default
q_err=$(read_by_source "$D7/.cc-mode" 2>&1 >/dev/null)
assert_eq "an unbalanced quote no longer breaks the source" "" "$q_err"
q_out=$(read_by_source "$D7/.cc-mode" 2>/dev/null)
assert_contains "fields above the quote still survive" "slug=ok" "$q_out"
assert_contains "the malformed field itself round-trips" 'session_id=sid"unbalanced' "$q_out"
assert_contains "parent_id, one line below, is intact"   "parent_id=pid"         "$q_out"
assert_contains "model, two lines below, is intact"      "model=opus"            "$q_out"
assert_contains "model_source is intact"                 "model_source=policy:x" "$q_out"
assert_contains "perm_mode_source, at the bottom, is intact" \
    "perm_mode_source=settings-default" "$q_out"
assert_eq "readers B and C recover the quote through the decode" \
    'sid"unbalanced' "$(__cc_mode_unquote "$(read_by_cut "$D7/.cc-mode" session_id)")"

# =========================================================================
# 6. FIXED (INFRA-45) -- .cc-mode is no longer EXECUTABLE config.
#
#    This is the defect that mattered. $CC_PARENT_ID reached parent_id
#    unquoted, and the old scrub removed only newlines and '='. A command
#    substitution contains neither, so it survived the writer intact and was
#    executed by the statusline -- on every repaint, in every session in that
#    worktree, for as long as the session stayed open.
#
#    Calibrated honestly: CC_PARENT_ID is set locally by cc-branch from a
#    minted hex id, so this was never remotely triggerable and should not be
#    written up as though it were. It was a config-data-to-execution path that
#    fired repeatedly, in a file three wrappers write automatically. That is
#    enough to fix properly and not enough to oversell.
#
#    The canary is a filesystem fact rather than an inference from output:
#    section 9 reuses the same technique for every hostile value.
# =========================================================================
D8=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
D8_CANARY="$D8/EXECUTED"
__cc_write_mode_file "$D8" branched ok /repo sid "\$(touch $D8_CANARY)" \
    opus policy:x "" settings-default
assert_eq "the substitution is stored as an inert quoted string" \
    "parent_id='\$(touch $D8_CANARY)'" "$(grep '^parent_id=' "$D8/.cc-mode")"
read_by_source "$D8/.cc-mode" >/dev/null 2>&1
if [ -e "$D8_CANARY" ]; then
    t_fail "reader A does NOT execute it" "canary created: $D8_CANARY"
else
    t_pass "reader A does NOT execute it"
fi
assert_contains "reader A returns it as text" \
    "parent_id=\$(touch $D8_CANARY)" "$(read_by_source "$D8/.cc-mode" 2>/dev/null)"
assert_eq "reader B returns it as text" \
    "\$(touch $D8_CANARY)" "$(__cc_mode_unquote "$(read_by_ifs "$D8/.cc-mode" parent_id)")"

# =========================================================================
# 7. __cc_read_mode -- the upward walk.
#
#    It takes NO argument and always resolves from the process's cwd. That is
#    the same shape as the tree-slot helper defect logged in
#    claude-memory/feedback_tree_slot_helpers_resolve_from_cwd.md, so it is
#    pinned here explicitly rather than left as a surprise: a caller cannot ask
#    "what is the mode of directory X", only "what is the mode of where I am".
# =========================================================================
D9=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
mkdir -p "$D9/a/b/c"
__cc_write_mode_file "$D9" exploration walk /repo sidwalk "" \
    opus policy:explore "" settings-default

got=$(cd "$D9" && __cc_read_mode)
assert_eq "finds .cc-mode in cwd" "$(cat "$D9/.cc-mode")" "$got"

got=$(cd "$D9/a/b/c" && __cc_read_mode)
assert_eq "finds .cc-mode in an ancestor three levels up" "$(cat "$D9/.cc-mode")" "$got"

# The nearest one wins, which is what makes a branch worktree inside a repo
# that also has a .cc-mode report as itself.
__cc_write_mode_file "$D9/a" branched nearer /repo sidnear "" \
    opus policy:x "" settings-default
got=$(cd "$D9/a/b/c" && __cc_read_mode)
assert_contains "the NEAREST .cc-mode wins" "slug=nearer" "$got"

D10=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
t_run bash -c 'cd "$1" && source "$2" && __cc_read_mode' _ "$D10" "$CC_FUNCTIONS_UNDER_TEST"
assert_ne "returns non-zero when no .cc-mode exists anywhere upward" 0 "$T_RC"
assert_eq "  ... and prints nothing" "" "$T_OUT"

# Full loop: write, walk up to it, and parse it back with cc-continue's own
# parser. This is the path a real `cc-continue` takes.
parsed=$(cd "$D9/b" 2>/dev/null || cd "$D9" || exit 1; __cc_read_mode | { \
    while IFS='=' read -r k v; do [ "$k" = "session_id" ] && printf '%s' "$v"; done; })
assert_eq "write -> __cc_read_mode -> cc-continue parser round-trips session_id" \
    "sidwalk" "$parsed"

# =========================================================================
# 8. Failure to write must not look like success.
# =========================================================================
t_run __cc_write_mode_file "/nonexistent-dir-$$" branched ok /repo sid "" \
    opus policy:x "" settings-default
assert_ne "writing into a missing directory returns non-zero" 0 "$T_RC"


# =========================================================================
# 9. THE QUOTING CONTRACT (INFRA-45)
#
#    Sections 4-6 above characterise three ways a value written into .cc-mode
#    misbehaves when reader A sources it: a space blanks the field, an
#    unbalanced quote blanks every field BELOW it, and a command substitution
#    is EXECUTED. All three are the same bug wearing three hats -- the file is
#    shell code and the writer does not make its values shell tokens.
#
#    The contract these tests pin:
#
#      A value is written BARE if and only if every character of it is in the
#      safe set [A-Za-z0-9_@%+:,./-] (the empty string qualifies). Otherwise it
#      is written SINGLE-QUOTED with every embedded ' rendered as '\''.
#      Newline and carriage return are not representable in a line-oriented
#      format and are removed at the write boundary; that is the ONLY lossy
#      transformation, and it is the whole of it.
#
#    The invariant, stated once so it can be pointed at:
#
#      Sourcing a .cc-mode produced by __cc_write_mode_file can never execute
#      anything, and can never alter a field other than the one being assigned.
#
#    "Never" is asserted, not asserted-about: every hostile value below is fed
#    through the REAL writer and the REAL readers, and an execution canary file
#    is checked for absence after each one.
# =========================================================================

# The canary. Nothing legitimate ever creates this path; every hostile value
# that could execute is built to create it, so "did not execute" is a file
# system fact rather than an inference from an error message.
D_CANARY=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
CANARY="$D_CANARY/EXECUTED"

# Value arguments 2..10 of __cc_write_mode_file, as an array indexed 0..8.
# Every filler is deliberately distinctive so a field that gets clobbered by
# its neighbour is visible in the diagnostic rather than merely absent.
#              0=mode    1=slug   2=parent_repo  3=session_id  4=parent_id
#              5=model   6=model_source          7=perm_mode   8=perm_mode_source
Q_DEFAULT=(branched okslug /home/u/repo sidgood pidgood opus policy:role acceptEdits settings-default)
Q_KEY=(mode slug parent_repo session_id parent_id model model_source perm_mode perm_mode_source)

# q_write <dir> <index0> <value> -- write a .cc-mode whose <index0> field holds
# <value> and whose other eight fields hold their known-good filler.
q_write() {
    local dir="$1" idx="$2" val="$3"
    local -a a
    a=("${Q_DEFAULT[@]}")
    a[$idx]="$val"
    __cc_write_mode_file "$dir" "${a[@]}"
}

# q_contract <index0> <case-name> <written-value> <expected-read-back>
#
# One compound assertion per (field, value) pair, because the six sub-checks
# are six faces of ONE property and a suite that reports them separately turns
# a single regression into six red lines. The diagnostic names whichever
# sub-checks failed, so granularity is preserved where it is actually needed.
q_contract() {
    local idx="$1" name="$2" val="$3" want="$4"
    local key="${Q_KEY[$idx]}" d bad="" srcout srcerr i
    d=$(t_tmpdir) || { t_fail "tmpdir"; return 1; }
    rm -f "$CANARY"

    q_write "$d" "$idx" "$val"

    # 1. The file is still ten lines carrying exactly the ten expected keys, in
    #    order. A value that grew a line, or that renamed/injected a key, fails
    #    here before anything else is examined.
    local lines keys
    lines=$(wc -l < "$d/.cc-mode")
    keys=$(cut -d= -f1 < "$d/.cc-mode" | tr '\n' ' ' | sed 's/ $//')
    [ "$lines" = 10 ] || bad="$bad line-count($lines)"
    [ "$keys" = "$EXPECTED_KEYS" ] || bad="$bad key-set"

    # 2. Reader A sources it in silence. Any diagnostic on stderr means the
    #    shell disagreed with the file -- the "command not found" of defect 1
    #    and the "unexpected EOF" of defect 2 both land here.
    srcerr=$(read_by_source "$d/.cc-mode" 2>&1 >/dev/null)
    [ -z "$srcerr" ] || bad="$bad source-stderr"

    # 3. Reader A recovers the value, and 4. every OTHER field is untouched.
    #    Check 4 is defect 2's specific shape: the damage there is positional
    #    and silent, so the neighbours are what has to be asserted.
    srcout=$(read_by_source "$d/.cc-mode" 2>/dev/null)
    local got
    got=$(printf '%s\n' "$srcout" | sed -n "s/^$key=//p")
    [ "$got" = "$want" ] || bad="$bad value(A:$(t_render "$got"))"
    for i in "${!Q_KEY[@]}"; do
        [ "$i" = "$idx" ] && continue
        local nk="${Q_KEY[$i]}" ngot
        ngot=$(printf '%s\n' "$srcout" | sed -n "s/^$nk=//p")
        [ "$ngot" = "${Q_DEFAULT[$i]}" ] || bad="$bad neighbour:$nk($(t_render "$ngot"))"
    done

    # 5. Nothing ran. This is defect 3, and it is the only sub-check whose
    #    failure is a security finding rather than a display bug.
    [ -e "$CANARY" ] && bad="$bad EXECUTED"

    # 6. Reader B -- cc-continue's IFS='=' parser plus the contract's decoder --
    #    recovers the same value. A file that only reader A can read is not a
    #    format, it is a coincidence.
    local gotb
    gotb=$(__cc_mode_unquote "$(read_by_ifs "$d/.cc-mode" "$key")")
    [ "$gotb" = "$want" ] || bad="$bad value(B:$(t_render "$gotb"))"

    rm -f "$CANARY"
    if [ -z "$bad" ]; then
        t_pass "$key holds $name"
    else
        t_fail "$key holds $name" \
            "wrote:  $(t_render "$val")" \
            "wanted: $(t_render "$want")" \
            "failed sub-checks:$bad" \
            "file:" "$(cat "$d/.cc-mode")"
    fi
}

# ---- the hostile table --------------------------------------------------
# Every metacharacter the brief names, plus the two that make a quoted format
# hard rather than merely fiddly: the single quote itself, and the backslash.
q_table() {
    # Emitted as name<TAB>value<TAB>expected triples so a newline inside a
    # value cannot be confused with the record separator.
    printf '%s\t%s\t%s\n' \
        space           'a b'                       'a b' \
        singlequote     "a'b"                       "a'b" \
        doublequote     'a"b'                       'a"b' \
        unbalancedquote 'a"b c'                     'a"b c' \
        backslash       'a\b'                       'a\b' \
        equals          'a=b'                       'a=b' \
        dollar          'a$b'                       'a$b' \
        semicolon       'a;b'                       'a;b' \
        pipe            'a|b'                       'a|b' \
        redirect        'a>b'                       'a>b' \
        tilde           '~/x'                       '~/x' \
        paramexp        'a${HOME}b'                 'a${HOME}b' \
        backtick        "a\`touch $CANARY\`b"       "a\`touch $CANARY\`b" \
        cmdsubst        "a\$(touch $CANARY)b"       "a\$(touch $CANARY)b"
}

# Newline is handled separately: it is the one value the format cannot hold, so
# its expectation is the stripped form rather than the value written.
Q_NL_IN=$'a\nparent_id=$(touch '"$CANARY"$')\nb'
Q_NL_WANT='aparent_id=$(touch '"$CANARY"')b'

# ---- 9a. every hostile value, at three positions in the file -------------
#
# Three positions rather than nine, because what varies by FIELD is position,
# and position is exactly what defect 2 exploits: an unterminated quote damages
# everything BELOW its line and nothing above it. So the table runs at the
# first line (mode), the middle (session_id -- the line the reproduction in the
# brief used), and the last (perm_mode_source), which brackets the blast
# radius. Field-by-field coverage follows in 9b.
for POS in 0 3 8; do
    while IFS=$'\t' read -r qname qval qwant; do
        [ -n "$qname" ] || continue
        q_contract "$POS" "$qname" "$qval" "$qwant"
    done < <(q_table)
    q_contract "$POS" "newline (stripped -- the format is line-oriented)" \
        "$Q_NL_IN" "$Q_NL_WANT"
done

# ---- 9b. one composite hostile value, in every field ---------------------
#
# Every metacharacter at once, so no field is left holding only the easy cases.
Q_ALL="a b'c\"d\`touch $CANARY\`e\$(touch $CANARY)f\${HOME}g=h;i|j>k\\l"
for POS in 0 1 2 3 4 5 6 7 8; do
    q_contract "$POS" "the composite hostile value" "$Q_ALL" "$Q_ALL"
done

# ---- 9c. the encoder and decoder, directly -------------------------------
#
# q_contract exercises them through the file. These pin the two halves on
# their own, so a failure says which half moved.
assert_eq "quote: a safe token is written bare (the wire format does not change)" \
    "policy:branched-worker" "$(__cc_mode_quote 'policy:branched-worker')"
assert_eq "quote: every character of the safe set stays bare" \
    'aZ9_@%+:,./-' "$(__cc_mode_quote 'aZ9_@%+:,./-')"
assert_eq "quote: the empty string stays bare (perm_mode= is a legal line)" \
    "" "$(__cc_mode_quote '')"
assert_eq "quote: a space forces quoting" \
    "'a b'" "$(__cc_mode_quote 'a b')"
assert_eq "quote: an embedded single quote becomes '\\''" \
    "'a'\\''b'" "$(__cc_mode_quote "a'b")"
assert_eq "quote: a newline is removed, not quoted" \
    "ab" "$(__cc_mode_quote "$(printf 'a\nb')")"
assert_eq "quote: a carriage return is removed too" \
    "ab" "$(__cc_mode_quote "$(printf 'a\rb')")"

assert_eq "unquote: a bare value decodes as itself" \
    "opus" "$(__cc_mode_unquote 'opus')"
assert_eq "unquote: a legacy unquoted value with a space decodes as itself" \
    "my feature" "$(__cc_mode_unquote 'my feature')"
assert_eq "unquote: the empty string decodes as itself" \
    "" "$(__cc_mode_unquote '')"
assert_eq "unquote: reverses quote for a value made only of single quotes" \
    "'''" "$(__cc_mode_unquote "$(__cc_mode_quote "'''")")"
assert_eq "unquote: reverses quote for a value that is one single quote" \
    "'" "$(__cc_mode_unquote "$(__cc_mode_quote "'")")"
assert_eq "unquote: reverses quote for a value ending in a single quote" \
    "ab'" "$(__cc_mode_unquote "$(__cc_mode_quote "ab'")")"
assert_eq "unquote: reverses quote for a value that is entirely metacharacters" \
    '$`\"'"'" "$(__cc_mode_unquote "$(__cc_mode_quote '$`\"'"'")")"

# The encoder's output must be a shell word that evaluates back to the input.
# Asserted by having a clean subprocess do the evaluation, because "is a valid
# shell token" is not a property any string comparison can check.
q_eval_roundtrip() {
    local v="$1" q got
    q=$(__cc_mode_quote "$v")
    got=$(bash -c 'eval "x=$1"; printf %s "$x"' _ "$q" 2>/dev/null)
    assert_eq "eval round-trip: $2" "$v" "$got"
}
q_eval_roundtrip 'a b'            "space"
q_eval_roundtrip "a'b"            "single quote"
q_eval_roundtrip 'a"b'            "double quote"
q_eval_roundtrip 'a`b`'           "backtick"
q_eval_roundtrip 'a$(b)'          "command substitution"
q_eval_roundtrip 'a${b}'          "parameter expansion"
q_eval_roundtrip 'a=b'            "equals"
q_eval_roundtrip 'a\b'            "backslash"
q_eval_roundtrip '~/x'            "leading tilde (must not expand)"
q_eval_roundtrip "$Q_ALL"         "the composite hostile value"

# ---- 9d. the wire format does not move for values seen in the wild -------
#
# Every value the four wrappers actually write today is a safe token, so a
# correct implementation of this contract leaves real .cc-mode files
# byte-identical. That is the whole reason the encoding is conditional rather
# than unconditional: six OTHER readers of this file (cc-tree-slot-write.sh,
# cc-tree-slot-update.sh, cc-status-scan.sh, cc-reclaim-window.sh,
# cc-plane-sync.sh and the session-start skill) parse it with
# `grep '^key=' | cut -d= -f2-` and would have to be changed in lockstep if
# ordinary values grew quotes. This assertion is what stops that happening by
# accident.
D_WIRE=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
__cc_write_mode_file "$D_WIRE" branched INFRA-45 /home/mhurt/environment-foundation \
    d5112587ab04478ab4a29e 72227ce9183843ee8c2599 opus policy:branched-worker "" settings-default
assert_eq "wire format: a real branched launch is written entirely bare" \
    "mode=branched
slug=INFRA-45
parent_repo=/home/mhurt/environment-foundation
session_id=d5112587ab04478ab4a29e
parent_id=72227ce9183843ee8c2599
model=opus
model_source=policy:branched-worker
perm_mode=
perm_mode_source=settings-default" \
    "$(grep -v '^started_at=' "$D_WIRE/.cc-mode")"

# ---- 9e. the reproduction from the brief, verbatim ----------------------
#
# The three defects as they were actually reproduced, kept in the shape they
# were reported in so this file answers "is INFRA-45 fixed?" directly.
D_R1=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
__cc_write_mode_file "$D_R1" branched 'my thing' /tmp sid2 '' opus policy '' settings-default
assert_eq "defect 1: a space in slug no longer blanks the field" \
    "slug=my thing" "$(read_by_source "$D_R1/.cc-mode" 2>/dev/null | grep '^slug=')"
assert_eq "defect 1: sourcing is silent" "" "$(read_by_source "$D_R1/.cc-mode" 2>&1 >/dev/null)"

D_R2=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
__cc_write_mode_file "$D_R2" branched ok '/tmp/we"ird' sid2 pid2 \
    opus policy:x "" settings-default
r2=$(read_by_source "$D_R2/.cc-mode" 2>/dev/null)
assert_eq "defect 2: an unbalanced quote no longer blanks the fields below it" \
    "session_id=sid2" "$(printf '%s\n' "$r2" | grep '^session_id=')"
assert_eq "defect 2: ... nor the model two lines further down" \
    "model=opus" "$(printf '%s\n' "$r2" | grep '^model=')"
assert_eq "defect 2: and the malformed field itself round-trips" \
    'parent_repo=/tmp/we"ird' "$(printf '%s\n' "$r2" | grep '^parent_repo=')"

D_R3=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
rm -f "$CANARY"
__cc_write_mode_file "$D_R3" branched ok /repo sid "\$(touch $CANARY)" \
    opus policy:x "" settings-default
read_by_source "$D_R3/.cc-mode" >/dev/null 2>&1
if [ -e "$CANARY" ]; then
    t_fail "defect 3: sourcing a .cc-mode must not execute a command substitution" \
        "the canary file was created: $CANARY"
else
    t_pass "defect 3: sourcing a .cc-mode must not execute a command substitution"
fi
assert_eq "defect 3: the substitution round-trips as inert text" \
    "\$(touch $CANARY)" "$(__cc_mode_unquote "$(read_by_cut "$D_R3/.cc-mode" parent_id)")"
rm -f "$CANARY"

# Sourcing repeatedly is what the statusline does; once-safe is not the claim.
for _ in 1 2 3; do read_by_source "$D_R3/.cc-mode" >/dev/null 2>&1; done
if [ -e "$CANARY" ]; then
    t_fail "defect 3: still inert after three repaints' worth of sourcing" \
        "the canary file was created: $CANARY"
else
    t_pass "defect 3: still inert after three repaints' worth of sourcing"
fi
rm -f "$CANARY"

t_finish
