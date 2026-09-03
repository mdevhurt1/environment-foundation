#!/usr/bin/env bash
# cc-land-child.sh — land a finished child in ONE verified invocation:
# merge its branch into LOCAL main, then run the four-gate window reclaim.
#
# Part of the company-status skill; the shell entry point is `cc-land`.
#
# ---------------------------------------------------------------------------
# WHY (AI_ST-72, workflow-audit delegation.md §5-§7)
# ---------------------------------------------------------------------------
# On 2026-09-03 every finished child cost the EA a hand-run merge and a
# hand-run reclaim — 2 of the ~5 mechanical touches per child lifecycle that
# fragmented the whole day (52 interrupts, one per 7.7 min). INFRA-41's
# Done-flip mechanization proved the pattern pays the same day it merges.
# This script is the same move for the close side: after the EA has done the
# JUDGEMENT (read the report, decided the work should land), the mechanics
# are one command:   cc-land <task-id>
#
# What it does, in order, refusing loudly at the first failed gate:
#   1. resolve worktree -> .cc-mode -> slot   (C4, identity — same rule as
#      cc-reclaim-window.sh: the worktree's .cc-mode names the session)
#   2. C1: slot status terminal + ended_at set. If the child is still
#      `running`, DIAGNOSE the close-side stall class (AI_ST-19 idled >=7m39s
#      at the end-conversation transcript menu, event 0011): the pane is
#      scanned for the known closing-ritual signatures and, with --nudge, the
#      one documented mitigation is applied and the slot re-polled.
#   3. C2: child worktree clean.
#   4. merge branch/<task> into the parent repo's LOCAL main — only if the
#      main worktree has main checked out and is itself clean. Conflicts
#      abort the merge and refuse; nothing is left half-merged.
#   5. delegate to cc-reclaim-window.sh --kill, which re-verifies all four
#      conditions atomically (C3, merged-into-main, now passes because of
#      step 4) and closes the window.
#
# Every action is appended to the EA action trail (cc-ea-log.sh, AI_ST-73).
#
# THIS SCRIPT NEVER PUSHES. Publishing is the EA's judgement call, kept
# deliberately outside the mechanized path.
#
# Exit codes: 0 landed (merged or already merged; window reclaimed or already
#               gone); 1 refused or failed at some gate; 2 usage error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
RECLAIM_SH="$SCRIPT_DIR/cc-reclaim-window.sh"
EALOG_SH="${CC_EA_LOG_SH:-$SCRIPT_DIR/../../../shell/cc-ea-log.sh}"

usage() {
    cat <<'USAGE'
usage: cc-land-child.sh [options] <task-id>

  --repo <path>          Candidate parent repo for worktree derivation.
                         Repeatable. Default: every parent_repo named by the
                         tree slots (same rule as cc-reclaim-window.sh).
  --worktree <path>      Explicit child worktree (skips derivation).
  --merge-msg <text>     Merge-commit description. Default: the branch tip's
                         subject line, as "Merge branch/<task>: <subject>".
  --main-ref <ref>       Ref that counts as "main" (default: main, then master).
  --tree-dir <path>      Tree sessions dir (default ~/vault/20-surface/company/tree/sessions)
  --tmux-session <name>  tmux session holding child windows (default: company)
  --nudge                On a diagnosed close-stall, apply the documented
                         mitigation once (Enter on a menu; a Skill-tool
                         instruction on `Unknown command: /end`) and re-poll.
  --nudge-wait <s>       How long to wait for the slot to flip after a nudge
                         (default 120).
  --dry-run              Verify every gate and report; merge nothing, kill
                         nothing (reclaim is run without --kill).
  --no-reclaim           Merge only; leave the window alone.
  --no-fetch             Passed through to the reclaim gate.
  --allow-dirty-main     Merge even if the main worktree has uncommitted
                         changes. Default is to refuse: a merge into a dirty
                         main checkout can entangle unrelated work.
  -h, --help             Show this help.
USAGE
}

TREE_DIR="$HOME/vault/20-surface/company/tree/sessions"
TMUX_SESSION="company"
MAIN_REF=""
EXPLICIT_WT=""
MERGE_MSG=""
REPOS=()
TASK=""
DRY_RUN=0
NO_RECLAIM=0
NO_FETCH=0
NUDGE=0
NUDGE_WAIT=120
ALLOW_DIRTY_MAIN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) [ $# -ge 2 ] || { echo "ERROR: --repo needs a value" >&2; exit 2; }
                REPOS+=("$2"); shift 2 ;;
        --repo=*) REPOS+=("${1#*=}"); shift ;;
        --worktree) [ $# -ge 2 ] || { echo "ERROR: --worktree needs a value" >&2; exit 2; }
                EXPLICIT_WT="$2"; shift 2 ;;
        --worktree=*) EXPLICIT_WT="${1#*=}"; shift ;;
        --merge-msg) [ $# -ge 2 ] || { echo "ERROR: --merge-msg needs a value" >&2; exit 2; }
                MERGE_MSG="$2"; shift 2 ;;
        --merge-msg=*) MERGE_MSG="${1#*=}"; shift ;;
        --main-ref) [ $# -ge 2 ] || { echo "ERROR: --main-ref needs a value" >&2; exit 2; }
                MAIN_REF="$2"; shift 2 ;;
        --main-ref=*) MAIN_REF="${1#*=}"; shift ;;
        --tree-dir) [ $# -ge 2 ] || { echo "ERROR: --tree-dir needs a value" >&2; exit 2; }
                TREE_DIR="$2"; shift 2 ;;
        --tree-dir=*) TREE_DIR="${1#*=}"; shift ;;
        --tmux-session) [ $# -ge 2 ] || { echo "ERROR: --tmux-session needs a value" >&2; exit 2; }
                TMUX_SESSION="$2"; shift 2 ;;
        --tmux-session=*) TMUX_SESSION="${1#*=}"; shift ;;
        --nudge) NUDGE=1; shift ;;
        --nudge-wait) [ $# -ge 2 ] || { echo "ERROR: --nudge-wait needs a value" >&2; exit 2; }
                NUDGE_WAIT="$2"; shift 2 ;;
        --nudge-wait=*) NUDGE_WAIT="${1#*=}"; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --no-reclaim) NO_RECLAIM=1; shift ;;
        --no-fetch) NO_FETCH=1; shift ;;
        --allow-dirty-main) ALLOW_DIRTY_MAIN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
        *) [ -z "$TASK" ] || { echo "ERROR: one task-id per invocation" >&2; exit 2; }
           TASK="$1"; shift ;;
    esac
done

[ -n "$TASK" ] || { echo "ERROR: no task-id given" >&2; usage >&2; exit 2; }

ealog() {  # ealog <verb> <text...> — best-effort trail append, never fatal.
    [ -f "$EALOG_SH" ] || return 0
    bash "$EALOG_SH" --task "$TASK" "$@" >/dev/null 2>&1 || true
}

fm() { { grep -m1 "^$2:" "$1" 2>/dev/null || true; } | sed "s/^$2:[[:space:]]*//"; }

# Default repo set: same derivation as cc-reclaim-window.sh.
if [ ${#REPOS[@]} -eq 0 ]; then
    while IFS= read -r r; do [ -n "$r" ] && REPOS+=("$r"); done < <(
        { grep -h '^parent_repo:' "$TREE_DIR"/*.md 2>/dev/null || true; } \
        | sed 's/^parent_repo:[[:space:]]*//' | sort -u)
fi

echo "=============================================================="
echo "LAND — task_id: $TASK$( [ "$DRY_RUN" -eq 1 ] && echo '   [DRY RUN]' )"
echo "=============================================================="

# ---------------------------------------------------- resolve worktree ------
wt=""
if [ -n "$EXPLICIT_WT" ]; then
    wt="$EXPLICIT_WT"
else
    task_safe="${TASK//\//-}"
    for repo in ${REPOS[@]+"${REPOS[@]}"}; do
        [ -d "$repo" ] || continue
        cand="${repo%/*}/$(basename "$repo")-branch-${task_safe}"
        [ -d "$cand" ] && { wt="$cand"; break; }
    done
fi
if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    echo "REFUSED: no worktree found for '$TASK' (tried the cc-branch pattern against ${#REPOS[@]} repo(s))."
    echo "  pass --worktree <path> if it lives elsewhere."
    exit 1
fi
echo "worktree    : $wt"

# ------------------------------------------ C4: worktree -> .cc-mode -> slot
if [ ! -f "$wt/.cc-mode" ]; then
    echo "REFUSED (C4): no .cc-mode in $wt — cannot establish which session owns it."
    exit 1
fi
sid=$( { grep '^session_id=' "$wt/.cc-mode" || true; } | cut -d= -f2-)
slot="$TREE_DIR/${sid}.md"
if [ -z "$sid" ] || [ ! -f "$slot" ]; then
    echo "REFUSED (C4): worktree session '${sid:-none}' has no slot in $TREE_DIR."
    exit 1
fi
slot_task=$(fm "$slot" task_id)
if [ "$slot_task" != "$TASK" ]; then
    echo "REFUSED (C4): worktree is owned by task '${slot_task:-(unset)}', not '$TASK' (reused worktree)."
    exit 1
fi
echo "slot        : $slot (C4 identity PASS)"

# --------------------------------------- C1: terminal status, or diagnose ---
read_status() { printf '%s|%s' "$(fm "$slot" status)" "$(fm "$slot" ended_at)"; }

# pane_diag -> prints comma-joined signature names for the child's pane.
# Presence-based, same doctrine as cc-status-scan.sh PANE_SIGS: a specific
# artefact on screen is informative; a normal-looking pane proves nothing.
pane_diag() {
    command -v tmux >/dev/null 2>&1 || { printf 'no-tmux'; return; }
    # Herestrings, not printf|grep -q: an early-exit consumer SIGPIPEs its
    # producer under pipefail (INFRA-46 pattern, same as its siblings here).
    local out hits="" n
    out=$(tmux capture-pane -p -t "${TMUX_SESSION}:=${TASK}" 2>/dev/null) || { printf 'no-window'; return; }
    out=$(tail -n 40 <<<"$out")
    grep -qF 'Keep this transcript'  <<<"$out" && hits="${hits}${hits:+,}TRANSCRIPT_MENU"
    grep -qF 'Unknown command: /end' <<<"$out" && hits="${hits}${hits:+,}END_NOT_A_COMMAND"
    grep -qE 'In one sentence, what is this session for' <<<"$out" && hits="${hits}${hits:+,}GOAL_PROMPT"
    grep -qF 'Do you trust the files' <<<"$out" && hits="${hits}${hits:+,}TRUST_DIALOG"
    n=$(grep -cE '^[[:space:]]*(❯[[:space:]]*)?[0-9]+\.[[:space:]]+[A-Za-z]' <<<"$out" 2>/dev/null)
    [ "${n:-0}" -ge 2 ] && hits="${hits}${hits:+,}NUMBERED_MENU"
    printf '%s' "${hits:-none}"
}

IFS='|' read -r st ea <<<"$(read_status)"
case "$st" in
    completed|ended-by-user|abandoned) ;;
    *)
        diag=$(pane_diag)
        echo "C1 status   : FAIL — slot says '${st:-(unset)}', not terminal."
        echo "close-stall : pane signatures: $diag"
        nudged=0
        if [ "$NUDGE" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
            case "$diag" in
                *TRANSCRIPT_MENU*|*NUMBERED_MENU*)
                    # Accept the highlighted default. The end-conversation
                    # skill's autonomous branch already tells the child to
                    # decide for itself; a menu on screen means it asked
                    # anyway, and Enter takes its own highlighted answer.
                    tmux send-keys -t "${TMUX_SESSION}:=${TASK}" Enter
                    echo "nudge       : sent Enter (menu default)"
                    ealog nudge "close-stall $diag — sent Enter"
                    nudged=1 ;;
                *END_NOT_A_COMMAND*)
                    tmux send-keys -t "${TMUX_SESSION}:=${TASK}" -l 'Invoke the end-conversation skill via the Skill tool now (the slash form is /end-conversation; /end does not exist).'
                    tmux send-keys -t "${TMUX_SESSION}:=${TASK}" Enter
                    echo "nudge       : sent Skill-tool instruction"
                    ealog nudge "close-stall $diag — sent Skill-tool instruction"
                    nudged=1 ;;
                *)
                    echo "nudge       : no known mitigation for '$diag' — not touching the pane." ;;
            esac
            if [ "$nudged" -eq 1 ]; then
                waited=0
                while [ "$waited" -lt "$NUDGE_WAIT" ]; do
                    sleep 5; waited=$((waited + 5))
                    IFS='|' read -r st ea <<<"$(read_status)"
                    case "$st" in completed|ended-by-user|abandoned) break ;; esac
                done
            fi
        fi
        case "$st" in
            completed|ended-by-user|abandoned)
                echo "C1 status   : now '$st' after nudge (${waited:-0}s)" ;;
            *)
                echo "REFUSED (C1): child is not done. If the pane shows a closing-ritual"
                echo "  artefact, re-run with --nudge, or inspect:"
                echo "    tmux capture-pane -p -t '${TMUX_SESSION}:=${TASK}' | tail -20"
                exit 1 ;;
        esac ;;
esac
if [ -z "$ea" ]; then
    echo "REFUSED (C1): status=$st but ended_at is empty — close-out did not finish writing."
    exit 1
fi
echo "C1 status   : PASS (status=$st, ended_at=$ea)"

# ------------------------------------------------- C2: child worktree clean -
porcelain=$(git -C "$wt" status --porcelain 2>&1)
if [ -n "$porcelain" ]; then
    echo "C2 clean    : FAIL — uncommitted paths in $wt:"
    head -10 <<<"$porcelain" | sed 's/^/              /'
    echo "REFUSED (C2): a dirty worktree means unfinished or unsaved work."
    exit 1
fi
echo "C2 clean    : PASS"

# ----------------------------------------------------------- merge to main --
repo_root=$(fm "$slot" parent_repo)
if [ -z "$repo_root" ] || ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
    echo "REFUSED: slot parent_repo '${repo_root:-none}' is not a git repo."
    exit 1
fi

mref="$MAIN_REF"
if [ -z "$mref" ]; then
    for r in main master; do
        git -C "$repo_root" rev-parse --verify --quiet "$r" >/dev/null 2>&1 && { mref="$r"; break; }
    done
fi
[ -n "$mref" ] || { echo "REFUSED: no main/master ref in $repo_root (use --main-ref)."; exit 1; }

cur_branch=$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ "$cur_branch" != "$mref" ]; then
    echo "REFUSED: $repo_root has '$cur_branch' checked out, not '$mref'."
    echo "  The merge target must be the main worktree with $mref checked out."
    exit 1
fi

head_sha=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
child_branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
echo "merge       : $child_branch @ ${head_sha:0:8} -> $mref in $repo_root"

if git -C "$repo_root" merge-base --is-ancestor "$head_sha" "$mref" 2>/dev/null; then
    echo "merge       : already an ancestor of $mref — nothing to merge."
    merge_done="already-merged"
else
    main_porcelain=$(git -C "$repo_root" status --porcelain 2>&1)
    if [ -n "$main_porcelain" ] && [ "$ALLOW_DIRTY_MAIN" -eq 0 ]; then
        echo "REFUSED: the main worktree itself has uncommitted changes:"
        head -5 <<<"$main_porcelain" | sed 's/^/              /'
        echo "  Merging now could entangle unrelated work. Commit/stash there first,"
        echo "  or re-run with --allow-dirty-main."
        exit 1
    fi
    if [ -z "$MERGE_MSG" ]; then
        MERGE_MSG=$(git -C "$wt" log -1 --format=%s 2>/dev/null)
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "merge       : WOULD MERGE with message: Merge $child_branch: $MERGE_MSG"
        merge_done="dry-run"
    else
        if git -C "$repo_root" merge --no-ff --no-edit -m "Merge $child_branch: $MERGE_MSG" "$child_branch"; then
            # Verify, don't trust: the child's tip must now be an ancestor.
            if git -C "$repo_root" merge-base --is-ancestor "$head_sha" "$mref" 2>/dev/null; then
                echo "merge       : MERGED ($(git -C "$repo_root" rev-parse --short HEAD))"
                merge_done="merged"
                ealog merge "$child_branch @ ${head_sha:0:8} -> $mref ($(git -C "$repo_root" rev-parse --short HEAD))"
            else
                echo "REFUSED: merge command succeeded but $child_branch is still not an ancestor of $mref — inspect $repo_root by hand."
                exit 1
            fi
        else
            git -C "$repo_root" merge --abort 2>/dev/null
            echo "REFUSED: merge conflicted — aborted, $repo_root left as it was."
            echo "  Resolve by hand: git -C '$repo_root' merge --no-ff '$child_branch'"
            ealog merge "CONFLICT merging $child_branch — aborted, left for judgement"
            exit 1
        fi
    fi
fi
echo "NOTE        : nothing was pushed — publishing stays the EA's call."

# ------------------------------------------------------------- reclaim ------
if [ "$NO_RECLAIM" -eq 1 ]; then
    echo "reclaim     : skipped (--no-reclaim)"
    echo "VERDICT: LANDED (merge=$merge_done, window kept)"
    exit 0
fi

[ -f "$RECLAIM_SH" ] || { echo "ERROR: cc-reclaim-window.sh not found beside this script"; exit 1; }

reclaim_args=(--tree-dir "$TREE_DIR" --tmux-session "$TMUX_SESSION" --worktree "$wt")
[ -n "$MAIN_REF" ] && reclaim_args+=(--main-ref "$MAIN_REF")
[ "$NO_FETCH" -eq 1 ] && reclaim_args+=(--no-fetch)
[ "$DRY_RUN" -eq 0 ] && reclaim_args+=(--kill)

echo
if bash "$RECLAIM_SH" "${reclaim_args[@]}" "$TASK"; then
    [ "$DRY_RUN" -eq 0 ] && ealog reclaim "window ${TMUX_SESSION}:${TASK} reclaimed via four-gate kill"
    echo "VERDICT: LANDED (merge=$merge_done, reclaim=$( [ "$DRY_RUN" -eq 1 ] && echo dry-run || echo done ))"
    exit 0
else
    rc=$?
    if [ "$DRY_RUN" -eq 1 ]; then
        # In a dry run the merge above did not happen, so the reclaim gate's
        # C3 (merged-into-main) fails BY CONSTRUCTION. That refusal is the
        # gate working, not a landing problem; the real run merges first.
        echo "VERDICT: DRY RUN COMPLETE (a C3 refusal above is expected — the merge has not run yet)"
        exit 0
    fi
    echo "VERDICT: MERGE $merge_done, BUT RECLAIM REFUSED (rc=$rc) — window kept; see the gate output above."
    exit 1
fi
