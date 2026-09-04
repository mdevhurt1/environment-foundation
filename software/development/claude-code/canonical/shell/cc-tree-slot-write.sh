#!/usr/bin/env bash
# cc-tree-slot-write — write the per-session tree slot at session start.
#
# Called by the session-start skill (Step 3). Reads identity fields from the
# nearest .cc-mode (walking up from cwd) and writes
#   ~/vault/20-surface/company/tree/sessions/{session_id}.md
# plus an adjacent .events/ directory for append-only events.
#
# If .cc-mode declares a parent_id and that parent has an events directory,
# a `spawned` event is appended there -- once. Re-running (e.g. /start used to
# re-orient mid-session) will not append a second spawned event for the same
# child, which would otherwise show the parent one child spawning twice.
#
# Which .cc-mode is used, highest precedence first:
#   1. --mode-file <path>   an explicitly named .cc-mode
#   2. the nearest .cc-mode walking up from $PWD   (fallback)
#
# Every field written here comes from that one file, so resolving the wrong one
# writes another lane's slot. (2) does exactly that whenever the caller's cwd
# has moved -- a `cd` into another worktree earlier in the same compound command
# is enough. Pass --session-id to assert which session this must be: it is
# checked against the resolved .cc-mode and a mismatch is refused before any
# write. $CC_SESSION_ID is honoured the same way when set. See
# ~/vault/20-surface/claude-memory/feedback_tree_slot_helpers_resolve_from_cwd.md
#
# No-op (exit 0 with a WARN) if no .cc-mode is found or it lacks session_id —
# this covers older sessions predating Phase 1 and bare launches. Those are
# expected states, not faults, and must stay quiet-and-zero: making every early
# return fatal would break every non-wrapper launch on the box.
#
# Exit codes: 2 usage error, 3 refused session-id mismatch (both before any
# write), 4 the slot could not be written after a retry (INFRA-68). A genuine
# write failure is an ERROR, never a WARN — see the write block below for why.

set -euo pipefail

usage() {
    cat <<'USAGE'
usage: cc-tree-slot-write.sh [--session-id <id>] [--mode-file <path>]

  --session-id <id>   Assert this session's id (22-hex). The resolved .cc-mode
                      must agree, or the run is refused before writing.
  --mode-file <path>  Read identity from this .cc-mode rather than walking up
                      from the current working directory.
  -h, --help          Show this help.

With no arguments, identity is inferred from the nearest .cc-mode above $PWD,
which resolves the wrong session if the caller's cwd has moved.
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

# An explicit id beats the environment; either one asserts against .cc-mode.
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

# Find .cc-mode walking up from cwd, unless one was named explicitly.
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

if [ -z "$mode_file" ]; then
    echo "no .cc-mode found — skipping tree slot"
    exit 0
fi

# grep || true: a legacy .cc-mode predating Phase 1 won't have session_id /
# parent_id; pipefail would otherwise abort before the empty-check below.
session_id=$( { grep '^session_id=' "$mode_file" || true; } | cut -d= -f2-)
if [ -z "$session_id" ]; then
    echo "WARN: .cc-mode has no session_id; skipping tree slot"
    exit 0
fi

# Consistency assertion: when the caller states who it is, the .cc-mode we
# resolved must agree. Disagreement means the cwd is pointing at another lane;
# refuse before touching anything.
if [ -n "$want_id" ] && [ "$want_id" != "$session_id" ]; then
    echo "ERROR: session id mismatch -- refusing to write a slot that is not yours." >&2
    echo "       $want_src says: $want_id" >&2
    echo "       $mode_file says: $session_id" >&2
    echo "       cwd is $PWD; run this from your own worktree, or pass --mode-file." >&2
    exit 3
fi

parent_id=$( { grep '^parent_id=' "$mode_file" || true; } | cut -d= -f2-)
# Same grep || true guard as above: commit 85d2407 added it for session_id and
# parent_id but not for these four, so a .cc-mode missing any one of them still
# aborted the script at exit 1 under pipefail -- silently, before the WARN that
# the header promises for legacy files.
slug=$( { grep '^slug=' "$mode_file" || true; } | cut -d= -f2-)
mode=$( { grep '^mode=' "$mode_file" || true; } | cut -d= -f2-)
started_at=$( { grep '^started_at=' "$mode_file" || true; } | cut -d= -f2-)
parent_repo=$( { grep '^parent_repo=' "$mode_file" || true; } | cut -d= -f2-)
# Model stamp. Absent in any .cc-mode written before the model policy landed,
# and absent for bare launches -- an empty value is legitimate, so these stay
# WARN-free. Same `grep || true` guard as the four fields above.
model=$( { grep '^model=' "$mode_file" || true; } | cut -d= -f2-)
model_source=$( { grep '^model_source=' "$mode_file" || true; } | cut -d= -f2-)

# Validate identifiers before interpolating into paths/heredocs. session_id
# and parent_id must match the 22-hex format minted by __cc_mint_session_id;
# parent_id may also legitimately be empty (root sessions). slug and mode
# flow into the heredoc body — strip newlines and restrict to safe chars.
if ! [[ "$session_id" =~ ^[0-9a-f]{22}$ ]]; then
    echo "WARN: malformed session_id in $mode_file (refusing to write tree slot)" >&2
    exit 0
fi
if [ -n "$parent_id" ] && ! [[ "$parent_id" =~ ^[0-9a-f]{22}$ ]]; then
    echo "WARN: malformed parent_id in $mode_file (refusing to write tree slot)" >&2
    exit 0
fi
slug=${slug//$'\n'/}
mode=${mode//$'\n'/}
if ! [[ "$slug" =~ ^[a-zA-Z0-9_./-]*$ ]]; then
    echo "WARN: malformed slug in $mode_file (refusing to write tree slot)" >&2
    exit 0
fi
if ! [[ "$mode" =~ ^[a-zA-Z0-9_./-]*$ ]]; then
    echo "WARN: malformed mode in $mode_file (refusing to write tree slot)" >&2
    exit 0
fi
# model/model_source flow into the YAML frontmatter, so they are constrained to
# characters that cannot break out of a scalar. Square brackets are allowed
# because exact model ids carry a context variant: claude-opus-5[1m]. A
# malformed value is blanked with a WARN rather than aborting the whole slot
# write -- losing the model stamp is worth less than losing the session's tree
# presence entirely.
#
# The class is written ^[][a-zA-Z0-9._:-]*$ -- ] FIRST and - LAST -- because a
# POSIX bracket expression has no backslash escaping: the intuitive
# [a-zA-Z0-9._:\[\]-] is parsed as a class ending at the first ] and silently
# matches nothing useful, which blanked every stamped model on the first run
# of this code.
model=${model//$'\n'/}
model_source=${model_source//$'\n'/}
if ! [[ "$model" =~ ^[][a-zA-Z0-9._:-]*$ ]]; then
    echo "WARN: malformed model in $mode_file (recording as empty)" >&2
    model=""
fi
if ! [[ "$model_source" =~ ^[a-zA-Z0-9._:-]*$ ]]; then
    echo "WARN: malformed model_source in $mode_file (recording as empty)" >&2
    model_source=""
fi

# task_id: defaults to slug; Plane-backed tasks can be edited in the slot later.
task_id="$slug"

slot="$HOME/vault/20-surface/company/tree/sessions/${session_id}.md"

# Rewriting an existing slot resets it to status=running. That is right for a
# genuinely resumed session, but it also silently reopens a session that had
# already closed -- which reads to the parent as a finished lane going live
# again. Don't change the semantics here (resume is cc-continue's call), but
# don't let it happen quietly either.
if [ -f "$slot" ]; then
    prev_status=$( { grep -m1 '^status:' "$slot" || true; } | sed 's/^status:[[:space:]]*//')
    if [ "$prev_status" = "completed" ]; then
        echo "WARN: slot $session_id already exists with status=completed;" >&2
        echo "      rewriting it resets the session to running." >&2
    fi
fi

# The slot is this session's ONLY presence in the tree: the company-status
# scan, the reclaim gate and the parent's child list all key off this one
# file. A session that fails to write it runs its whole lifecycle invisible --
# which is precisely what happened to aabd7e4c460747558046f2 on 2026-09-04
# (INFRA-68). So this write does not get to fail quietly.
#
# Three properties, in order of how much each one was missing before:
#   1. VERIFIED. The success line is printed only after the slot is read back
#      non-empty, never merely because `cat` returned -- the success message is
#      bound to the operation it claims
#      (feedback_bind_the_success_message_to_the_operation).
#   2. RETRIED, ONCE. The realistic transient here is the vault tree being
#      momentarily absent or busy, not a permission fault. The bound is 2
#      attempts by construction, not by a timeout: a retry loop that outlives
#      the fault it was written for is a worse bug than the one it fixes.
#   3. LOUD. A final failure is an ERROR on stderr that names the session, the
#      path, and what has been LOST -- not a WARN. The 2026-09-04 incident
#      survived a close-time WARN that was read, understood as by-design, and
#      scrolled past; a message that does not state its consequence gets
#      triaged as noise.
events_dir="${slot%.md}.events"

write_slot_attempt() {
    mkdir -p "$(dirname "$slot")" || return 1
    mkdir -p "$events_dir" || return 1
    cat > "$slot" <<EOF
---
session_id: $session_id
parent_id: $parent_id
task_id: $task_id
slug: $slug
mode: $mode
status: running
started_at: $started_at
ended_at:
worktree: $(dirname "$mode_file")
parent_repo: $parent_repo
model: $model
model_source: $model_source
---

# Session $session_id

Started: $started_at
Mode: $mode
EOF
}

# Condition context, so `set -e` does not abort the script inside the helper --
# a failed attempt must reach the retry, not kill the shell.
slot_written=0
for attempt in 1 2; do
    if write_slot_attempt && [ -s "$slot" ]; then
        slot_written=1
        break
    fi
    [ "$attempt" -eq 1 ] && \
        echo "WARN: tree slot write failed — retrying once before giving up" >&2
done

if [ "$slot_written" -ne 1 ]; then
    echo "ERROR: could not write the tree slot for session $session_id" >&2
    echo "       slot: $slot" >&2
    echo "       Both attempts failed. Until this file exists the session is" >&2
    echo "       INVISIBLE to the company-status scan, to the reclaim gate and" >&2
    echo "       to its parent's child list — it will run to completion with" >&2
    echo "       nobody able to see it. Fix the path above, then re-run:" >&2
    echo "         bash ~/.claude/cc-tree-slot-write.sh" >&2
    exit 4
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

echo "tree slot: $slot"

# Append a spawned event to the parent's events directory, if it exists.
if [ -n "$parent_id" ]; then
    parent_events="$HOME/vault/20-surface/company/tree/sessions/${parent_id}.events"
    if [ -d "$parent_events" ]; then
        # Idempotency guard: dedupe on (child session_id, verb=spawned). This
        # script is re-run whenever session-start runs again (/start re-orients
        # mid-session); without this the parent sees the child spawn twice.
        existing=""
        for e in "$parent_events"/[0-9]*-*.md; do
            [ -f "$e" ] || continue
            if grep -q '^verb: spawned$' "$e" \
               && grep -qxF "# Child session spawned: $session_id" "$e"; then
                existing="$e"
                break
            fi
        done

        if [ -n "$existing" ]; then
            echo "spawned event: already recorded at $existing — not appending a duplicate"
        else
            # Events are named and stamped by cc-event-emit.sh (AI_ST-74):
            # monotonic epoch-based leading numbers, machine-true emitted_at.
            # The old sequential NNNN- naming this block used to do is what
            # poisoned the numeric read marker once epoch-named events (from
            # dispatched children following the brief protocol) shared a dir.
            # The helper sits beside this script in canonical/shell/, so
            # resolve it relative to this file's real path — that works both
            # from the repo and through the ~/.claude symlink.
            emit_sh="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/cc-event-emit.sh"
            if [ -f "$emit_sh" ] && out=$(bash "$emit_sh" --dir "$parent_events" \
                    --session-id "$session_id" --verb spawned --severity info \
                    --title "Child session spawned: $session_id" \
                    --body "slug=$slug mode=$mode" </dev/null); then
                echo "spawned event: $out"
            else
                # Legacy inline fallback: a spawned event the parent can see
                # is worth more than naming purity. WARN so the gap is loud.
                echo "WARN: cc-event-emit.sh unavailable — falling back to legacy sequential event naming" >&2
                next=$(printf "%04d" $(( $(find "$parent_events" -name '*.md' 2>/dev/null | wc -l) + 1 )))
                cat > "$parent_events/${next}-spawned.md" <<EOF
---
event_id: $next
session_id: $parent_id
emitted_at: $(date -Iseconds)
verb: spawned
severity: info
---

# Child session spawned: $session_id

slug=$slug mode=$mode
EOF
                echo "spawned event: $parent_events/${next}-spawned.md"
            fi
        fi
    fi
fi
