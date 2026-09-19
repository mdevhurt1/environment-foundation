#!/usr/bin/env bash
# cc-reclaim-exercise.sh — self-contained validation harness for the reclaim gate.
#
# WHY THIS EXISTS
# ---------------
# The session that wrote cc-reclaim-window.sh could not execute it even once:
# AF_UNIX sockets are blocked at the syscall in the authoring sandbox, so every
# tmux call returns "error connecting to /tmp/tmux-1000/default (Operation not
# permitted)". (systemctl --user and obsidian-cli fail identically, for the same
# reason and unrelated to any of those services.) The gate logic was therefore
# written as unverifiable-in-production code, and this harness is how it gets
# verified — by an operator with a real tmux server.
#
# It builds a THROWAWAY world: a temp git repo, temp worktrees, a temp tree
# directory, and its own tmux session. It never reads or writes the real
# ~/vault tree and never touches the `company` tmux session.
#
# RUN IT:
#   bash ~/.claude/skills/company-status/scripts/cc-reclaim-exercise.sh
#
# Expected final line on success:
#   ALL 8 CASES PASSED
#
# Anything else is a real defect in cc-reclaim-window.sh. Each case prints the
# exact assertion it made, so a failure names the condition that regressed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECLAIM="$HERE/cc-reclaim-window.sh"
[ -f "$RECLAIM" ] || { echo "FATAL: cc-reclaim-window.sh not found next to this script"; exit 2; }

SESSION="cc-reclaim-exercise-$$"
TMP="$(mktemp -d -t cc-reclaim-exercise-XXXXXX)"
TREE="$TMP/tree"
REPOS="$TMP/repos"
mkdir -p "$TREE" "$REPOS"

pass_n=0; fail_n=0; case_n=0

cleanup() {
    tmux kill-session -t "$SESSION" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

# ------------------------------------------------------------- preflight ---
echo "== preflight =="
command -v tmux >/dev/null 2>&1 || { echo "FATAL: tmux is not installed."; exit 2; }
if ! tmux new-session -d -s "$SESSION" -n base 'sleep 100000' 2>/dev/null; then
    echo "FATAL: cannot start a tmux session."
    echo "  If this says 'Operation not permitted' you are inside the sandbox that"
    echo "  blocks AF_UNIX. Run this harness from a normal terminal instead."
    tmux new-session -d -s "$SESSION" -n base 'sleep 100000'   # re-run to show the error
    exit 2
fi
echo "tmux ok — exercise session: $SESSION"
echo "scratch: $TMP"
echo

G() { git -c user.email=x@y -c user.name=x -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }

# mk_repo <name> — a repo with one commit on main
mk_repo() {
    local r="$REPOS/$1"
    mkdir -p "$r"; G -C "$r" init -q
    echo seed > "$r/seed.txt"; G -C "$r" add -A; G -C "$r" commit -qm seed
    printf '%s' "$r"
}

# mk_child <repo> <task> <slot_session> <ccmode_session> <status> <ended_at> <dirty> <merged>
#   Creates the branch worktree, its .cc-mode, its tree slot, and a tmux window.
#   slot_session and ccmode_session are separate on purpose: case 6 needs them
#   to disagree, which is exactly the worktree-reuse trap.
mk_child() {
    local repo="$1" task="$2" slot_sid="$3" ccm_sid="$4" status="$5" ended="$6" dirty="$7" merged="$8"
    # Separate statements on purpose: `local a=$x b=$a` expands every word
    # BEFORE the builtin assigns any of them, so $safe would be unbound here.
    local safe="${task//\//-}"
    local wt="$REPOS/$(basename "$repo")-branch-$safe"
    G -C "$repo" worktree add -q -b "branch/$task" "$wt" >/dev/null 2>&1
    echo "work-$task" > "$wt/work.txt"; G -C "$wt" add -A; G -C "$wt" commit -qm "work $task"
    [ "$merged" = "1" ] && G -C "$repo" merge -q --no-ff -m "merge $task" "branch/$task" >/dev/null 2>&1
    [ "$dirty" = "1" ] && echo scratch > "$wt/uncommitted.txt"

    cat > "$wt/.cc-mode" <<EOF
mode=branched
slug=$task
started_at=2026-09-03T00:00:00-04:00
parent_repo=$repo
session_id=$ccm_sid
parent_id=aaaaaaaaaaaaaaaaaaaaaa
EOF
    cat > "$TREE/${slot_sid}.md" <<EOF
---
session_id: $slot_sid
parent_id: aaaaaaaaaaaaaaaaaaaaaa
task_id: $task
slug: $task
mode: branched
status: $status
started_at: 2026-09-03T00:00:00-04:00
ended_at: $ended
worktree: $wt
parent_repo: $repo
---
EOF
    mkdir -p "$TREE/${slot_sid}.events"
    tmux new-window -d -t "$SESSION" -n "$task" -c "$wt" 'sleep 100000' 2>/dev/null
    printf '%s' "$wt"
}

run_gate() { bash "$RECLAIM" --tree-dir "$TREE" --tmux-session "$SESSION" --no-fetch "$@" 2>&1; }

# Capture-then-herestring, not a pipe: grep -Fxq is an early-exit consumer
# and this script sets pipefail (doctor.sh check 9).
win_exists() { local w; w=$(tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null); grep -Fxq "$1" <<<"$w"; }

# check <case-name> <expectation-text> <condition-result 0|1> <output>
check() {
    case_n=$((case_n+1))
    echo "-- CASE $case_n: $1"
    echo "   expect: $2"
    if [ "$3" -eq 0 ]; then
        echo "   RESULT: PASS"; pass_n=$((pass_n+1))
    else
        echo "   RESULT: FAIL"; fail_n=$((fail_n+1))
        printf '%s\n' "$4" | sed 's/^/     | /'
    fi
    echo
}

# =========================================================== CASE 1: pass ===
R1=$(mk_repo p1)
mk_child "$R1" T-PASS 1111111111111111111111 1111111111111111111111 completed 2026-09-03T01:00:00-04:00 0 1 >/dev/null
out=$(run_gate --repo "$R1" --kill T-PASS); rc=$?
ok=1
if grep -q "VERDICT: RECLAIMED" <<<"$out" && [ "$rc" -eq 0 ] && ! win_exists T-PASS; then ok=0; fi
check "all four conditions hold" \
      "VERDICT: RECLAIMED, exit 0, window gone" "$ok" "$out"

# ==================================== CASE 2: C1 — slot still says running ===
R2=$(mk_repo p2)
mk_child "$R2" T-RUNNING 2222222222222222222222 2222222222222222222222 running "" 0 1 >/dev/null
out=$(run_gate --repo "$R2" --kill T-RUNNING); rc=$?
ok=1
if grep -q "C1 status   : FAIL" <<<"$out" \
   && grep -q "VERDICT: REFUSED" <<<"$out" \
   && [ "$rc" -eq 1 ] && win_exists T-RUNNING; then ok=0; fi
check "C1 — status=running (the 2026-08-15 failure)" \
      "C1 FAIL, VERDICT: REFUSED, exit 1, window KEPT" "$ok" "$out"

# ============================ CASE 3: C1 — terminal but ended_at is empty ====
R3=$(mk_repo p3)
mk_child "$R3" T-NOEND 3333333333333333333333 3333333333333333333333 completed "" 0 1 >/dev/null
out=$(run_gate --repo "$R3" --kill T-NOEND); rc=$?
ok=1
if grep -q "ended_at is EMPTY" <<<"$out" && [ "$rc" -eq 1 ] && win_exists T-NOEND; then ok=0; fi
check "C1 — completed but ended_at unset (close-out mid-write)" \
      "'ended_at is EMPTY', exit 1, window KEPT" "$ok" "$out"

# ================================================= CASE 4: C2 — dirty tree ===
R4=$(mk_repo p4)
mk_child "$R4" T-DIRTY 4444444444444444444444 4444444444444444444444 completed 2026-09-03T01:00:00-04:00 1 1 >/dev/null
out=$(run_gate --repo "$R4" --kill T-DIRTY); rc=$?
ok=1
if grep -q "C2 clean    : FAIL" <<<"$out" && [ "$rc" -eq 1 ] && win_exists T-DIRTY; then ok=0; fi
check "C2 — worktree has uncommitted changes" \
      "C2 FAIL listing the dirty path, exit 1, window KEPT" "$ok" "$out"

# ================================================== CASE 5: C3 — unmerged ====
R5=$(mk_repo p5)
mk_child "$R5" T-UNMERGED 5555555555555555555555 5555555555555555555555 completed 2026-09-03T01:00:00-04:00 0 0 >/dev/null
out=$(run_gate --repo "$R5" --kill T-UNMERGED); rc=$?
ok=1
if grep -q "C3 merged   : FAIL" <<<"$out" \
   && grep -q "deliberately unmerged" <<<"$out" \
   && [ "$rc" -eq 1 ] && win_exists T-UNMERGED; then ok=0; fi
check "C3 — branch not merged into main" \
      "C3 FAIL + 'deliberately unmerged' note, exit 1, window KEPT" "$ok" "$out"

# ========================= CASE 6: C4 — worktree reused, stale slot decoy ====
# The exact near-miss: task_id T-REUSED names TWO slots. The old one (6a) is
# completed+merged+clean and would sail through a task_id-first resolution. The
# worktree's .cc-mode names the CURRENT session (6b), which is still running.
# Correct behaviour: resolve via .cc-mode to 6b, refuse on C1, keep the window.
R6=$(mk_repo p6)
mk_child "$R6" T-REUSED 6666666666666666666666 6b6b6b6b6b6b6b6b6b6b6b running "" 0 1 >/dev/null
cat > "$TREE/6a6a6a6a6a6a6a6a6a6a6a.md" <<EOF
---
session_id: 6a6a6a6a6a6a6a6a6a6a6a
parent_id: aaaaaaaaaaaaaaaaaaaaaa
task_id: T-REUSED
slug: T-REUSED
mode: branched
status: abandoned
started_at: 2026-09-02T00:00:00-04:00
ended_at: 2026-09-02T05:00:00-04:00
worktree: $REPOS/p6-branch-T-REUSED
parent_repo: $R6
---
EOF
# The live session's own slot, keyed by the .cc-mode session_id.
cat > "$TREE/6b6b6b6b6b6b6b6b6b6b6b.md" <<EOF
---
session_id: 6b6b6b6b6b6b6b6b6b6b6b
parent_id: aaaaaaaaaaaaaaaaaaaaaa
task_id: T-REUSED
slug: T-REUSED
mode: branched
status: running
started_at: 2026-09-03T00:00:00-04:00
ended_at:
worktree: $REPOS/p6-branch-T-REUSED
parent_repo: $R6
---
EOF
rm -f "$TREE/6666666666666666666666.md"
out=$(run_gate --repo "$R6" --kill T-REUSED); rc=$?
ok=1
if grep -q "cc-mode sid : 6b6b6b6b6b6b6b6b6b6b6b" <<<"$out" \
   && grep -q "6a6a6a6a6a6a6a6a6a6a6a(abandoned)" <<<"$out" \
   && grep -q "C1 status   : FAIL" <<<"$out" \
   && [ "$rc" -eq 1 ] && win_exists T-REUSED; then ok=0; fi
check "C4 — worktree reused; a stale completed slot shares the task_id" \
      "resolves to the .cc-mode session (6b…), names the decoy (6a…) as unused, C1 FAIL, window KEPT" \
      "$ok" "$out"

# ============================ CASE 7: numeric task_id must not hit an index ===
# A decoy window is created FIRST so that a task named "42" cannot be confused
# with window index 42; the gate must address by name only and leave the decoy.
R7=$(mk_repo p7)
tmux new-window -d -t "$SESSION" -n decoy-index 'sleep 100000' 2>/dev/null
mk_child "$R7" 42 7777777777777777777777 7777777777777777777777 completed 2026-09-03T01:00:00-04:00 0 1 >/dev/null
out=$(run_gate --repo "$R7" --kill 42); rc=$?
ok=1
if grep -q "VERDICT: RECLAIMED" <<<"$out" \
   && ! win_exists 42 && win_exists decoy-index && [ "$rc" -eq 0 ]; then ok=0; fi
check "numeric task_id '42' addressed by name, not as window index 42" \
      "window '42' reclaimed, decoy window untouched" "$ok" "$out"

# ======================== CASE 8: race — slot flips between gate and kill =====
# The pre-kill hook rewrites the slot to running after the gate passes. The
# final re-read must catch it and abort. This is the guard that the 2026-08-15
# two-batch failure had no equivalent of.
R8=$(mk_repo p8)
mk_child "$R8" T-RACE 8888888888888888888888 8888888888888888888888 completed 2026-09-03T01:00:00-04:00 0 1 >/dev/null
out=$(CC_RECLAIM_TEST_PRE_KILL_HOOK="sed -i 's/^status: completed/status: running/' '$TREE/8888888888888888888888.md'" \
      run_gate --repo "$R8" --kill T-RACE); rc=$?
ok=1
if grep -q "VERDICT: ABORTED (race caught)" <<<"$out" \
   && [ "$rc" -eq 4 ] && win_exists T-RACE; then ok=0; fi
check "race — slot flips to running after the gate passes" \
      "VERDICT: ABORTED (race caught), exit 4, window KEPT" "$ok" "$out"

# ------------------------------------------------------------------ result --
echo "=============================================================="
if [ "$fail_n" -eq 0 ]; then
    echo "ALL $case_n CASES PASSED"
    exit 0
else
    echo "$fail_n of $case_n CASES FAILED"
    exit 1
fi
