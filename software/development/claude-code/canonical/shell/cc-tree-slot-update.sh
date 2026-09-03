#!/usr/bin/env bash
# cc-tree-slot-update — mark the session's tree slot completed at session end.
#
# Called by the end-conversation skill (Step 7). Sets status=completed and
# ended_at=<now> in the slot file, and if a parent_id is known and its events
# directory exists, appends a `completion` event there.
#
# Identity resolution, highest precedence first:
#   1. --session-id <id>   explicit, from the caller
#   2. $CC_SESSION_ID      exported by the launcher, if present
#   3. --mode-file <path>  an explicitly named .cc-mode
#   4. the nearest .cc-mode walking up from $PWD   (fallback)
#
# (4) is what this script did exclusively before 2026-08-20, and it silently
# targets the WRONG session whenever the caller's cwd has moved -- a `cd` into
# another lane's worktree earlier in the same compound command is enough. When
# an explicit id and a .cc-mode are both available they must agree; a mismatch
# is refused before anything is written. See
# ~/vault/20-surface/claude-memory/feedback_tree_slot_helpers_resolve_from_cwd.md
#
# The parent-event append is idempotent: a second run for a child that already
# has a completion event logs nothing rather than double-reporting it. The
# failure direction is deliberate -- a missing duplicate costs nothing, while a
# double-count misleads the parent's status pass.
#
# No-op (exit 0 with a WARN) if no identity can be resolved, or the slot file
# was never written (older sessions, bare launches). Exits non-zero only on a
# refused mismatch or a usage error, both before any write.

set -euo pipefail

usage() {
    cat <<'USAGE'
usage: cc-tree-slot-update.sh [--session-id <id>] [--mode-file <path>]

  --session-id <id>   Close this session (22-hex). Authoritative; if a .cc-mode
                      is also resolved, its session_id must agree.
  --mode-file <path>  Read identity from this .cc-mode rather than walking up
                      from the current working directory.
  -h, --help          Show this help.

With no arguments, identity is inferred from the nearest .cc-mode above $PWD,
which resolves the wrong session if the caller's cwd has moved. Prefer passing
--session-id from anywhere the cwd is not guaranteed.
USAGE
}

arg_session_id=""
mode_file=""
while [ $# -gt 0 ]; do
    case "$1" in
        --session-id)
            [ $# -ge 2 ] || { echo "ERROR: --session-id needs a value" >&2; exit 2; }
            arg_session_id="$2"; shift 2 ;;
        --session-id=*) arg_session_id="${1#*=}"; shift ;;
        --mode-file)
            [ $# -ge 2 ] || { echo "ERROR: --mode-file needs a value" >&2; exit 2; }
            mode_file="$2"; shift 2 ;;
        --mode-file=*) mode_file="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# An explicit id beats the environment; both beat the cwd walk.
want_id="$arg_session_id"
want_src="--session-id"
if [ -z "$want_id" ] && [ -n "${CC_SESSION_ID:-}" ]; then
    want_id="$CC_SESSION_ID"
    want_src="\$CC_SESSION_ID"
fi

if [ -n "$mode_file" ] && [ ! -f "$mode_file" ]; then
    echo "ERROR: --mode-file $mode_file does not exist" >&2
    exit 2
fi

# Fall back to the cwd walk only when no .cc-mode was named explicitly.
resolved_from_cwd=0
if [ -z "$mode_file" ]; then
    d="$PWD"
    while [ "$d" != "/" ]; do
        if [ -f "$d/.cc-mode" ]; then
            mode_file="$d/.cc-mode"
            resolved_from_cwd=1
            break
        fi
        d=$(dirname "$d")
    done
fi

# grep || true: a legacy .cc-mode predating Phase 1 won't have these fields;
# pipefail would otherwise abort before we reach the empty-check below.
mode_session_id=""
parent_id=""
if [ -n "$mode_file" ]; then
    mode_session_id=$( { grep '^session_id=' "$mode_file" || true; } | cut -d= -f2-)
    parent_id=$( { grep '^parent_id=' "$mode_file" || true; } | cut -d= -f2-)
fi

# Consistency assertion: when the caller states who it is AND a .cc-mode was
# found, disagreement means the cwd is pointing at another lane. Refuse before
# touching anything -- this is the wrong-lane failure caught at the door.
if [ -n "$want_id" ] && [ -n "$mode_session_id" ] && [ "$want_id" != "$mode_session_id" ]; then
    echo "ERROR: session id mismatch -- refusing to update a slot that is not yours." >&2
    echo "       $want_src says: $want_id" >&2
    echo "       $mode_file says: $mode_session_id" >&2
    echo "       cwd is $PWD; run this from your own worktree, or pass --mode-file." >&2
    exit 3
fi

if [ -n "$want_id" ]; then
    session_id="$want_id"
else
    session_id="$mode_session_id"
fi

if [ -z "$session_id" ]; then
    echo "WARN: no session_id; skipping slot update"
    exit 0
fi

# Validate identifiers before interpolating into paths/heredocs. session_id
# and parent_id must match the 22-hex format minted by __cc_mint_session_id;
# parent_id may also legitimately be empty (root sessions).
if ! [[ "$session_id" =~ ^[0-9a-f]{22}$ ]]; then
    echo "WARN: malformed session_id ($session_id); refusing to write tree slot" >&2
    exit 0
fi
if [ -n "$parent_id" ] && ! [[ "$parent_id" =~ ^[0-9a-f]{22}$ ]]; then
    echo "WARN: malformed parent_id in $mode_file (refusing to write tree slot)" >&2
    exit 0
fi

slot="$HOME/vault/20-surface/company/tree/sessions/${session_id}.md"
if [ ! -f "$slot" ]; then
    echo "WARN: no slot file at $slot — slot was never written; skipping update"
    exit 0
fi

# An explicit id may arrive without any .cc-mode (e.g. closing from elsewhere).
# The slot recorded parent_id at write time, so take it from there.
if [ -z "$parent_id" ]; then
    parent_id=$( { grep -m1 '^parent_id:' "$slot" || true; } | sed 's/^parent_id:[[:space:]]*//')
    if [ -n "$parent_id" ] && ! [[ "$parent_id" =~ ^[0-9a-f]{22}$ ]]; then
        echo "WARN: malformed parent_id in $slot; not emitting a parent event" >&2
        parent_id=""
    fi
fi

# Say out loud whose slot this is. When identity came from the cwd walk this
# line is the only thing standing between a moved cwd and another lane's slot,
# so it names the source as well as the id.
if [ -n "$want_id" ]; then
    echo "identity: $session_id (from $want_src)"
elif [ "$resolved_from_cwd" -eq 1 ]; then
    echo "identity: $session_id (from $mode_file via cwd walk — pass --session-id to be explicit)"
else
    echo "identity: $session_id (from --mode-file $mode_file)"
fi

prev_status=$( { grep -m1 '^status:' "$slot" || true; } | sed 's/^status:[[:space:]]*//')
if [ "$prev_status" = "completed" ]; then
    prev_ended=$( { grep -m1 '^ended_at:' "$slot" || true; } | sed 's/^ended_at:[[:space:]]*//')
    echo "WARN: slot $session_id is ALREADY status=completed (ended_at: $prev_ended)." >&2
    echo "      Keeping the original ended_at. If you meant to close a different" >&2
    echo "      session, re-run with --session-id <your id>." >&2
fi

ended_at=$(date -Iseconds)

# Both substitutions are no-ops on an already-completed slot, which is what
# keeps the slot write itself idempotent.
sed -i "s/^status: running$/status: completed/" "$slot"
sed -i "s/^ended_at:$/ended_at: $ended_at/" "$slot"

echo "tree slot updated: $slot"

if [ -n "$parent_id" ]; then
    parent_events="$HOME/vault/20-surface/company/tree/sessions/${parent_id}.events"
    if [ -d "$parent_events" ]; then
        # Idempotency guard: dedupe on (child session_id, verb=completion). A
        # completion already on the record means this child has been reported;
        # appending again would show the parent one child completing twice.
        # Two shapes count as "already reported": the legacy heading this
        # script used to write, and — since cc-event-emit.sh stamps events
        # with the EMITTER's id — a rich completion the child wrote itself
        # per the dispatch-brief protocol. Skipping the mechanical notice in
        # that second case is deliberate: the 2026-09-03 audit counted 9
        # no-content /end notices shadowing 5 rich child-authored summaries
        # (delegation.md §4); one completion per child is the contract.
        existing=""
        for e in "$parent_events"/[0-9]*-*.md; do
            [ -f "$e" ] || continue
            grep -q '^verb: completion$' "$e" || continue
            if grep -qxF "# Child session completed: $session_id" "$e" \
               || grep -qxF "session_id: $session_id" "$e"; then
                existing="$e"
                break
            fi
        done

        if [ -n "$existing" ]; then
            echo "completion event: already recorded at $existing — not appending a duplicate"
        else
            # The body carries everything a MECHANICAL writer can know:
            # the fact of completion, the slot, and whether the task-folder
            # report exists. Substance beyond that is the child's job
            # (cc-event-emit.sh enforces it on child-authored completions).
            task_id=$( { grep -m1 '^task_id:' "$slot" || true; } | sed 's/^task_id:[[:space:]]*//')
            report="$HOME/vault/20-surface/company/tasks/${task_id:-unknown}/report.md"
            if [ -f "$report" ]; then
                report_line="report: $report ($(wc -c < "$report" | tr -d ' ') bytes)"
            else
                report_line="report: NONE at $report — outcome must be in this dir's rich completion event, or is missing"
            fi
            body="The child session reported normal completion via its close bookend.
slot: $HOME/vault/20-surface/company/tree/sessions/${session_id}.md
$report_line"

            emit_sh="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/cc-event-emit.sh"
            if [ -f "$emit_sh" ] && out=$(bash "$emit_sh" --dir "$parent_events" \
                    --session-id "$session_id" --verb completion --severity normal \
                    --title "Child session completed: $session_id" \
                    --body "$body" </dev/null); then
                echo "completion event: $out"
            else
                echo "WARN: cc-event-emit.sh unavailable — falling back to legacy sequential event naming" >&2
                next=$(printf "%04d" $(( $(find "$parent_events" -name '*.md' 2>/dev/null | wc -l) + 1 )))
                cat > "$parent_events/${next}-completion.md" <<EOF
---
event_id: $next
session_id: $parent_id
emitted_at: $ended_at
verb: completion
severity: normal
---

# Child session completed: $session_id

$body
EOF
                echo "completion event: $parent_events/${next}-completion.md"
            fi
        fi
    fi
fi
