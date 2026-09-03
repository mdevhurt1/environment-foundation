#!/usr/bin/env bash
# Description: Mutation check — breaks cc-functions.sh and statusline-command.sh in known ways and asserts the test suite catches each one, so that a green run means something.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, jq, python3, coreutils, the tests in this directory
# Idempotent. Never modifies a checked-in file — every mutation is applied to a
# throwaway copy under $TMPDIR.

set -uo pipefail   # NOT -e: every mutation must be attempted and reported.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MODULE_DIR/../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

# Two subjects now, not one. INFRA-45 moved half the .cc-mode fix into the
# READER -- the statusline stopped sourcing the file and started parsing it --
# and a mutation table that can only reach cc-functions.sh would leave that
# half unmutated, which is the same as leaving it untested. Each mutation
# names its subject; the test file it must break is invoked with the matching
# *_UNDER_TEST variable so the suite loads the mutant rather than the original.
declare -A SUBJECTS=(
    [functions]="$MODULE_DIR/canonical/shell/cc-functions.sh"
    [statusline]="$MODULE_DIR/canonical/statusline-command.sh"
)
declare -A SUBJECT_ENV=(
    [functions]=CC_FUNCTIONS_UNDER_TEST
    [statusline]=STATUSLINE_UNDER_TEST
)

# A test that has never been seen to fail proves nothing. Each mutation below
# breaks ONE behaviour the suite claims to protect, and names the test file that
# must go red. Three outcomes:
#
#   CAUGHT    the named test file failed. Good.
#   SURVIVED  the test file still passed. That is a GAP IN THE TESTS, reported
#             as a failure of this script, not as a pass.
#   STALE     the code no longer contains the text this mutation edits, so the
#             mutation tested nothing. Also a failure: a mutation table that
#             quietly stops applying is the same as no mutation table.
#
# Patterns are held in quoted heredocs rather than in a one-line table so the
# before/after reads as the actual code, with no escaping layer to get wrong.

declare -a M_LABEL M_TEST M_FROM M_TO M_SUBJ
# add_mut <label> <test-file> <from> <to> [subject]   subject defaults to
# "functions"; the other value is "statusline".
add_mut() {
    M_LABEL+=("$1"); M_TEST+=("$2"); M_FROM+=("$3"); M_TO+=("$4")
    M_SUBJ+=("${5:-functions}")
}

# ---- __cc_resolve_model --------------------------------------------------

# The exact historical failure: a role that cannot be resolved falls through to
# Claude Code's "Default", which is a moving referent. No error, no diff, a
# different model. This is the mutation the whole refusal contract exists for.
add_mut "absent role silently resolves to Default" test_resolve_model.sh \
"$(cat <<'FROM'
.roles[$r].model // empty
FROM
)" "$(cat <<'TO'
.roles[$r].model // "Default"
TO
)"

add_mut "env override reports the wrong source" test_resolve_model.sh \
"$(cat <<'FROM'
        printf '%s\t%s\n' "$CC_MODEL" "env"
FROM
)" "$(cat <<'TO'
        printf '%s\t%s\n' "$CC_MODEL" "policy"
TO
)"

# ---- __cc_resolve_perm ---------------------------------------------------

# Drop the leading tab from the fall-through line. __cc_perm_prepare splits on
# that tab; without it the VALUE becomes "settings-default", which
# __cc_perm_stage rejects as not a permission mode claude accepts — aborting
# every launch on the machine. A one-character edit, catastrophic blast radius.
add_mut "fall-through loses its empty value field" test_resolve_perm.sh \
"$(cat <<'FROM'
    printf '\t%s\n' "settings-default"
FROM
)" "$(cat <<'TO'
    printf '%s\n' "settings-default"
TO
)"

# Turn the deliberate asymmetry with __cc_resolve_model into symmetry: refuse
# instead of falling through. Locks in the reasoning recorded in the source.
add_mut "missing policy becomes fatal for the permission mode" test_resolve_perm.sh \
"$(cat <<'FROM'
    if [ -n "$mode" ]; then
        printf '%s\t%s\n' "$mode" "policy:$role"
        return 0
    fi
FROM
)" "$(cat <<'TO'
    if [ -n "$mode" ]; then
        printf '%s\t%s\n' "$mode" "policy:$role"
        return 0
    fi
    return 1
TO
)"

# ---- __cc_write_mode_file ------------------------------------------------

# RETARGETED by INFRA-45. This was "'=' scrub dropped from session_id", editing
# `_sid=$(printf %s "$5" | tr -d '\n=')`, a line the quoting contract deleted.
# The INTENT is unchanged and is why it was retargeted rather than dropped: a
# malformed id must not be able to inject extra .cc-mode keys. Under the
# contract that defence is no longer the '=' scrub -- a '=' inside a value is
# harmless once the value is one quoted token -- it is the line-break strip,
# because a newline is the only character that can still manufacture a second
# line, and therefore a second key. So the mutation now removes that strip.
add_mut "line-break strip dropped from the encoder" test_mode_file_roundtrip.sh \
"$(cat <<'FROM'
    v=${v//$'\n'/}
FROM
)" "$(cat <<'TO'
    v=${v//$'\r'/}
TO
)"

# RETARGETED by INFRA-45. This was "whitespace scrub dropped from model",
# editing `_model=$(printf %s "${7:-}" | tr -d "\n= \t")`, also deleted by the
# contract. Intent unchanged: a value containing a space must not reach a
# sourcing reader unquoted. The defence moved from deleting the space to
# quoting the value, so the mutation now admits the space into the safe-bare
# set -- the one edit that would put a raw space back into the file. The space
# is written as a quoted " " because an unquoted one inside a case pattern
# ends the pattern word, and a mutant that does not parse tests nothing.
add_mut "a space is admitted to the safe-bare set" test_mode_file_roundtrip.sh \
"$(cat <<'FROM'
        *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+:,./-]*)
FROM
)" "$(cat <<'TO'
        *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+:,./-" "]*)
TO
)"

# The escape that makes single-quoting work at all. Without it a value
# containing a quote closes the quoting early and the rest of the value is
# bare shell — the unbalanced-quote defect, reintroduced by one deletion.
add_mut "the single-quote escape is dropped from the encoder" test_mode_file_roundtrip.sh \
"$(cat <<'FROM'
            printf "'%s'" "${v//\'/\'\\\'\'}" ;;
FROM
)" "$(cat <<'TO'
            printf "'%s'" "$v" ;;
TO
)"

# The safe set is the whole security predicate. Admitting '$' writes a command
# substitution into the file bare — defect 3, restored by one character.
add_mut "'\$' is admitted to the safe-bare set" test_mode_file_roundtrip.sh \
"$(cat <<'FROM'
        *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+:,./-]*)
FROM
)" "$(cat <<'TO'
        *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+:,./$-]*)
TO
)"

# The decoder half. If it stops unquoting, every quoted value reaches
# cc-continue and the tests with its quote characters still attached.
add_mut "the decoder stops unquoting" test_mode_file_roundtrip.sh \
"$(cat <<'FROM'
        "'"*"'")
            v=${v#\'}
            v=${v%\'}
FROM
)" "$(cat <<'TO'
        "'"*"'"XXNEVERXX)
            v=${v#\'}
            v=${v%\'}
TO
)"

# ---- statusline-command.sh -----------------------------------------------

# The whole reader-side fix, reverted: source .cc-mode instead of parsing it.
# This is the mutation the statusline tests exist for — it restores all three
# INFRA-45 defects for any .cc-mode the writer did not produce.
add_mut "the statusline sources .cc-mode again" test_statusline.sh \
"$(cat <<'FROM'
        while IFS= read -r line || [ -n "$line" ]; do
            case $line in
                mode=*)  __cc_unq "${line#mode=}";  mode=$UNQ  ;;
                slug=*)  __cc_unq "${line#slug=}";  slug=$UNQ  ;;
                model=*) __cc_unq "${line#model=}"; model=$UNQ ;;
            esac
        done < "$dir/.cc-mode"
FROM
)" "$(cat <<'TO'
        # shellcheck disable=SC1090,SC1091
        . "$dir/.cc-mode"
TO
)" statusline

# The statusline carries its own copy of the decoder because it is /bin/sh and
# cannot source cc-functions.sh on every repaint. Two copies of one algorithm
# is a standing invitation for them to drift, so the copy gets its own
# mutation rather than riding on the bash one's coverage.
add_mut "the statusline decoder drops the escape collapse" test_statusline.sh \
"$(cat <<'FROM'
        UNQ=$UNQ$_pre\'
FROM
)" "$(cat <<'TO'
        UNQ=$UNQ$_pre
TO
)" statusline

# The statusline's key whitelist. Widening it to a prefix match lets
# model_source overwrite the model, which is the drift indicator the whole
# instrument exists to show.
add_mut "the statusline whitelist becomes a prefix match" test_statusline.sh \
"$(cat <<'FROM'
                model=*) __cc_unq "${line#model=}"; model=$UNQ ;;
FROM
)" "$(cat <<'TO'
                model*) __cc_unq "${line#model=}"; model=$UNQ ;;
TO
)" statusline

# Rename a key. Readers B and C look the key up by name, so this silently blanks
# the field for cc-continue and for the tree-slot writer.
add_mut "a key is renamed in the written file" test_mode_file_roundtrip.sh \
"$(cat <<'FROM'
perm_mode_source=$_psrc
FROM
)" "$(cat <<'TO'
permmode_source=$_psrc
TO
)"

# ---- __cc_read_mode ------------------------------------------------------

# Stop the upward walk after one level: a session anywhere below the worktree
# root stops finding its own .cc-mode.
add_mut "upward walk stops after one level" test_mode_file_roundtrip.sh \
"$(cat <<'FROM'
            cat "$dir/.cc-mode"
            return 0
        fi
        dir=$(dirname "$dir")
FROM
)" "$(cat <<'TO'
            cat "$dir/.cc-mode"
            return 0
        fi
        dir=/
TO
)"

# ==========================================================================

WORK=$(mktemp -d) || exit 2
trap 'rm -rf "$WORK"' EXIT

caught=0 survived=0 stale=0

printf 'Mutation check: %s\n' "${SUBJECTS[functions]}"
printf '                %s\n' "${SUBJECTS[statusline]}"
printf '(the checked-in files are never modified; mutants live under %s)\n\n' "$WORK"

for i in "${!M_LABEL[@]}"; do
    label="${M_LABEL[$i]}" testfile="${M_TEST[$i]}"
    subj="${M_SUBJ[$i]}"
    subject="${SUBJECTS[$subj]}"
    subject_env="${SUBJECT_ENV[$subj]}"
    mutant="$WORK/mutant-$i.sh"
    cp "$subject" "$mutant"

    # Literal substitution, applied once. Exit 3 means the pattern is gone, which
    # is reported rather than silently producing an unmutated "mutant"; exit 4
    # means it appears more than once, which would make the mutation ambiguous.
    M_FROM_TEXT="${M_FROM[$i]}" M_TO_TEXT="${M_TO[$i]}" python3 - "$mutant" <<'PY'
import os, sys
path = sys.argv[1]
frm, to = os.environ["M_FROM_TEXT"], os.environ["M_TO_TEXT"]
s = open(path).read()
n = s.count(frm)
if n == 0:
    sys.exit(3)
if n > 1:
    sys.exit(4)
open(path, "w").write(s.replace(frm, to, 1))
PY
    prc=$?
    if [ "$prc" -eq 3 ]; then
        log_error "STALE    $label"
        printf '         the text this mutation edits is no longer in %s\n' "$(basename "$subject")"
        stale=$((stale + 1)); continue
    elif [ "$prc" -eq 4 ]; then
        log_error "STALE    $label"
        printf '         the pattern matches more than once; make it unique\n'
        stale=$((stale + 1)); continue
    elif [ "$prc" -ne 0 ]; then
        log_error "STALE    $label (mutation could not be applied, rc=$prc)"
        stale=$((stale + 1)); continue
    fi

    # The mutant must still parse, or "the tests failed" would only prove that
    # a syntax error breaks bash.
    if ! bash -n "$mutant" 2>/dev/null; then
        log_error "STALE    $label (mutant does not parse)"
        stale=$((stale + 1)); continue
    fi

    out=$(env "$subject_env=$mutant" \
          -u CC_MODEL -u CC_MODEL_POLICY -u CC_PERM_MODE \
          bash "$SCRIPT_DIR/$testfile" 2>&1)
    rc=$?

    if [ "$rc" -ne 0 ]; then
        log_ok "CAUGHT   $label"
        printf '         %s failed %s assertion(s), first:\n' \
            "$testfile" "$(printf '%s\n' "$out" | grep -c '^not ok')"
        printf '%s\n' "$out" | grep -m1 '^not ok' | sed 's/^/           /'
        printf '%s\n' "$out" | grep -A2 -m1 '^not ok' | grep '^#' | sed 's/^/           /'
        caught=$((caught + 1))
    else
        log_error "SURVIVED $label"
        printf '         %s passed against a mutant that should have broken it.\n' "$testfile"
        printf '         This is a GAP IN THE TESTS, not a passing result.\n'
        survived=$((survived + 1))
    fi
done

echo
printf 'mutations: %d   caught: %d  survived: %d  stale: %d\n' \
    "${#M_LABEL[@]}" "$caught" "$survived" "$stale"
if [ "$survived" -eq 0 ] && [ "$stale" -eq 0 ]; then
    log_ok "every mutation was caught — the suite bites."
    exit 0
fi
log_error "the suite does not fully bite."
exit 1
