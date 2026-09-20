#!/usr/bin/env bash
# cc-reclaim-window.sh — verify the four reclaim conditions and kill a finished
# child's tmux window, ATOMICALLY, in one process.
#
# Part 2 of the company-status skill.
#
# ---------------------------------------------------------------------------
# WHY THIS IS A SCRIPT AND NOT A CHECKLIST
# ---------------------------------------------------------------------------
# On 2026-08-15 the EA killed ENPM808-92's window while its slot still read
# `running`. Nothing was wrong with the four conditions themselves — they were
# checked across TWO command batches, and the slot re-check was skipped in the
# batch that did the kill. The child was mid-/end; its memory delta was lost.
#
# A checklist cannot fix that, because the failure was the GAP between the
# check and the act. So the gate and the kill live in one process, and the
# slot's status line — condition 1 — is read as the LAST thing before the kill
# and re-read once more immediately before the tmux call. Never from a
# completion event, never from a scan a minute old.
#
# ---------------------------------------------------------------------------
# THE FOUR CONDITIONS (all must hold, verified here, in this run)
# ---------------------------------------------------------------------------
#   C1  slot status is completed | ended-by-user | abandoned AND ended_at set
#   C2  worktree is clean (git status --porcelain empty)
#   C3  branch is merged into main (git merge-base --is-ancestor)
#   C4  session_id in the worktree's .cc-mode matches the slot being checked
#
# C4 is not merely a check — it is how the slot is RESOLVED. Worktrees are
# reused across sessions, so a task_id can name several slots (one per session
# that ever used it). Resolving by task_id alone once picked up an abandoned
# session from earlier the same day and would have reclaimed a live window.
# Here: worktree -> .cc-mode session_id -> slot. Then we assert the slot's
# task_id is the one asked for, and report any OTHER slots sharing that
# task_id so the near-miss is visible rather than silent.
#
# ---------------------------------------------------------------------------
# WINDOW ADDRESSING
# ---------------------------------------------------------------------------
# Windows are addressed by NAME with tmux's `=` exact-match prefix
# (`company:=TASK`), never by index. Indices renumber on every close — closing
# five windows once renumbered the two survivors — and a purely numeric
# task_id like "42" would be parsed as index 42 without the `=`.
#
# Usage:
#   cc-reclaim-window.sh [options] <task-id> [<task-id> ...]
#
#   Dry-run by default. Nothing is killed without --kill.
#
# Exit codes: 0 all requested tasks passed the gate (and were killed if --kill)
#             1 at least one task was REFUSED by the gate
#             2 usage error
#             4 a kill was aborted by the final pre-kill re-read (race caught)

set -uo pipefail

usage() {
    cat <<'USAGE'
usage: cc-reclaim-window.sh [options] <task-id> [<task-id> ...]

  --kill                 Actually close windows that pass all four conditions.
                         Omitted, the script only reports the verdict.
  --repo <path>          Repo the child was branched from. Used to derive the
                         worktree path the way cc-branch does. Repeatable;
                         each task is tried against each repo.
  --worktree <path>      Explicit worktree for a single task (skips derivation).
  --main-ref <ref>       Ref that counts as "main" (default: main, then master).
  --tree-dir <path>      Tree sessions dir (default ~/vault/20-surface/company/tree/sessions)
  --tmux-session <name>  tmux session holding the windows (default: company)
  --no-fetch             Skip `git fetch` before the merge check.
  -h, --help             Show this help.

Test-only seam: $CC_RECLAIM_TEST_PRE_KILL_HOOK, if set, is eval'd after the
gate passes and before the final status re-read. cc-reclaim-exercise.sh uses
it to prove the race guard fires. Never set it in normal operation.
USAGE
}

TREE_DIR="$HOME/vault/20-surface/company/tree/sessions"
TMUX_SESSION="company"
DO_KILL=0
DO_FETCH=1
MAIN_REF=""
EXPLICIT_WT=""
REPOS=()
TASKS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --kill) DO_KILL=1; shift ;;
        --no-fetch) DO_FETCH=0; shift ;;
        --repo) REPOS+=("$2"); shift 2 ;;
        --repo=*) REPOS+=("${1#*=}"); shift ;;
        --worktree) EXPLICIT_WT="$2"; shift 2 ;;
        --worktree=*) EXPLICIT_WT="${1#*=}"; shift ;;
        --main-ref) MAIN_REF="$2"; shift 2 ;;
        --main-ref=*) MAIN_REF="${1#*=}"; shift ;;
        --tree-dir) TREE_DIR="$2"; shift 2 ;;
        --tree-dir=*) TREE_DIR="${1#*=}"; shift ;;
        --tmux-session) TMUX_SESSION="$2"; shift 2 ;;
        --tmux-session=*) TMUX_SESSION="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
        *) TASKS+=("$1"); shift ;;
    esac
done

[ ${#TASKS[@]} -eq 0 ] && { echo "ERROR: no task-id given" >&2; usage >&2; exit 2; }
[ -n "$EXPLICIT_WT" ] && [ ${#TASKS[@]} -gt 1 ] && {
    echo "ERROR: --worktree applies to a single task-id" >&2; exit 2; }

# Default repo set: every repo that has a worktree registered. Derived from the
# tree slots themselves so the caller usually needs no --repo at all.
if [ ${#REPOS[@]} -eq 0 ]; then
    while IFS= read -r r; do [ -n "$r" ] && REPOS+=("$r"); done < <(
        { grep -h '^parent_repo:' "$TREE_DIR"/*.md 2>/dev/null || true; } \
        | sed 's/^parent_repo:[[:space:]]*//' | sort -u)
fi

fm() { { grep -m1 "^$2:" "$1" 2>/dev/null || true; } | sed "s/^$2:[[:space:]]*//"; }

# read_slot_status <slot> -> "status|ended_at"  — always a FRESH read from disk.
read_slot_status() { printf '%s|%s' "$(fm "$1" status)" "$(fm "$1" ended_at)"; }

overall=0
raced=0

for task_id in "${TASKS[@]}"; do
    echo "=============================================================="
    echo "RECLAIM GATE — task_id: $task_id"
    echo "=============================================================="
    fail=""

    # ---------------------------------------------------- resolve worktree --
    wt=""
    if [ -n "$EXPLICIT_WT" ]; then
        wt="$EXPLICIT_WT"
    else
        task_id_safe="${task_id//\//-}"
        for repo in "${REPOS[@]}"; do
            [ -d "$repo" ] || continue
            cand="${repo%/*}/$(basename "$repo")-branch-${task_id_safe}"
            [ -d "$cand" ] && { wt="$cand"; break; }
        done
    fi
    if [ -z "$wt" ] || [ ! -d "$wt" ]; then
        echo "REFUSED: no worktree found for '$task_id'"
        echo "  tried the cc-branch pattern <repo-parent>/<repo>-branch-${task_id//\//-} against:"
        printf '    %s\n' "${REPOS[@]+"${REPOS[@]}"}"
        echo "  pass --worktree <path> if it lives elsewhere."
        echo "VERDICT: REFUSED (unresolvable worktree)"; echo
        overall=1; continue
    fi
    echo "worktree    : $wt"

    # ------------------------------- C4 (as resolver): worktree -> slot ------
    # Done FIRST because it determines which slot the other three conditions
    # are even about. Resolving by task_id here instead is the 2026-08 bug.
    if [ ! -f "$wt/.cc-mode" ]; then
        echo "REFUSED: no .cc-mode in $wt — cannot establish which session owns this worktree."
        echo "VERDICT: REFUSED (C4)"; echo; overall=1; continue
    fi
    ccm_id=$( { grep '^session_id=' "$wt/.cc-mode" || true; } | cut -d= -f2-)
    if [ -z "$ccm_id" ]; then
        echo "REFUSED: .cc-mode in $wt has no session_id."
        echo "VERDICT: REFUSED (C4)"; echo; overall=1; continue
    fi
    slot="$TREE_DIR/${ccm_id}.md"
    echo "cc-mode sid : $ccm_id"
    echo "slot        : $slot"
    if [ ! -f "$slot" ]; then
        echo "REFUSED: no slot file for the session that owns this worktree."
        echo "  The .cc-mode names $ccm_id but $TREE_DIR has no slot for it."
        echo "VERDICT: REFUSED (C4)"; echo; overall=1; continue
    fi

    slot_task=$(fm "$slot" task_id)
    if [ "$slot_task" != "$task_id" ]; then
        echo "REFUSED: worktree is currently owned by a DIFFERENT task."
        echo "  asked for task_id : $task_id"
        echo "  slot $ccm_id says : ${slot_task:-(unset)}"
        echo "  The worktree has been reused. Reclaiming here would close the"
        echo "  window of a task that is still using it."
        echo "VERDICT: REFUSED (C4)"; echo; overall=1; continue
    fi

    # Near-miss visibility: other sessions that ever ran this task_id. These are
    # exactly the slots a task_id-first resolution could have latched onto.
    others=""
    for s in "$TREE_DIR"/*.md; do
        [ -f "$s" ] || continue
        sb=$(basename "$s" .md)
        [ "$sb" = "$ccm_id" ] && continue
        [ "$(fm "$s" task_id)" = "$task_id" ] && others="${others}${others:+ }${sb}($(fm "$s" status))"
    done
    if [ -n "$others" ]; then
        echo "note        : $task_id also names these OTHER sessions: $others"
        echo "              (not used — C4 resolved via .cc-mode, which is the point)"
    fi
    echo "C4 identity : PASS (.cc-mode session_id == slot session_id == $ccm_id)"

    # ------------------------------------------------- C2: worktree clean ---
    if ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
        echo "C2 clean    : REFUSED — $wt is not a git worktree"
        echo "VERDICT: REFUSED (C2)"; echo; overall=1; continue
    fi
    porcelain=$(git -C "$wt" status --porcelain 2>&1)
    dirty_n=$( [ -z "$porcelain" ] && echo 0 || printf '%s\n' "$porcelain" | wc -l | tr -d ' ')
    if [ "$dirty_n" -ne 0 ]; then
        echo "C2 clean    : FAIL — $dirty_n uncommitted path(s)"
        head -10 <<<"$porcelain" | sed 's/^/              /'
        fail="${fail}C2 "
    else
        echo "C2 clean    : PASS (git status --porcelain empty)"
    fi

    # -------------------------------------------- C3: merged into main ------
    # Fetch first. For THIS gate a stale cache can only make a merged branch
    # look unmerged — a false negative, which refuses the reclaim, which is the
    # safe direction. We fetch anyway so the reported ahead-count is real and
    # so the operator is never shown a number that came out of a cache.
    fetch_note="skipped(--no-fetch)"
    if [ "$DO_FETCH" -eq 1 ]; then
        if [ -z "$(git -C "$wt" remote 2>/dev/null)" ]; then
            fetch_note="no-remote(local-only)"
        elif timeout 90 git -C "$wt" fetch --all --prune --tags >/dev/null 2>&1; then
            fetch_note="fetched"
        else
            fetch_note="FETCH FAILED (local refs may be stale; can only under-report merges)"
        fi
    fi

    mref="$MAIN_REF"
    if [ -z "$mref" ]; then
        for r in main master; do
            git -C "$wt" rev-parse --verify --quiet "$r" >/dev/null 2>&1 && { mref="$r"; break; }
        done
    fi
    if [ -z "$mref" ]; then
        echo "C3 merged   : REFUSED — no main/master ref in this repo (use --main-ref)"
        fail="${fail}C3 "
    else
        head_sha=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
        branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
        ahead=$(git -C "$wt" rev-list --count "$mref..HEAD" 2>/dev/null)
        if git -C "$wt" merge-base --is-ancestor "$head_sha" "$mref" 2>/dev/null; then
            echo "C3 merged   : PASS ($branch @ ${head_sha:0:8} is an ancestor of $mref) [$fetch_note]"
        else
            echo "C3 merged   : FAIL ($branch is ${ahead:-?} commit(s) ahead of $mref, not merged) [$fetch_note]"
            echo "              A finished child whose branch is deliberately unmerged"
            echo "              KEEPS its window — that is a CEO decision, not a stall."
            fail="${fail}C3 "
        fi
    fi

    # ------------------------------------------------------ window exists ---
    win_ok=0
    if command -v tmux >/dev/null 2>&1; then
        wl=$(tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2>&1)
        if [ $? -ne 0 ]; then
            echo "window      : tmux unavailable — $(head -1 <<<"$wl")"
            fail="${fail}TMUX "
        elif grep -Fxq "$task_id" <<<"$wl"; then
            echo "window      : ${TMUX_SESSION}:=${task_id} present"
            win_ok=1
        else
            echo "window      : no window named '$task_id' in session '$TMUX_SESSION' — nothing to reclaim"
            echo "VERDICT: NO-OP (already reclaimed)"; echo; continue
        fi
    else
        echo "window      : tmux not installed"
        fail="${fail}TMUX "
    fi

    # ------------------------------------------- C1: slot status, read LAST --
    # Deliberately the final condition evaluated. Everything above is about
    # durable state that does not change under us; the slot flips the instant
    # the child finishes /end, so it is read as late as possible.
    IFS='|' read -r st ea <<<"$(read_slot_status "$slot")"
    case "$st" in
        completed|ended-by-user|abandoned)
            if [ -z "$ea" ]; then
                echo "C1 status   : FAIL — status=$st but ended_at is EMPTY"
                echo "              A terminal status without ended_at means the close-out"
                echo "              did not finish writing. Treat as still in flight."
                fail="${fail}C1 "
            else
                echo "C1 status   : PASS (status=$st, ended_at=$ea) [read at gate time]"
            fi ;;
        *)
            echo "C1 status   : FAIL — status=${st:-(unset)} is not terminal"
            fail="${fail}C1 " ;;
    esac

    if [ -n "$fail" ]; then
        echo "VERDICT: REFUSED (${fail% })"
        echo; overall=1; continue
    fi

    if [ "$DO_KILL" -eq 0 ]; then
        echo "VERDICT: WOULD RECLAIM — all four conditions pass."
        echo "         Re-run with --kill. The conditions are re-verified in that run;"
        echo "         this verdict is NOT carried over."
        echo; continue
    fi

    # ------------------------------------------------- pre-kill race guard --
    # Test seam only; no-op in normal operation.
    [ -n "${CC_RECLAIM_TEST_PRE_KILL_HOOK:-}" ] && eval "$CC_RECLAIM_TEST_PRE_KILL_HOOK"

    # Final re-read of the ONE condition that can change under us, with nothing
    # between it and the kill but the comparison itself. This narrows the
    # check-to-act gap to microseconds. It is not a mutex — a child could still
    # flip in that window — but it removes the entire class of failure that
    # comes from a stale batch, which is what actually happened.
    IFS='|' read -r st2 ea2 <<<"$(read_slot_status "$slot")"
    if [ "$st2" != "$st" ] || [ "$ea2" != "$ea" ]; then
        echo "ABORTED: slot changed between gate and kill."
        echo "  at gate : status=$st ended_at=$ea"
        echo "  now     : status=$st2 ended_at=$ea2"
        echo "  The child is doing something. Window kept."
        echo "VERDICT: ABORTED (race caught)"
        echo; raced=1; overall=1; continue
    fi

    if [ "$win_ok" -eq 1 ] && tmux kill-window -t "${TMUX_SESSION}:=${task_id}" 2>/dev/null; then
        echo "RECLAIMED: closed window '${task_id}' in tmux session '${TMUX_SESSION}'"
        echo "           (addressed by name; window indices are never cited)"
        echo "VERDICT: RECLAIMED"
    else
        echo "VERDICT: KILL FAILED — window '${task_id}' could not be closed"
        overall=1
    fi
    echo
done

[ "$raced" -eq 1 ] && exit 4
exit "$overall"
