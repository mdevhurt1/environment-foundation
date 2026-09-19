#!/usr/bin/env bash
# Description: Tests for canonical/statusline-command.sh — the reader that used to SOURCE .cc-mode on every repaint, covering the whitelist parser that replaced it and the hostile files a writer-side fix cannot reach.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, jq, coreutils, canonical/statusline-command.sh

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

# Overridable for the same reason CC_FUNCTIONS_UNDER_TEST is: a suite that
# cannot be pointed at a deliberately broken copy has never been shown to
# fail, and a test that has never failed proves nothing.
STATUSLINE_UNDER_TEST="${STATUSLINE_UNDER_TEST:-$MODULE_DIR/canonical/statusline-command.sh}"
STATUSLINE="$STATUSLINE_UNDER_TEST"

t_begin "statusline-command.sh: .cc-mode is parsed, not sourced"

# =========================================================================
# WHY THIS FILE EXISTS
#
# The statusline is the only reader that ever treated .cc-mode as code, and it
# is the reader with the worst properties for that: it runs on EVERY repaint,
# its stdout is a decoration nobody reads closely, and its stderr goes
# wherever Claude Code sends it. A defect here is loud in effect and silent in
# presentation.
#
# INFRA-45 fixed the writer AND the reader, and the reason for doing both is
# exactly what this file tests. Encoding on write makes files THIS writer
# produces safe. It does nothing for a .cc-mode written by an older
# cc-functions.sh, edited by hand mid-debug, restored from a backup, or left
# in an ancestor directory by something else -- and the upward walk will
# happily find any of those. So every hostile fixture below is HAND-WRITTEN,
# never produced by __cc_write_mode_file. A test that only fed the statusline
# its own writer's output would be testing the fix that was already tested,
# and would pass just as well against the sourcing version.
#
# jq is a hard dependency of the statusline itself, so its absence skips this
# file rather than failing it -- the same call the shellcheck gate makes.
# =========================================================================

if ! command -v jq >/dev/null 2>&1; then
    t_diag "jq not installed - statusline tests skipped (the script requires it)."
    t_pass "statusline tests skipped (jq not installed)"
    t_finish
    exit $?
fi

# sl <dir> [ctx-pct] -- run the statusline as Claude Code runs it: JSON on
# stdin, one line of text out. ANSI sequences are stripped, because what is
# being asserted is the content of the line, not its colouring.
# SL_CWD is where these run FROM, which matters because mutate.sh points this
# file at a statusline that sources .cc-mode again: a hostile fixture holding a
# redirect would then create a file in the caller's directory, and the caller
# is usually the repository.
SL_CWD=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
sl() {
    local dir="$1" pct="${2:-12}"
    jq -nc --arg cwd "$dir" --argjson pct "$pct" \
        '{cwd:$cwd, model:{display_name:"Opus 5", id:"claude-opus-5"}, context_window:{used_percentage:$pct}}' \
    | ( cd "$SL_CWD" && sh "$STATUSLINE" 2>/dev/null ) \
    | sed -e 's/\x1b\[[0-9;]*m//g'
}

# sl_err <dir> -- the statusline's stderr. A parser that is silent on a file a
# sourcing reader would have choked on is half the claim being made.
sl_err() {
    jq -nc --arg cwd "$1" \
        '{cwd:$cwd, model:{display_name:"Opus 5", id:"claude-opus-5"}, context_window:{used_percentage:12}}' \
    | ( cd "$SL_CWD" && sh "$STATUSLINE" 2>&1 >/dev/null )
}

# =========================================================================
# 1. The ordinary path still works. Nothing below means anything if the
#    statusline stopped rendering the fields it exists to render.
# =========================================================================
D1=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
__cc_write_mode_file "$D1" branched INFRA-45 /home/u/repo sid pid \
    opus policy:branched-worker "" settings-default
out=$(sl "$D1")
assert_contains "renders the branched badge with its slug" "[BRANCH INFRA-45]" "$out"
assert_contains "renders the running model"                "[Opus 5]"          "$out"
assert_contains "renders the context percentage"           "(ctx 12%)"         "$out"
assert_not_contains "no drift marker when intent matches reality" "MODEL-DRIFT" "$out"
assert_eq "a clean .cc-mode produces no stderr" "" "$(sl_err "$D1")"

D1b=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
__cc_write_mode_file "$D1b" exploration adhoc /home/u/repo sid "" \
    sonnet policy:explore "" settings-default
out=$(sl "$D1b")
assert_contains "exploration badge"                     "[EXPLORE adhoc]"        "$out"
assert_contains "drift marker when intent != reality"   "MODEL-DRIFT(want sonnet)" "$out"

D1c=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
assert_contains "no .cc-mode anywhere upward renders the bare badge" \
    "[bare]" "$(sl "$D1c")"
assert_contains "CTX-WARN appears at 80%" "CTX-WARN" "$(sl "$D1c" 85)"
assert_not_contains "CTX-WARN absent below 80%" "CTX-WARN" "$(sl "$D1c" 79)"

# =========================================================================
# 2. HAND-WRITTEN hostile .cc-mode files. These are the ones the writer-side
#    fix cannot reach, and the reason the statusline had to stop sourcing.
# =========================================================================

# hostile <name> <cc-mode-body> -- write the body verbatim into a fresh dir,
# run the statusline, and assert three things at once: nothing was created,
# nothing was destroyed, and stderr stayed empty. @CANARY@ in the body is
# replaced with a path that does not exist; @VICTIM@ with one that does.
#
# Both directions are needed. A creation canary catches `touch`; it says
# nothing about `rm`, which is the shape that would actually cost something,
# and which would otherwise pass this helper by doing its damage silently.
#
# Leaves the rendered line in $SL_OUT for callers that want to check it.
SL_OUT=""
hostile() {
    local name="$1" body="$2" d canary victim err
    d=$(t_tmpdir) || { t_fail "tmpdir"; return 1; }
    canary="$d/EXECUTED"
    victim="$d/VICTIM"
    printf 'do not delete me\n' > "$victim"
    printf '%s\n' "${body//@CANARY@/$canary}" | sed "s|@VICTIM@|$victim|g" > "$d/.cc-mode"
    SL_OUT=$(sl "$d")
    err=$(sl_err "$d")
    local bad=""
    [ -e "$canary" ]  && bad="$bad EXECUTED(created)"
    [ -e "$victim" ]  || bad="$bad EXECUTED(destroyed)"
    [ -z "$err" ]     || bad="$bad stderr($(t_render "$err"))"
    if [ -z "$bad" ]; then
        t_pass "hostile .cc-mode: $name"
    else
        t_fail "hostile .cc-mode: $name" "failed:$bad" "file:" "$(cat "$d/.cc-mode")"
    fi
}

# The three defects, as files the writer would never emit but the walk can find.
hostile "a bare space blanks nothing" \
'mode=branched
slug=my thing
parent_repo=/home/u/repo
session_id=sid
model=opus'
assert_contains "  ... and the slug renders in full" "[BRANCH my thing]" "$SL_OUT"

hostile "an unbalanced double quote does not swallow the rest of the file" \
'mode=branched
slug=okslug
parent_repo=/tmp/we"ird
session_id=sid
model=opus'
assert_contains "  ... the field above survives"      "[BRANCH okslug]" "$SL_OUT"
assert_contains "  ... and the field BELOW it does too, which sourcing lost" \
    "[Opus 5]" "$SL_OUT"

hostile "a command substitution is not executed" \
'mode=branched
slug=okslug
parent_id=$(touch @CANARY@)
model=opus'

hostile "a backtick substitution is not executed" \
'mode=branched
slug=okslug
parent_id=`touch @CANARY@`
model=opus'

hostile "a command substitution IN A DISPLAYED FIELD is not executed" \
'mode=branched
slug=$(touch @CANARY@)
model=opus'

hostile "a bare command is not run" \
'mode=branched
slug=okslug
parent_repo=touch @CANARY@
model=opus'

hostile "a semicolon does not start a second command" \
'mode=branched
slug=x; touch @CANARY@
model=opus'

hostile "a redirect does not create a file" \
'mode=branched
slug=x > @CANARY@
model=opus'

hostile "an rm is not run (the shape that would have cost something)" \
'mode=branched
slug=okslug
parent_repo=$(rm -f @VICTIM@)
model=opus'

# Sourcing would have aborted the whole statusline here, since `exit` in a
# sourced file exits the sourcing shell.
hostile "an exit line does not truncate the statusline" \
'mode=branched
slug=okslug
exit 1
model=opus'
assert_contains "  ... the whole line still renders" "[BRANCH okslug]" "$SL_OUT"

# =========================================================================
# 3. The whitelist. Sourcing set every variable in the file, including ones
#    the statusline reads for other reasons. $debian_chroot is interpolated
#    straight into the rendered prompt, so a .cc-mode could write arbitrary
#    text into a display the operator trusts to describe their session.
# =========================================================================
D3=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
cat > "$D3/.cc-mode" <<'EOF'
mode=branched
slug=okslug
debian_chroot=INJECTED
cwd=/somewhere/else
HOME=/not/home
model=opus
EOF
out=$(sl "$D3")
assert_not_contains "an unknown key cannot reach the rendered line" "INJECTED" "$out"
assert_not_contains "an unknown key cannot overwrite \$cwd"         "/somewhere/else" "$out"
assert_contains     "the whitelisted keys still render"             "[BRANCH okslug]" "$out"

# =========================================================================
# 4. Decoding, from the reader's side. The statusline carries its own copy of
#    the unquote logic -- it is /bin/sh and cannot source cc-functions.sh on
#    every repaint -- so the two implementations are asserted to agree rather
#    than assumed to.
# =========================================================================
D4=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
for v in 'my feature' "it's here" 'a"b' 'a$(b)c' 'a`b`c' 'a${b}c' "quote'at'end'" \
         'a=b' 'a\b' '~/x' "all: a b'c\"d\$(e)f\`g\`h=i;j|k>l\\m"; do
    __cc_write_mode_file "$D4" branched "$v" /repo sid pid opus policy:x "" settings-default
    assert_contains "statusline decodes slug: $(t_render "$v")" \
        "[BRANCH $v]" "$(sl "$D4")"
done

# A pre-contract .cc-mode has bare values and must keep rendering as itself --
# including one that a naive "strip the outer quotes" decoder would corrupt.
D5=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
printf 'mode=branched\nslug=INFRA-39\nmodel=opus\n' > "$D5/.cc-mode"
assert_contains "a legacy bare .cc-mode still renders" "[BRANCH INFRA-39]" "$(sl "$D5")"

# A file with no trailing newline on its last line must not lose that line.
D6=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
printf 'mode=branched\nslug=notrailing' > "$D6/.cc-mode"
assert_contains "the last line is read even without a trailing newline" \
    "[BRANCH notrailing]" "$(sl "$D6")"

# The nearest .cc-mode wins, same as __cc_read_mode's walk.
D7=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
mkdir -p "$D7/a/b"
__cc_write_mode_file "$D7"     branched outer /repo sid pid opus policy:x "" settings-default
__cc_write_mode_file "$D7/a"   branched inner /repo sid pid opus policy:x "" settings-default
assert_contains "the nearest .cc-mode wins on the upward walk" \
    "[BRANCH inner]" "$(sl "$D7/a/b")"

t_finish
