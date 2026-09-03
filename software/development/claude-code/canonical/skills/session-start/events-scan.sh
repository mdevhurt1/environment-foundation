#!/usr/bin/env bash
# events-scan.sh — session-start Step 4: list this session's unread events.
#
# Extracted verbatim from the Step 4 inline block (INFRA-52) so the skill
# body stops paying its byte cost every session. Behavior is part of the
# session-start contract: numeric .read-up-to threshold marker, zero-padded
# lexical-sort ordering (see test_tree_slot_events.sh, test_event_emit.sh),
# silent exit 0 when there is no .cc-mode / session_id / events dir.

mode_file=$(dir=$(pwd); while [ "$dir" != / ]; do [ -f "$dir/.cc-mode" ] && echo "$dir/.cc-mode" && break; dir=$(dirname "$dir"); done)
[ -z "$mode_file" ] && exit 0

my_session_id=$(grep '^session_id=' "$mode_file" | cut -d= -f2-)
[ -z "$my_session_id" ] && exit 0

events_dir=~/vault/20-surface/company/tree/sessions/${my_session_id}.events
[ ! -d "$events_dir" ] && exit 0

marker="$events_dir/.read-up-to"
last_read=0
[ -f "$marker" ] && last_read=$(cat "$marker")

# Filenames are zero-padded, so lexical sort = chronological.
unread=$(find "$events_dir" -maxdepth 1 -name '[0-9]*-*.md' -type f 2>/dev/null | sort | awk -v threshold="$last_read" -F'/' '{
    fname=$NF
    n=fname; sub(/-.*$/, "", n); gsub(/^0+/, "", n); if (n=="") n="0"
    if (n+0 > threshold+0) print $0
}')

if [ -z "$unread" ]; then
    echo "no unread events"
else
    echo "unread events:"
    while IFS= read -r f; do
        echo "  --- $f ---"
        head -20 "$f"
        echo
    done <<< "$unread"

    # Highest event id present (read or unread); the agent bumps the marker
    # only after actually processing the events.
    highest=$(find "$events_dir" -maxdepth 1 -name '[0-9]*-*.md' -type f 2>/dev/null \
        | awk -F'/' '{fname=$NF; n=fname; sub(/-.*$/, "", n); gsub(/^0+/, "", n); if (n=="") n="0"; print n+0}' \
        | sort -n | tail -1)
    echo "(after deciding on each event, mark them read with:"
    echo "  echo $highest > '$marker' )"
fi
