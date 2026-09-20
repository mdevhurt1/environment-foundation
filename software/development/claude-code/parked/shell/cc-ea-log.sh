#!/usr/bin/env bash
# cc-ea-log.sh — append ONE line per EA action to the action trail.
#
# Why (AI_ST-73): the 2026-09-03 audit found a 1h50m43s artifact-free gap —
# 27% of the EA session, larger than all measured mechanics and judgement
# combined — that no artifact on any surface could attribute. The CEO's
# "mechanics vs judgement" question is answerable to ±10% at best until the
# EA leaves *some* action trail. A one-line-per-action log suffices; a full
# transcript is not required. This is that log.
#
# The mechanized helpers (cc-branch --brief, cc-land-child.sh) call this
# automatically; the EA calls it by hand (via the cc-ea-log shell function)
# for judgement actions the helpers cannot see — report reads, brief
# composition, escalation rulings — so the split stops being unknowable.
#
# Format — append-only, one line, five ` | `-separated fields:
#
#   <ISO-8601 stamp> | <session-id or -> | <verb> | <task or -> | <free text>
#
# The stamp is computed here (same rule as cc-event-emit.sh: machine-stamped,
# no override flag). Verbs are constrained to [a-z][a-z0-9-]* so the trail
# stays greppable; the free text is scrubbed of newlines. Suggested verbs —
# mechanics: dispatch, brief, flip, merge, reclaim, nudge, marker, teardown;
# judgement: read-report, compose-brief, ticket, ruling, note.
#
# Usage:
#   cc-ea-log.sh [--task <task-id>] [--session-id <id>] [--file <path>] <verb> [text...]
#
# The file defaults to $CC_EA_LOG_FILE, then
# ~/vault/20-surface/company/_command-center/state/ea-actions.log.
# Exit codes: 0 appended; 2 usage. Never blocks a caller on identity: an
# unresolvable session id is recorded as "-".

set -uo pipefail

usage() {
    cat <<'USAGE'
usage: cc-ea-log.sh [--task <task-id>] [--session-id <id>] [--file <path>] <verb> [text...]

  <verb>            Action verb, [a-z][a-z0-9-]*. Mechanics: dispatch, brief,
                    flip, merge, reclaim, nudge, marker, teardown. Judgement:
                    read-report, compose-brief, ticket, ruling, note.
  [text...]         Free-text description; joined with spaces, newlines removed.
  --task <id>       Task the action concerns (column 4; default "-").
  --session-id <id> Acting session (column 2; default: $CC_SESSION_ID, then
                    the nearest .cc-mode above $PWD, then "-").
  --file <path>     Log file (default: $CC_EA_LOG_FILE, then
                    ~/vault/20-surface/company/_command-center/state/ea-actions.log)
USAGE
}

TASK="-"
ARG_SID=""
FILE="${CC_EA_LOG_FILE:-$HOME/vault/20-surface/company/_command-center/state/ea-actions.log}"

while [ $# -gt 0 ]; do
    case "$1" in
        --task) [ $# -ge 2 ] || { echo "ERROR: --task needs a value" >&2; exit 2; }
                TASK="$2"; shift 2 ;;
        --task=*) TASK="${1#*=}"; shift ;;
        --session-id) [ $# -ge 2 ] || { echo "ERROR: --session-id needs a value" >&2; exit 2; }
                ARG_SID="$2"; shift 2 ;;
        --session-id=*) ARG_SID="${1#*=}"; shift ;;
        --file) [ $# -ge 2 ] || { echo "ERROR: --file needs a value" >&2; exit 2; }
                FILE="$2"; shift 2 ;;
        --file=*) FILE="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
        *) break ;;
    esac
done

[ $# -ge 1 ] || { echo "ERROR: a verb is required" >&2; usage >&2; exit 2; }
VERB="$1"; shift
if ! [[ "$VERB" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "ERROR: verb must match [a-z][a-z0-9-]* (keeps the trail greppable); got: $VERB" >&2
    exit 2
fi

TEXT="$*"
TEXT=${TEXT//$'\n'/ }
TEXT=${TEXT//$'\r'/}
TASK=${TASK//$'\n'/ }
TASK=${TASK//$'\r'/}
[ -z "$TASK" ] && TASK="-"

SID="$ARG_SID"
[ -z "$SID" ] && SID="${CC_SESSION_ID:-}"
if [ -z "$SID" ]; then
    d="$PWD"
    while [ "$d" != "/" ]; do
        if [ -f "$d/.cc-mode" ]; then
            SID=$( { grep '^session_id=' "$d/.cc-mode" || true; } | cut -d= -f2-)
            break
        fi
        d=$(dirname "$d")
    done
fi
[ -z "$SID" ] && SID="-"
SID=${SID//$'\n'/}

mkdir -p "$(dirname "$FILE")"
# A single printf >> of one short line is an atomic O_APPEND write, so
# concurrent helpers (a dispatch wave) interleave by whole lines.
printf '%s | %s | %s | %s | %s\n' "$(date -Is)" "$SID" "$VERB" "$TASK" "$TEXT" >> "$FILE"
