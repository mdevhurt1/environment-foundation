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
#   A. canonical/statusline-command.sh:37   . "$dir/.cc-mode"
#      Sources it AS SHELL. Every value must therefore be a single bare token.
#      This reader runs on every statusline repaint, in every session, in
#      every worktree.
#   B. cc-functions.sh:620 (cc-continue)    while IFS='=' read -r key val
#      Splits on the FIRST '=' only; val keeps everything after it.
#   C. the session-start skill and cc-tree-slot-write.sh
#      grep '^key=' | cut -d= -f2-  -- same first-'=' semantics as B.
#
# Reader A is the strict one and the one whose failures are silent: a bad value
# does not error a command anybody is watching, it prints
# "<word>: command not found" into a statusline nobody reads and blanks every
# field after the offending line.
#
# __cc_write_mode_file scrubs for A on SIX of its nine value fields. The other
# three -- mode, slug, parent_repo -- are unscrubbed, and started_at is
# computed. The tests below assert the scrub where it exists and CHARACTERISE
# the behaviour where it does not; the latter are prefixed "KNOWN DEFECT" and
# are expected to fail the day the gap is closed, which is the signal wanted.
# =========================================================================

# Positional contract of __cc_write_mode_file, for reading the calls below:
#   1 dir  2 mode  3 slug  4 parent_repo  5 session_id  6 parent_id
#   7 model  8 model_source  9 perm_mode  10 perm_mode_source
EXPECTED_KEYS='mode slug started_at parent_repo session_id parent_id model model_source perm_mode perm_mode_source'

# read_by_source <file> -- source the file in a clean subprocess; print the
# fields as "key=<value>" lines on stdout, and let the subprocess's own stderr
# through so a broken parse is observable.
read_by_source() {
    bash -c '
        set +u
        . "$1"; __src_rc=$?
        for k in mode slug started_at parent_repo session_id parent_id \
                 model model_source perm_mode perm_mode_source; do
            eval "printf %s=%s\\\\n \"\$k\" \"\${$k}\""
        done
        printf "__rc=%s\\n" "$__src_rc"
    ' _ "$1"
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
# 3. The scrub that IS implemented: '=' and newline on the id fields, and
#    additionally whitespace on the four model/perm fields.
#
#    The stated purpose is key injection: $CC_PARENT_ID is an environment
#    variable, so it is the least-trusted input that reaches this file.
# =========================================================================
D2=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
__cc_write_mode_file "$D2" branched ok /repo 'sid=injected' 'pid=also=injected' \
    opus policy:x "" settings-default
assert_eq "'=' scrub: still exactly 10 lines" 10 "$(wc -l < "$D2/.cc-mode")"
assert_eq "'=' scrub: session_id" "sidinjected"     "$(read_by_cut "$D2/.cc-mode" session_id)"
assert_eq "'=' scrub: parent_id"  "pidalsoinjected" "$(read_by_cut "$D2/.cc-mode" parent_id)"
assert_eq "'=' scrub: no key was injected" \
    "$EXPECTED_KEYS" "$(cut -d= -f1 < "$D2/.cc-mode" | tr '\n' ' ' | sed 's/ $//')"

D3=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
__cc_write_mode_file "$D3" branched ok /repo "$(printf 'sid\nmode=build')" \
    "$(printf 'pid\nparent_repo=/elsewhere')" opus policy:x "" settings-default
assert_eq "newline scrub: still exactly 10 lines" 10 "$(wc -l < "$D3/.cc-mode")"
assert_eq "newline scrub: mode was not overwritten" "branched" "$(read_by_cut "$D3/.cc-mode" mode)"
assert_eq "newline scrub: parent_repo was not overwritten" "/repo" "$(read_by_cut "$D3/.cc-mode" parent_repo)"

D4=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
__cc_write_mode_file "$D4" branched ok /repo sid pid \
    'op us' 'policy: x' 'accept Edits' 'settings default'
assert_eq "whitespace scrub: model"            "opus"            "$(read_by_cut "$D4/.cc-mode" model)"
assert_eq "whitespace scrub: model_source"     "policy:x"        "$(read_by_cut "$D4/.cc-mode" model_source)"
assert_eq "whitespace scrub: perm_mode"        "acceptEdits"     "$(read_by_cut "$D4/.cc-mode" perm_mode)"
assert_eq "whitespace scrub: perm_mode_source" "settingsdefault" "$(read_by_cut "$D4/.cc-mode" perm_mode_source)"
assert_eq "whitespace scrub: reader A stays silent" "" "$(read_by_source "$D4/.cc-mode" 2>&1 >/dev/null)"

D5=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
__cc_write_mode_file "$D5" branched ok /repo "$(printf 'sid\ta')" pid \
    "$(printf 'op\tus')" policy:x "" settings-default
assert_eq "tab is scrubbed from model" "opus" "$(read_by_cut "$D5/.cc-mode" model)"
# session_id's scrub set is '\n=' only, so a tab survives there. Harmless for
# reader A (a bare tab is just whitespace after '='), but it means the value
# read back is NOT the value written -- recorded so the asymmetry is on paper.
assert_eq "tab SURVIVES in session_id (scrub set is newline and '=' only)" \
    "$(printf 'sid\ta')" "$(read_by_cut "$D5/.cc-mode" session_id)"

# =========================================================================
# 4. KNOWN DEFECT -- values containing a space, in the three UNSCRUBBED fields.
#
#    Reachable today: cc-build passes basename "$repo_root" as the slug with no
#    validation, and ALL FOUR wrappers pass "$repo_root" as parent_repo with no
#    validation. A repository checked out at a path containing a space
#    therefore writes a .cc-mode that reader A cannot parse. cc-explore
#    (^[a-zA-Z0-9_-]+$) and cc-branch (^[a-zA-Z0-9_./-]+$) validate their own
#    slug argument, so they are covered by their callers, not by the writer.
#
#    These assertions describe what happens NOW. When the writer is fixed they
#    will fail, which is the intended signal: come back and restate the
#    contract rather than discovering the change from a blank statusline.
#
#    The fix is NOT "scrub spaces like the model fields do" -- silently
#    mangling a filesystem path is worse than the symptom. It is either to
#    shell-quote the values on write (and teach readers B and C to unquote) or
#    to refuse at the write boundary. That is a larger change than this ticket
#    owns; see the INFRA-39 report.
# =========================================================================
D6=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
__cc_write_mode_file "$D6" branched 'my feature' '/home/u/my repo' sid pid \
    opus policy:x "" settings-default

assert_eq "KNOWN DEFECT: a space in slug is written through unscrubbed" \
    "my feature" "$(read_by_cut "$D6/.cc-mode" slug)"
assert_contains "KNOWN DEFECT: reader A errors on the space in slug" \
    "command not found" "$(read_by_source "$D6/.cc-mode" 2>&1 >/dev/null)"
# Not a truncation -- a TOTAL loss. `slug=my feature` parses as the assignment
# `slug=my` PREFIXED to the command `feature`, and a prefix assignment is
# scoped to that command's environment only. So the statusline reports the
# field as EMPTY, not as a shortened value, which is why this has never looked
# like a quoting bug to anyone reading the statusline.
assert_eq "KNOWN DEFECT: reader A loses slug entirely (prefix assignment)" \
    "slug=" "$(read_by_source "$D6/.cc-mode" 2>/dev/null | grep '^slug=')"
assert_eq "KNOWN DEFECT: reader A loses parent_repo entirely" \
    "parent_repo=" "$(read_by_source "$D6/.cc-mode" 2>/dev/null | grep '^parent_repo=')"
# Readers B and C are unaffected -- they split on '=', not on whitespace.
assert_eq "readers B and C survive a space in parent_repo" \
    "/home/u/my repo" "$(read_by_ifs "$D6/.cc-mode" parent_repo)"

# =========================================================================
# 5. KNOWN DEFECT -- an unbalanced quote aborts the ENTIRE source.
#
#    Worse than the space case: bash gives up at the unterminated quote, so
#    every field on that line and BELOW it is lost. session_id is line 5, so a
#    single stray '"' blanks parent_id, model, model_source, perm_mode and
#    perm_mode_source -- i.e. the whole model/permission display the statusline
#    exists to show -- while mode and slug, written above it, survive. A
#    partially-correct statusline is a worse failure than a blank one.
# =========================================================================
D7=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
__cc_write_mode_file "$D7" branched ok /repo 'sid"unbalanced' pid \
    opus policy:x "" settings-default
q_err=$(read_by_source "$D7/.cc-mode" 2>&1 >/dev/null)
assert_contains "KNOWN DEFECT: an unbalanced quote breaks the source outright" \
    "unexpected EOF" "$q_err"
q_out=$(read_by_source "$D7/.cc-mode" 2>/dev/null)
assert_contains "KNOWN DEFECT: fields ABOVE the bad line still survive" "slug=ok" "$q_out"
assert_contains "KNOWN DEFECT: fields BELOW the bad line are lost" "model=" "$q_out"
assert_not_contains "KNOWN DEFECT: model_source is lost with them" "policy:x" "$q_out"
# Readers B and C are unaffected, so the damage is confined to the statusline.
assert_eq "readers B and C survive the quote" \
    'sid"unbalanced' "$(read_by_cut "$D7/.cc-mode" session_id)"

# =========================================================================
# 6. KNOWN DEFECT -- .cc-mode is EXECUTABLE config for reader A.
#
#    $CC_PARENT_ID reaches parent_id unquoted, and the scrub removes only
#    newlines and '='. A value containing a command substitution is therefore
#    executed by the statusline, on every repaint, in every session in that
#    worktree. Not currently reachable from anything hostile -- CC_PARENT_ID is
#    set by cc-branch from a minted hex id -- but it is an environment
#    variable, which makes it the least-trusted input in the file, and nothing
#    downstream of the scrub notices.
# =========================================================================
D8=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
__cc_write_mode_file "$D8" branched ok /repo sid '$(printf CMDSUBST)' \
    opus policy:x "" settings-default
assert_eq "KNOWN DEFECT: the substitution is stored verbatim" \
    '$(printf CMDSUBST)' "$(read_by_cut "$D8/.cc-mode" parent_id)"
assert_contains "KNOWN DEFECT: reader A EXECUTES it" \
    "parent_id=CMDSUBST" "$(read_by_source "$D8/.cc-mode" 2>/dev/null)"

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

t_finish
