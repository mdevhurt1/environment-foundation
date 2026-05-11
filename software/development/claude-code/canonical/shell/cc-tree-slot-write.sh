#!/usr/bin/env bash
# cc-tree-slot-write — write the per-session tree slot at session start.
#
# Called by the session-start skill (Step 3). Reads identity fields from the
# nearest .cc-mode (walking up from cwd) and writes
#   ~/vault/20-surface/company/tree/sessions/{session_id}.md
# plus an adjacent .events/ directory for append-only events.
#
# If .cc-mode declares a parent_id and that parent has an events directory,
# a `spawned` event is appended there.
#
# No-op (exit 0 with a WARN) if no .cc-mode is found or it lacks session_id —
# this covers older sessions predating Phase 1 and bare launches.

set -euo pipefail

# Find .cc-mode walking up from cwd.
mode_file=""
d="$PWD"
while [ "$d" != "/" ]; do
    if [ -f "$d/.cc-mode" ]; then
        mode_file="$d/.cc-mode"
        break
    fi
    d=$(dirname "$d")
done

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

parent_id=$( { grep '^parent_id=' "$mode_file" || true; } | cut -d= -f2-)
slug=$(grep '^slug=' "$mode_file" | cut -d= -f2-)
mode=$(grep '^mode=' "$mode_file" | cut -d= -f2-)
started_at=$(grep '^started_at=' "$mode_file" | cut -d= -f2-)
parent_repo=$(grep '^parent_repo=' "$mode_file" | cut -d= -f2-)

# task_id: defaults to slug; Plane-backed tasks can be edited in the slot later.
task_id="$slug"

slot="$HOME/vault/20-surface/company/tree/sessions/${session_id}.md"
mkdir -p "$(dirname "$slot")"
mkdir -p "${slot%.md}.events"

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
---

# Session $session_id

Started: $started_at
Mode: $mode
EOF

echo "tree slot: $slot"

# Append a spawned event to the parent's events directory, if it exists.
if [ -n "$parent_id" ]; then
    parent_events="$HOME/vault/20-surface/company/tree/sessions/${parent_id}.events"
    if [ -d "$parent_events" ]; then
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
