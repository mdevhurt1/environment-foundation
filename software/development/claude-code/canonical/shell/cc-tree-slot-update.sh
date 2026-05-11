#!/usr/bin/env bash
# cc-tree-slot-update — mark the session's tree slot completed at session end.
#
# Called by the end-conversation skill (Step 7). Sets status=completed and
# ended_at=<now> in the slot file, and if .cc-mode declares a parent_id whose
# events directory exists, appends a `completion` event there.
#
# No-op (exit 0 with a WARN) if .cc-mode is missing, has no session_id, or
# the slot file was never written (older sessions, bare launches).

set -euo pipefail

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
    echo "no .cc-mode found — skipping slot update"
    exit 0
fi

# grep || true: a legacy .cc-mode predating Phase 1 won't have these fields;
# pipefail would otherwise abort before we reach the empty-check below.
session_id=$( { grep '^session_id=' "$mode_file" || true; } | cut -d= -f2-)
parent_id=$( { grep '^parent_id=' "$mode_file" || true; } | cut -d= -f2-)
if [ -z "$session_id" ]; then
    echo "WARN: no session_id; skipping slot update"
    exit 0
fi

slot="$HOME/vault/20-surface/company/tree/sessions/${session_id}.md"
if [ ! -f "$slot" ]; then
    echo "WARN: no slot file at $slot — slot was never written; skipping update"
    exit 0
fi

ended_at=$(date -Iseconds)

sed -i "s/^status: running$/status: completed/" "$slot"
sed -i "s/^ended_at:$/ended_at: $ended_at/" "$slot"

echo "tree slot updated: $slot"

if [ -n "$parent_id" ]; then
    parent_events="$HOME/vault/20-surface/company/tree/sessions/${parent_id}.events"
    if [ -d "$parent_events" ]; then
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

The child session reported normal completion via /end.
See its slot at \`$HOME/vault/20-surface/company/tree/sessions/${session_id}.md\`.
EOF
        echo "completion event: $parent_events/${next}-completion.md"
    fi
fi
