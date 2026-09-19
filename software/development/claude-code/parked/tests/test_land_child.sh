#!/usr/bin/env bash
# Description: Behavioral tests for cc-land-child.sh (AI_ST-72) — merge + four-gate reclaim in one verified invocation, close-stall diagnosis and nudge, refusal paths, idempotency.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, git, coreutils

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

LAND="$MODULE_DIR/canonical/skills/company-status/scripts/cc-land-child.sh"

t_begin "cc-land-child.sh"

# =========================================================================
# WHY THIS FILE EXISTS (AI_ST-72, delegation.md §5-§7)
#
# Merge and window reclaim were 2 of the ~5 manual EA touches per child.
# cc-land-child.sh folds them into one invocation gated exactly like
# cc-reclaim-window.sh (whose own race guard has its own exercise script).
# These tests pin: the happy path costs zero manual steps; every gate
# refuses loudly; a conflicted merge aborts cleanly; the close-stall class
# (AI_ST-19's transcript menu) is diagnosed and nudgeable; nothing pushes.
# =========================================================================

SID_N=0

# mk_fixture <task-id> — builds $FX/{repo,repo-branch-<task>,tree}, a slot
# with status=completed, and a stub tmux whose 'company' session holds a
# window named <task-id>. Sets: FX, WT, SLOT, SID.
mk_fixture() {
    local task="$1"
    FX=$(t_tmpdir) || return 1
    SID_N=$((SID_N + 1))
    SID=$(printf 'f%021d' "$SID_N")
    mkdir -p "$FX/tree" "$FX/bin"

    ( cd "$FX" && git init -q repo \
        && cd repo \
        && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "init" \
        && git branch -M main \
        && git worktree add -q "../repo-branch-${task//\//-}" -b "branch/$task" \
        && cd "../repo-branch-${task//\//-}" \
        && echo work > work.txt && git add work.txt \
        && git -c user.email=t@t -c user.name=t commit -q -m "feat: child work for $task" )

    WT="$FX/repo-branch-${task//\//-}"
    printf 'mode=branched\nslug=%s\nsession_id=%s\n' "$task" "$SID" > "$WT/.cc-mode"

    SLOT="$FX/tree/$SID.md"
    cat > "$SLOT" <<EOF
---
session_id: $SID
parent_id:
task_id: $task
status: completed
started_at: 2026-09-03T18:00:00-04:00
ended_at: 2026-09-03T19:00:00-04:00
worktree: $WT
parent_repo: $FX/repo
---
EOF

    # tmux stub: list-windows/kill-window over a plain windows file;
    # capture-pane/send-keys reuse the state-file pattern; on-enter<N>.sh
    # hooks let a test act as the child reacting to a nudge.
    printf '%s\n' "$task" > "$FX/windows"
    printf 's0\n' > "$FX/state"
    : > "$FX/calls.log"
    cat > "$FX/bin/tmux" <<'STUBEOF'
#!/usr/bin/env bash
d="$TMUX_STUB_DIR"
printf '%s\n' "$*" >> "$d/calls.log"
case "$1" in
    list-windows) cat "$d/windows" ;;
    kill-window)
        # NOTE: ${*##pattern} strips per-parameter, not on the joined string;
        # take the last argument (the -t target) and strip its :=-prefix.
        for a in "$@"; do :; done
        name="${a##*:=}"
        grep -vFx "$name" "$d/windows" > "$d/windows.new" || true
        mv "$d/windows.new" "$d/windows" ;;
    capture-pane) cat "$d/pane-$(cat "$d/state").txt" 2>/dev/null ;;
    send-keys)
        if printf '%s\n' "$*" | grep -qw 'Enter'; then
            n=$(( $(cat "$d/enters" 2>/dev/null || echo 0) + 1 ))
            printf '%s\n' "$n" > "$d/enters"
            [ -f "$d/on-enter$n.sh" ] && bash "$d/on-enter$n.sh"
        fi ;;
esac
exit 0
STUBEOF
    chmod +x "$FX/bin/tmux"
}

# run_land <extra args...> — invoke against the current fixture.
run_land() {
    TMUX_STUB_DIR="$FX" PATH="$FX/bin:$PATH" CC_EA_LOG_FILE="$FX/ea.log" \
        bash "$LAND" --tree-dir "$FX/tree" --repo "$FX/repo" --tmux-session company "$@" 2>&1
}

# --- 1. happy path: one invocation, zero manual steps --------------------

mk_fixture T1 || exit 1
out=$(run_land T1)
assert_eq "happy path exits 0" 0 $?
assert_contains "verdict LANDED" "VERDICT: LANDED (merge=merged, reclaim=done)" "$out"
merge_subject=$(git -C "$FX/repo" log -1 --merges --format=%s)
assert_eq "merge commit on main, message from branch tip" \
    "Merge branch/T1: feat: child work for T1" "$merge_subject"
assert_eq "window killed" "0" "$(wc -l < "$FX/windows" | tr -d ' ')"
assert_contains "never pushes, and says so" "nothing was pushed" "$out"
assert_contains "trail: merge logged" "| merge | T1 |" "$(cat "$FX/ea.log")"
assert_contains "trail: reclaim logged" "| reclaim | T1 |" "$(cat "$FX/ea.log")"

# --- 2. idempotent rerun: already merged, window already gone ------------

out=$(run_land T1)
assert_eq "rerun exits 0" 0 $?
assert_contains "rerun: already an ancestor" "already an ancestor" "$out"
assert_eq "rerun: no second merge commit" "1" "$(git -C "$FX/repo" rev-list --merges --count main)"

# --- 3. dry run: verifies everything, changes nothing --------------------

mk_fixture T2 || exit 1
out=$(run_land --dry-run T2)
assert_eq "dry run exits 0" 0 $?
assert_contains "dry run announces the merge it would make" "WOULD MERGE" "$out"
assert_eq "dry run: no merge commit" "0" "$(git -C "$FX/repo" rev-list --merges --count main)"
assert_eq "dry run: window kept" "T2" "$(cat "$FX/windows")"

# --- 4. C1 refusal + close-stall diagnosis -------------------------------

mk_fixture T3 || exit 1
sed -i 's/^status: completed/status: running/' "$SLOT"
printf 'Keep this transcript in the vault?\n  1. Yes\n  2. No\n' > "$FX/pane-s0.txt"
out=$(run_land T3)
assert_eq "running child refused" 1 $?
assert_contains "C1 named" "C1" "$out"
assert_contains "transcript menu diagnosed" "TRANSCRIPT_MENU" "$out"
assert_eq "no merge happened" "0" "$(git -C "$FX/repo" rev-list --merges --count main)"
assert_eq "window untouched" "T3" "$(cat "$FX/windows")"

# --- 5. the nudge: Enter on the menu, child closes, landing proceeds -----

# Same fixture; the stub's on-enter1 hook plays the child finishing its
# close-out (slot flips to completed with ended_at) — AI_ST-19's exact
# scenario, resolved mechanically instead of by a sibling's pane scan.
cat > "$FX/on-enter1.sh" <<EOF
sed -i 's/^status: running/status: completed/' "$SLOT"
EOF
out=$(run_land --nudge --nudge-wait 10 T3)
assert_eq "nudged landing exits 0" 0 $?
assert_contains "nudge sent the menu default" "sent Enter (menu default)" "$out"
assert_contains "slot flipped after nudge" "after nudge" "$out"
assert_eq "merged after nudge" "1" "$(git -C "$FX/repo" rev-list --merges --count main)"
assert_contains "trail: nudge logged" "| nudge | T3 |" "$(cat "$FX/ea.log")"

# --- 6. /end stall gets the Skill-tool instruction, not a blind Enter ----

mk_fixture T4 || exit 1
sed -i 's/^status: completed/status: running/' "$SLOT"
printf 'Unknown command: /end. Did you mean /cd?\n❯ \n' > "$FX/pane-s0.txt"
out=$(run_land --nudge --nudge-wait 5 T4)   # slot never flips; refusal expected
assert_eq "unresolved /end stall still refuses" 1 $?
assert_contains "instruction was sent" "Skill-tool instruction" "$out"
assert_contains "the literal guidance names the skill" "end-conversation" "$(cat "$FX/calls.log")"

# --- 7. C2 refusal: dirty child worktree ---------------------------------

mk_fixture T5 || exit 1
echo dirty >> "$WT/work.txt"
out=$(run_land T5)
assert_eq "dirty worktree refused" 1 $?
assert_contains "C2 named" "C2" "$out"

# --- 8. dirty MAIN worktree refused (unless --allow-dirty-main) ----------

mk_fixture T6 || exit 1
echo stray > "$FX/repo/stray.txt"
out=$(run_land T6)
assert_eq "dirty main refused" 1 $?
assert_contains "names the escape hatch" "--allow-dirty-main" "$out"
out=$(run_land --allow-dirty-main T6)
assert_eq "--allow-dirty-main proceeds" 0 $?

# --- 9. wrong branch checked out on main worktree ------------------------

mk_fixture T7 || exit 1
git -C "$FX/repo" checkout -q -b elsewhere
out=$(run_land T7)
assert_eq "non-main checkout refused" 1 $?
assert_contains "says what is checked out" "elsewhere" "$out"

# --- 10. conflicted merge: aborted, main left clean ----------------------

mk_fixture T8 || exit 1
( cd "$FX/repo" && echo conflict > work.txt && git add work.txt \
    && git -c user.email=t@t -c user.name=t commit -q -m "conflicting main work" )
out=$(run_land T8)
assert_eq "conflict refused" 1 $?
assert_contains "conflict reported with the by-hand command" "merge --no-ff" "$out"
assert_eq "merge aborted: main worktree clean" "" "$(git -C "$FX/repo" status --porcelain)"
assert_eq "no half-merge commit" "0" "$(git -C "$FX/repo" rev-list --merges --count main)"

# --- 11. --no-reclaim: merge only ----------------------------------------

mk_fixture T9 || exit 1
out=$(run_land --no-reclaim T9)
assert_eq "--no-reclaim exits 0" 0 $?
assert_contains "window kept on purpose" "window kept" "$out"
assert_eq "window still present" "T9" "$(cat "$FX/windows")"
assert_eq "but the merge happened" "1" "$(git -C "$FX/repo" rev-list --merges --count main)"

# --- 12. C4: reused worktree owned by a different task -------------------

mk_fixture TA || exit 1
sed -i 's/^task_id: TA/task_id: OTHER/' "$SLOT"
out=$(run_land TA)
assert_eq "reused worktree refused" 1 $?
assert_contains "C4 named" "C4" "$out"

t_finish
