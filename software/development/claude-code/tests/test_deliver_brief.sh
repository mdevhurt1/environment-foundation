#!/usr/bin/env bash
# Description: Behavioral tests for __cc_deliver_brief and cc-branch --brief plumbing (AI_ST-72/AI_ST-40) — the paste-verify-Enter dance against a scripted tmux stub.
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

CCF="$MODULE_DIR/canonical/shell/cc-functions.sh"

t_begin "__cc_deliver_brief / cc-branch --brief"

# =========================================================================
# WHY THIS FILE EXISTS (AI_ST-72; design record AI_ST-40)
#
# Brief delivery was the EA's most repeated manual touch: load-buffer,
# paste-buffer, wait, capture-pane, Enter — ten times on 2026-09-03. The
# dance is mechanized in __cc_deliver_brief; what these tests pin is the
# ORDER (verify BEFORE Enter — a blind Enter into an unverified pane is the
# forbidden move), the paste-then-Enter race mitigation (one extra Enter,
# exactly once), and that every failure path refuses rather than guesses.
# The tmux binary is a scripted stub: state transitions on paste/Enter,
# canned capture-pane output per state.
# =========================================================================

# --- the tmux stub -------------------------------------------------------

STUB=$(t_tmpdir) || exit 1
mkdir -p "$STUB/bin"
cat > "$STUB/bin/tmux" <<'STUBEOF'
#!/usr/bin/env bash
d="$TMUX_STUB_DIR"
printf '%s\n' "$*" >> "$d/calls.log"
case "$1" in
    capture-pane)
        cat "$d/pane-$(cat "$d/state").txt" 2>/dev/null
        ;;
    load-buffer) ;;
    paste-buffer)
        [ -f "$d/on-paste" ] && cp "$d/on-paste" "$d/state"
        ;;
    send-keys)
        if printf '%s\n' "$*" | grep -qw 'Enter'; then
            n=$(( $(cat "$d/enters" 2>/dev/null || echo 0) + 1 ))
            printf '%s\n' "$n" > "$d/enters"
            [ -f "$d/on-enter$n" ] && cp "$d/on-enter$n" "$d/state"
        fi
        ;;
esac
exit 0
STUBEOF
chmod +x "$STUB/bin/tmux"

BRIEF="$STUB/brief.md"
printf '# Brief — TASK-1 (autonomous)\n\nline two\nline three\n' > "$BRIEF"

# reset_stub <initial-state>
reset_stub() {
    rm -f "$STUB"/on-paste "$STUB"/on-enter* "$STUB"/pane-*.txt "$STUB"/calls.log "$STUB"/enters
    printf '%s\n' "$1" > "$STUB/state"
    : > "$STUB/calls.log"
}

# run_deliver — invoke __cc_deliver_brief in a subshell with the stub tmux
# first in PATH and fast timings. Prints stderr; exit code is the verdict.
run_deliver() {
    ( export TMUX_STUB_DIR="$STUB" PATH="$STUB/bin:$PATH" \
             CC_BRIEF_SETTLE=0 CC_BRIEF_POLL=1 CC_BRIEF_READY_TIMEOUT="${READY_TIMEOUT:-5}"
      # shellcheck disable=SC1090
      source "$CCF" >/dev/null 2>&1
      __cc_deliver_brief 'company:=TASK-1' "$BRIEF" 2>&1 )
}

READY_PANE=$'some transcript\n╭──────╮\n❯ \n╰──────╯\n⏵⏵ auto mode on'
PASTED_PANE=$'some transcript\n❯ [Pasted text #1 +3 lines]\n⏵⏵ auto mode on'
SUBMITTED_PANE=$'# Brief — TASK-1 (autonomous)\n✻ Running…\n❯ \n⏵⏵ auto mode on'

# --- 1. happy path: ready -> paste -> verify -> ONE Enter ----------------

reset_stub s0
printf '%s' "$READY_PANE"     > "$STUB/pane-s0.txt"
printf '%s' "$PASTED_PANE"    > "$STUB/pane-s1.txt"
printf '%s' "$SUBMITTED_PANE" > "$STUB/pane-s2.txt"
printf 's1' > "$STUB/on-paste"
printf 's2' > "$STUB/on-enter1"

out=$(run_deliver)
assert_eq "happy path: returns 0" 0 $?
assert_contains "reports delivered+submitted" "delivered and submitted" "$out"
assert_eq "exactly one Enter sent" "1" "$(cat "$STUB/enters")"
calls=$(grep -n . "$STUB/calls.log")
load_at=$(printf '%s\n' "$calls" | grep -m1 'load-buffer' | cut -d: -f1)
paste_at=$(printf '%s\n' "$calls" | grep -m1 'paste-buffer' | cut -d: -f1)
enter_at=$(printf '%s\n' "$calls" | grep -m1 'send-keys' | cut -d: -f1)
if [ -n "$load_at" ] && [ -n "$paste_at" ] && [ -n "$enter_at" ] \
   && [ "$load_at" -lt "$paste_at" ] && [ "$paste_at" -lt "$enter_at" ]; then
    t_pass "order: load-buffer < paste-buffer < Enter"
else
    t_fail "order: load-buffer < paste-buffer < Enter" "calls: $calls"
fi
assert_contains "paste uses a named buffer, deleted after use" "paste-buffer -d -b cc-brief" "$(cat "$STUB/calls.log")"

# --- 2. window never becomes ready: refuse, touch nothing ----------------

reset_stub s0
printf 'still launching...' > "$STUB/pane-s0.txt"

out=$(READY_TIMEOUT=1 run_deliver)
assert_eq "no prompt: returns 1" 1 $?
assert_contains "no prompt: names the by-hand commands" "by hand" "$out"
assert_not_contains "no prompt: nothing was pasted" "paste-buffer" "$(cat "$STUB/calls.log")"
assert_eq "no prompt: no Enter sent" "no" "$( [ -f "$STUB/enters" ] && echo yes || echo no )"

# --- 3. paste-then-Enter race: input line still holds paste -> ONE more Enter

reset_stub s0
printf '%s' "$READY_PANE"     > "$STUB/pane-s0.txt"
printf '%s' "$PASTED_PANE"    > "$STUB/pane-s1.txt"
printf '%s' "$PASTED_PANE"    > "$STUB/pane-s2.txt"   # Enter #1 swallowed
printf '%s' "$SUBMITTED_PANE" > "$STUB/pane-s3.txt"   # Enter #2 lands
printf 's1' > "$STUB/on-paste"
printf 's2' > "$STUB/on-enter1"
printf 's3' > "$STUB/on-enter2"

out=$(run_deliver)
assert_eq "race path: returns 0" 0 $?
assert_eq "race path: exactly two Enters" "2" "$(cat "$STUB/enters")"

# --- 4. race persists after the retry Enter: refuse loudly ----------------

reset_stub s0
printf '%s' "$READY_PANE"  > "$STUB/pane-s0.txt"
printf '%s' "$PASTED_PANE" > "$STUB/pane-s1.txt"
printf 's1' > "$STUB/on-paste"
# no on-enter transitions: the placeholder never clears

out=$(run_deliver)
assert_eq "stuck submit: returns 1" 1 $?
assert_contains "stuck submit: tells the EA the one key to press" "send-keys" "$out"
assert_eq "stuck submit: stopped after the documented single retry" "2" "$(cat "$STUB/enters")"

# --- 5. paste never verifies: retry once, then refuse WITHOUT Enter ------

reset_stub s0
printf '%s' "$READY_PANE" > "$STUB/pane-s0.txt"
printf '%s' "$READY_PANE" > "$STUB/pane-s1.txt"   # pane never shows the paste
printf 's1' > "$STUB/on-paste"

out=$(run_deliver)
assert_eq "unverified paste: returns 1" 1 $?
assert_eq "unverified paste: pasted twice (one retry)" "2" \
    "$(grep -c '^paste-buffer' "$STUB/calls.log")"
assert_eq "unverified paste: Enter NEVER sent blind" "no" "$( [ -f "$STUB/enters" ] && echo yes || echo no )"

# --- 6. single-line brief: verified via its own first line ---------------

reset_stub s0
printf 'Do the thing per spec X.\n' > "$BRIEF"
TYPED_PANE=$'transcript\n❯ Do the thing per spec X.\n⏵⏵ auto mode on'
printf '%s' "$READY_PANE"     > "$STUB/pane-s0.txt"
printf '%s' "$TYPED_PANE"     > "$STUB/pane-s1.txt"
printf '%s' "$SUBMITTED_PANE" > "$STUB/pane-s2.txt"
printf 's1' > "$STUB/on-paste"
printf 's2' > "$STUB/on-enter1"

out=$(run_deliver)
assert_eq "single-line brief: verified via probe text, returns 0" 0 $?

# --- 7. pane helpers, direct ---------------------------------------------

# shellcheck disable=SC1090
source "$CCF" >/dev/null 2>&1
if __cc_pane_ready "$READY_PANE" && ! __cc_pane_ready "still launching"; then
    t_pass "__cc_pane_ready keys on the prompt marker"
else
    t_fail "__cc_pane_ready keys on the prompt marker"
fi
# Text already scrolled into the transcript must NOT read as held paste.
if __cc_pane_holds_paste "$PASTED_PANE" "# Brief — TASK-1" \
   && ! __cc_pane_holds_paste "$SUBMITTED_PANE" "# Brief — TASK-1"; then
    t_pass "__cc_pane_holds_paste consults only the prompt line"
else
    t_fail "__cc_pane_holds_paste consults only the prompt line"
fi

# --- 8. cc-branch: --brief validated BEFORE side effects -----------------

D=$(t_tmpdir) || exit 1
mkdir -p "$D/repo"
( cd "$D/repo" && git init -q . && git commit -q --allow-empty -m init )
out=$( cd "$D/repo" && bash -c '
    source "'"$CCF"'" >/dev/null 2>&1
    cc-branch --brief /nonexistent-brief.md sometask 2>&1'
)
rc=$?
assert_ne "missing brief file refused" 0 "$rc"
assert_contains "refusal names the file" "brief file not found" "$out"
assert_eq "no worktree left behind" "no" "$( [ -d "$D/repo-branch-sometask" ] && echo yes || echo no )"

out=$( cd "$D/repo" && bash -c '
    source "'"$CCF"'" >/dev/null 2>&1
    cc-branch --bogus-flag sometask 2>&1'
)
rc=$?
assert_ne "unknown option refused" 0 "$rc"
assert_contains "usage names --brief" "--brief" "$out"

t_finish
