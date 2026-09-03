#!/usr/bin/env bash
# cc-status-scan.sh — one-shot, FRESH gather for an EA company-status pass.
#
# Part 1 of the company-status skill. Produces the raw material for the three
# command-center questions, from live artifacts only:
#
#   1. which children are in flight and what are they doing
#   2. what events arrived for me (unread vs the .read-up-to marker)
#   3. what needs the CEO right now
#
# This script PRINTS FACTS. It does not summarise, rank, or decide. Every
# number it emits is produced by a command run inside this process — nothing
# is read from a previous report, an event title, or a remembered verdict.
# See ~/vault/20-surface/claude-memory/feedback_fresh_status_checks.md.
#
# Why one script and not inline bash in the skill: a status pass must be a
# single Bash tool call with self-contained shell state. Split across calls,
# the cwd resets between them and the per-child `git -C` targets drift — the
# same failure class as feedback_tree_slot_helpers_resolve_from_cwd.md. It
# also means a partial scan cannot be mistaken for a whole one (see the
# SCAN COMPLETE sentinel at the bottom).
#
# Usage:
#   cc-status-scan.sh [--session-id <id>] [--mode-file <path>]
#                     [--tree-dir <path>] [--tasks-dir <path>]
#                     [--tmux-session <name>] [--pane-lines <n>]
#                     [--no-fetch] [--stall-hours <n>]
#
# Exit codes: 0 scan ran (findings are in the output, not the exit code)
#             2 usage error
#             3 identity mismatch — refused before reading anything

# NOT `set -e`. A child whose worktree was deleted, or whose git call fails,
# must be REPORTED and skipped, not abort the scan and leave the operator with
# a truncated list that reads as complete. `set -u` and pipefail stay on.
set -uo pipefail

usage() {
    cat <<'USAGE'
usage: cc-status-scan.sh [options]

  --session-id <id>     Assert whose status pass this is (22-hex). Checked
                        against the resolved .cc-mode; mismatch is refused.
  --mode-file <path>    Read identity from this .cc-mode instead of walking
                        up from $PWD.
  --tree-dir <path>     Tree sessions dir (default ~/vault/20-surface/company/tree/sessions)
  --tasks-dir <path>    Task folders dir (default ~/vault/20-surface/company/tasks)
  --tmux-session <name> tmux session holding child windows (default: company)
  --pane-lines <n>      Lines of pane tail to scan for blocking prompts (default 40)
  --stall-hours <n>     Age past which a running child with no output is
                        flagged as a stall candidate (default 1)
  --no-fetch            Skip `git fetch`. Every ahead/behind number is then
                        printed as UNVERIFIED — refs/remotes is a local cache.
  -h, --help            Show this help.
USAGE
}

TREE_DIR="$HOME/vault/20-surface/company/tree/sessions"
TASKS_DIR="$HOME/vault/20-surface/company/tasks"
TMUX_SESSION="company"
PANE_LINES=40
STALL_HOURS=1
DO_FETCH=1
arg_session_id=""
mode_file=""

while [ $# -gt 0 ]; do
    case "$1" in
        --session-id) [ $# -ge 2 ] || { echo "ERROR: --session-id needs a value" >&2; exit 2; }
                      arg_session_id="$2"; shift 2 ;;
        --session-id=*) arg_session_id="${1#*=}"; shift ;;
        --mode-file) [ $# -ge 2 ] || { echo "ERROR: --mode-file needs a value" >&2; exit 2; }
                     mode_file="$2"; shift 2 ;;
        --mode-file=*) mode_file="${1#*=}"; shift ;;
        --tree-dir) TREE_DIR="$2"; shift 2 ;;
        --tree-dir=*) TREE_DIR="${1#*=}"; shift ;;
        --tasks-dir) TASKS_DIR="$2"; shift 2 ;;
        --tasks-dir=*) TASKS_DIR="${1#*=}"; shift ;;
        --tmux-session) TMUX_SESSION="$2"; shift 2 ;;
        --tmux-session=*) TMUX_SESSION="${1#*=}"; shift ;;
        --pane-lines) PANE_LINES="$2"; shift 2 ;;
        --pane-lines=*) PANE_LINES="${1#*=}"; shift ;;
        --stall-hours) STALL_HOURS="$2"; shift 2 ;;
        --stall-hours=*) STALL_HOURS="${1#*=}"; shift ;;
        --no-fetch) DO_FETCH=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- identity --
# Same precedence and the same refusal as cc-tree-slot-write/update: an id the
# caller states must agree with the .cc-mode we resolve, or we are looking at
# another lane and everything downstream would be about the wrong session.
want_id="$arg_session_id"
want_src="--session-id"
if [ -z "$want_id" ] && [ -n "${CC_SESSION_ID:-}" ]; then
    want_id="$CC_SESSION_ID"; want_src="\$CC_SESSION_ID"
fi

if [ -n "$mode_file" ] && [ ! -f "$mode_file" ]; then
    echo "ERROR: --mode-file $mode_file does not exist" >&2; exit 2
fi

if [ -z "$mode_file" ]; then
    d="$PWD"
    while [ "$d" != "/" ]; do
        [ -f "$d/.cc-mode" ] && { mode_file="$d/.cc-mode"; break; }
        d=$(dirname "$d")
    done
fi

mode_session_id=""
[ -n "$mode_file" ] && mode_session_id=$( { grep '^session_id=' "$mode_file" || true; } | cut -d= -f2-)

if [ -n "$want_id" ] && [ -n "$mode_session_id" ] && [ "$want_id" != "$mode_session_id" ]; then
    echo "ERROR: session id mismatch — refusing to run a status pass as another session." >&2
    echo "       $want_src says: $want_id" >&2
    echo "       $mode_file says: $mode_session_id" >&2
    exit 3
fi

MY_ID="${want_id:-$mode_session_id}"
if [ -z "$MY_ID" ]; then
    echo "ERROR: no session_id (no --session-id, no \$CC_SESSION_ID, no .cc-mode above $PWD)." >&2
    echo "       A status pass has to know whose children it is scanning." >&2
    exit 2
fi

now_epoch=$(date +%s)

# --------------------------------------------------------------- utilities --
fm() {  # fm <file> <key>   — first frontmatter value for key
    { grep -m1 "^$2:" "$1" 2>/dev/null || true; } | sed "s/^$2:[[:space:]]*//"
}

age_of() {  # age_of <epoch> -> "2h14m ago" / "-"
    local t="$1" d
    [ -z "$t" ] && { printf '%s' "-"; return; }
    d=$(( now_epoch - t ))
    [ "$d" -lt 0 ] && d=0
    if   [ "$d" -lt 3600 ]; then printf '%dm ago' $(( d / 60 ))
    elif [ "$d" -lt 86400 ]; then printf '%dh%dm ago' $(( d / 3600 )) $(( (d % 3600) / 60 ))
    else printf '%dd%dh ago' $(( d / 86400 )) $(( (d % 86400) / 3600 ))
    fi
}

newest_event() {  # newest_event <events_dir>  -> "file|verb|severity|title|age"
    local dir="$1" f verb sev title mt
    [ -d "$dir" ] || { printf '%s' "|||no events dir|"; return; }
    f=$(find "$dir" -maxdepth 1 -name '[0-9]*-*.md' -type f 2>/dev/null | sort | tail -1)
    [ -z "$f" ] && { printf '%s' "|||(no events)|"; return; }
    verb=$(fm "$f" verb); sev=$(fm "$f" severity)
    title=$( { grep -m1 '^# ' "$f" || true; } | sed 's/^# //')
    mt=$(stat -c %Y "$f" 2>/dev/null)
    printf '%s|%s|%s|%s|%s' "$(basename "$f")" "$verb" "$sev" "${title:-(untitled)}" "$(age_of "$mt")"
}

# Blocking-prompt signatures. These are POSITIVE detectors for a pane that is
# WAITING ON A HUMAN — not a liveness oracle.
#
# feedback_verify_branch_liveness_by_filesystem.md is emphatic that a wedged
# TUI and a healthy idle one look identical in capture-pane, so "the pane looks
# fine" proves nothing and progress must be measured on the filesystem. That
# rule is about ABSENCE of a signal. These regexes are about PRESENCE of one:
# a trust dialog or a numbered menu on screen is a specific artefact that an
# idle-but-healthy session does not render. Presence is informative; absence is
# not. Both are reported, and the skill is required to corroborate either with
# the filesystem columns before acting.
PANE_SIGS=(
    "TRUST_DIALOG|Do you trust the files in this folder"
    "PERMISSION_PROMPT|Do you want to (proceed|make this edit|create|allow)"
    "YES_NO_PROMPT|❯ *1\. Yes|\(y/n\)"
    "GOAL_PROMPT|In one sentence, what is this session for"
    "END_NOT_A_COMMAND|Unknown command: /end"
    "LOGIN_REQUIRED|Please run /login|Invalid API key"
    "USAGE_LIMIT|approaching (your )?usage limit|rate limit"
)

pane_scan() {  # pane_scan <window_name> -> "status|signals"
    local w="$1" out rc hits="" name re n
    command -v tmux >/dev/null 2>&1 || { printf '%s' "tmux-not-installed|"; return; }
    # `=` forces exact NAME matching. Without it a numeric task_id (e.g. "42")
    # is parsed as a window INDEX and we would scan an unrelated window.
    out=$(tmux capture-pane -p -t "${TMUX_SESSION}:=${w}" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        # Distinguish the two failures carefully. "can't find window" is a
        # LIVE SERVER answering — the window is simply gone, which for a
        # finished child is the normal, healthy state. Reporting that as
        # "tmux unavailable" sends the reader off debugging a working tmux;
        # this session lost time to exactly that confusion.
        if printf '%s' "$out" | grep -qi "can't find window\|can't find session\|no such window"; then
            printf '%s' "no-window|"
        else
            printf 'tmux-unreachable(%s)|' "$(printf '%s' "$out" | head -1 | cut -c1-60)"
        fi
        return
    fi
    out=$(printf '%s\n' "$out" | tail -n "$PANE_LINES")
    for sig in "${PANE_SIGS[@]}"; do
        name="${sig%%|*}"; re="${sig#*|}"
        printf '%s\n' "$out" | grep -qE "$re" && hits="${hits}${hits:+,}${name}"
    done
    # A numbered menu needs >= 2 options to be a menu rather than prose.
    n=$(printf '%s\n' "$out" | grep -cE '^[[:space:]]*(❯[[:space:]]*)?[0-9]+\.[[:space:]]+[A-Za-z]' 2>/dev/null)
    [ "${n:-0}" -ge 2 ] && hits="${hits}${hits:+,}NUMBERED_MENU(${n})"
    printf 'ok|%s' "${hits:-none}"
}

# ------------------------------------------------------------------- fetch --
# refs/remotes is a LOCAL CACHE of the last fetch. Any ahead/behind derived
# from it without a fetch is fiction, reported silently
# (feedback_fresh_status_checks.md, 2026-08-10 instance). Fetch once per
# distinct object store — worktrees of one repo share refs, so fetching in
# every child worktree would be the same fetch N times.
declare -A FETCHED=()
fetch_repo() {  # fetch_repo <worktree> -> sets FETCH_NOTE
    local wt="$1" common rc out
    FETCH_NOTE=""
    if [ "$DO_FETCH" -eq 0 ]; then FETCH_NOTE="UNVERIFIED(--no-fetch)"; return; fi
    common=$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null) || { FETCH_NOTE="UNVERIFIED(not-a-repo)"; return; }
    common=$(cd "$wt" && cd "$common" && pwd 2>/dev/null) || common="$wt"
    if [ -n "${FETCHED[$common]:-}" ]; then FETCH_NOTE="${FETCHED[$common]}"; return; fi
    if [ -z "$(git -C "$wt" remote 2>/dev/null)" ]; then
        FETCHED[$common]="no-remote(local-only)"; FETCH_NOTE="${FETCHED[$common]}"; return
    fi
    out=$(timeout 90 git -C "$wt" fetch --all --prune --tags 2>&1); rc=$?
    if [ $rc -eq 0 ]; then FETCHED[$common]="fetched"
    else FETCHED[$common]="UNVERIFIED(fetch-failed rc=$rc: $(printf '%s' "$out" | head -1 | cut -c1-50))"
    fi
    FETCH_NOTE="${FETCHED[$common]}"
}

main_ref_for() {  # main_ref_for <worktree>
    local wt="$1"
    for r in main master; do
        git -C "$wt" rev-parse --verify --quiet "$r" >/dev/null 2>&1 && { printf '%s' "$r"; return; }
    done
    printf '%s' ""
}

echo "=============================================================="
echo "COMPANY STATUS SCAN"
echo "=============================================================="
echo "session_id : $MY_ID"
echo "mode_file  : ${mode_file:-(none)}"
echo "scanned_at : $(date -Iseconds)"
echo "tree_dir   : $TREE_DIR"
echo "fetch      : $( [ "$DO_FETCH" -eq 1 ] && echo enabled || echo 'DISABLED — ahead-counts are UNVERIFIED' )"
echo

if [ ! -d "$TREE_DIR" ]; then
    echo "ERROR: tree dir not found: $TREE_DIR"
    echo "SCAN COMPLETE (no data)"
    exit 0
fi

# ================================================== Q1: children in flight ==
echo "## Q1 — CHILDREN"
echo

child_slots=()
for slot in "$TREE_DIR"/*.md; do
    [ -f "$slot" ] || continue
    [ "$(fm "$slot" parent_id)" = "$MY_ID" ] && child_slots+=("$slot")
done

RECLAIM_CANDIDATES=()
STALL_CANDIDATES=()
REVIEW_CANDIDATES=()
BLOCKED_PANES=()

if [ ${#child_slots[@]} -eq 0 ]; then
    echo "(no children — no slot in $TREE_DIR has parent_id: $MY_ID)"
else
    for slot in "${child_slots[@]}"; do
        sid=$(basename "$slot" .md)
        task_id=$(fm "$slot" task_id)
        status=$(fm "$slot" status)
        ended_at=$(fm "$slot" ended_at)
        started_at=$(fm "$slot" started_at)
        wt=$(fm "$slot" worktree)

        echo "------------------------------------------------------------"
        echo "task_id     : ${task_id:-(unset)}"
        echo "session_id  : $sid"
        echo "status      : ${status:-(unset)}   ended_at: ${ended_at:-(empty)}"
        echo "started_at  : ${started_at:-(unset)}"
        echo "worktree    : ${wt:-(unset)}"

        # -- worktree identity. A worktree is REUSED across sessions, so its
        #    .cc-mode may name a different (older) session than this slot. That
        #    mismatch is the single most important field on this line: it is
        #    what stops a reclaim from acting on the wrong session's state.
        ccm_id=""; ident="n/a"
        if [ -n "$wt" ] && [ -f "$wt/.cc-mode" ]; then
            ccm_id=$( { grep '^session_id=' "$wt/.cc-mode" || true; } | cut -d= -f2-)
            if [ "$ccm_id" = "$sid" ]; then ident="MATCH"
            else ident="MISMATCH (.cc-mode=$ccm_id — worktree reused by another session)"; fi
        elif [ -n "$wt" ] && [ ! -d "$wt" ]; then ident="worktree-gone"
        elif [ -n "$wt" ]; then ident="no .cc-mode in worktree"
        fi
        echo "identity    : $ident"

        # -- git: fetch first, then derive. Counts printed with their provenance.
        if [ -n "$wt" ] && [ -d "$wt" ] && git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
            fetch_repo "$wt"
            mref=$(main_ref_for "$wt")
            branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
            dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
            if [ -n "$mref" ]; then
                ahead=$(git -C "$wt" rev-list --count "$mref..HEAD" 2>/dev/null)
                behind=$(git -C "$wt" rev-list --count "HEAD..$mref" 2>/dev/null)
                if git -C "$wt" merge-base --is-ancestor HEAD "$mref" 2>/dev/null; then merged="yes"; else merged="no"; fi
            else
                ahead="?"; behind="?"; merged="?"; mref="(no main/master)"
            fi
            echo "branch      : ${branch:-?}   vs $mref"
            echo "commits     : ahead=$ahead behind=$behind merged=$merged   [$FETCH_NOTE]"
            echo "dirty files : $dirty"
        else
            echo "branch      : (worktree missing or not a git repo)"
            echo "commits     : n/a"
            echo "dirty files : n/a"
            dirty=""; merged=""; ahead=""
        fi

        # -- newest event from THIS child's own events dir
        IFS='|' read -r ef ev es et ea <<<"$(newest_event "$TREE_DIR/${sid}.events")"
        echo "last event  : ${ef:-none} ${ev:+[$ev/${es:-?}]} ${et} ${ea}"

        # -- filesystem liveness. This, not the pane, is the progress oracle.
        tf="$TASKS_DIR/${task_id}"
        if [ -n "$task_id" ] && [ -d "$tf" ]; then
            newest=$(find "$tf" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1)
            nt=${newest%% *}; np=${newest#* }
            echo "task folder : $(basename "${np:-none}") $(age_of "${nt%%.*}")"
            tf_epoch="${nt%%.*}"
        else
            echo "task folder : ABSENT ($tf)"
            tf_epoch=""
        fi

        # -- pane signal (advisory only)
        IFS='|' read -r ps psig <<<"$(pane_scan "${task_id:-$sid}")"
        echo "pane        : $ps  signals=${psig:-none}"

        # -- mechanical flags. Synthesis is the skill's job, not this script's.
        if [ "$status" = "running" ]; then
            if [ "$ps" = "ok" ] && [ -n "$psig" ] && [ "$psig" != "none" ]; then
                BLOCKED_PANES+=("$task_id ($psig)")
            fi
            started_epoch=$(date -d "$started_at" +%s 2>/dev/null || echo "")
            if [ -n "$started_epoch" ] && [ $(( now_epoch - started_epoch )) -gt $(( STALL_HOURS * 3600 )) ]; then
                if [ "${ahead:-0}" = "0" ] && [ -z "$tf_epoch" ]; then
                    STALL_CANDIDATES+=("$task_id (running $(age_of "$started_epoch"), 0 commits, no task folder)")
                fi
            fi
        else
            case "$status" in
                completed|ended-by-user|abandoned)
                    if [ "$merged" = "yes" ] && [ "${dirty:-1}" = "0" ] && [ "$ident" = "MATCH" ] && [ -n "$ended_at" ]; then
                        RECLAIM_CANDIDATES+=("$task_id")
                    elif [ "$merged" = "no" ]; then
                        REVIEW_CANDIDATES+=("$task_id ($status, ${ahead:-?} commits unmerged)")
                    fi
                    ;;
            esac
        fi
    done
    echo "------------------------------------------------------------"
fi
echo

# ==================================================== Q2: my unread events ==
echo "## Q2 — UNREAD EVENTS FOR ME"
echo
my_events="$TREE_DIR/${MY_ID}.events"
NEEDS_ATTENTION=()
highest=0
if [ ! -d "$my_events" ]; then
    echo "(no events dir at $my_events)"
else
    marker="$my_events/.read-up-to"
    last_read=0
    [ -f "$marker" ] && last_read=$(tr -dc '0-9' < "$marker")
    [ -z "$last_read" ] && last_read=0
    echo "read-up-to marker: $last_read"
    unread=$(find "$my_events" -maxdepth 1 -name '[0-9]*-*.md' -type f 2>/dev/null | sort | awk -v t="$last_read" -F'/' '{
        f=$NF; n=f; sub(/-.*$/,"",n); gsub(/^0+/,"",n); if(n=="")n="0";
        if (n+0 > t+0) print $0 }')
    highest=$(find "$my_events" -maxdepth 1 -name '[0-9]*-*.md' -type f 2>/dev/null \
        | awk -F'/' '{f=$NF;n=f;sub(/-.*$/,"",n);gsub(/^0+/,"",n);if(n=="")n="0";print n+0}' | sort -n | tail -1)
    highest=${highest:-0}
    if [ -z "$unread" ]; then
        echo "unread: 0  (highest event on file: $highest)"
    else
        echo "unread: $(printf '%s\n' "$unread" | wc -l | tr -d ' ')  (highest event on file: $highest)"
        echo
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            v=$(fm "$f" verb); s=$(fm "$f" severity)
            t=$( { grep -m1 '^# ' "$f" || true; } | sed 's/^# //')
            echo "  $(basename "$f")  [${v:-?}/${s:-?}]  ${t:-(untitled)}  $(age_of "$(stat -c %Y "$f" 2>/dev/null)")"
            case "$v" in blocker|question|escalation|defect) NEEDS_ATTENTION+=("$(basename "$f"): ${t}") ;; esac
            [ "$s" = "critical" ] && NEEDS_ATTENTION+=("$(basename "$f") CRITICAL: ${t}")
        done <<<"$unread"
        echo
        echo "  after acting on each, advance the marker:"
        echo "    echo $highest > '$marker'"
    fi
fi
echo

# ======================================================== Q3: needs the CEO ==
echo "## Q3 — CANDIDATES FOR CEO ATTENTION (mechanical flags, not a verdict)"
echo
emit() { local label="$1"; shift; if [ $# -eq 0 ]; then echo "  $label: none"; else echo "  $label:"; printf '    - %s\n' "$@"; fi; }
emit "BLOCKED / awaiting a human"       "${NEEDS_ATTENTION[@]+"${NEEDS_ATTENTION[@]}"}"
emit "PANE SIGNAL (advisory — corroborate on the filesystem before acting)" "${BLOCKED_PANES[@]+"${BLOCKED_PANES[@]}"}"
emit "STALL CANDIDATES (running, no commits, no task folder)" "${STALL_CANDIDATES[@]+"${STALL_CANDIDATES[@]}"}"
emit "DONE BUT UNMERGED (awaiting review/merge decision)" "${REVIEW_CANDIDATES[@]+"${REVIEW_CANDIDATES[@]}"}"
emit "RECLAIM CANDIDATES (re-verify atomically — DO NOT kill from this list)" "${RECLAIM_CANDIDATES[@]+"${RECLAIM_CANDIDATES[@]}"}"
echo
echo "  NOTE: the reclaim list above is a SHORTLIST computed at scan time."
echo "        It is stale the instant it is printed. Every kill must re-verify"
echo "        all four conditions inside cc-reclaim-window.sh, which reads the"
echo "        slot status line again in the same process as the kill."
echo

# Sentinel. If this line is missing the scan died partway and the sections
# above are INCOMPLETE — do not read a truncated scan as an empty company.
echo "SCAN COMPLETE $(date -Iseconds)"
