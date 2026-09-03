#!/usr/bin/env bash
# cc-event-emit.sh — write one event file into a session's .events/ directory
# with a MACHINE-STAMPED timestamp and a collision-safe, monotonic name.
#
# Why this exists (AI_ST-74, evidence: workflow-audit delegation.md §4):
#
#   * Hand-authored `emitted_at` stamps are fiction. In the 2026-09-03 worked
#     example 4 of 6 hand-written stamps were wrong — two by more than an hour,
#     one IMPOSSIBLE (later than its author session's end). Helper-written
#     events matched file mtime to the second. So the stamp is computed here,
#     at write time, and there is no flag to override it.
#
#   * Mixed naming poisons the read marker. Events dirs accumulated both
#     `NNNN-<verb>.md` (sequential, from cc-tree-slot-write.sh) and
#     `<epoch>-<verb>.md` (from dispatched children following the brief
#     protocol). The session-start Step-4 marker logic treats the filename's
#     leading number as a monotonic cursor: once `.read-up-to` holds an epoch
#     (~1.8e9), every later `NNNN-` event compares BELOW it and is unread
#     forever. This helper names every event
#
#         n = max( epoch-seconds-now, highest-leading-number-in-dir + 1 )
#
#     so the leading number strictly increases regardless of what naming era
#     the directory carries, and the numeric-threshold marker logic is correct
#     by construction. (In the steady state n IS the epoch; n only exceeds it
#     when two events land in the same second, or when a dir already contains
#     a number from the future — both of which this rule absorbs.)
#
# CONTENT CONVENTION (the enforcement half of AI_ST-74):
#   A `completion` event must carry the outcome, not a pointer to it. 5 of 10
#   children in the worked example shipped substance only in their task-folder
#   reports, leaving the event channel empty for the parent. Minimum: THREE
#   non-empty body lines — what shipped (per ticket if several), what needs
#   the parent's action, and the report path. Thinner completions are REFUSED
#   (exit 5); --allow-thin exists for the rare event that genuinely has less
#   to say, and says so on the record.
#
# Usage:
#   cc-event-emit.sh --dir <events-dir> --verb <verb> [options]
#   cc-event-emit.sh --to-session <22-hex id> --verb <verb> [options]
#
# The body comes from --body <text>, --body-file <path> (`-` = stdin), or
# stdin when it is not a terminal. Prints the path of the written file.
#
# Exit codes: 0 written; 2 usage; 3 no emitter identity; 4 events dir missing;
#             5 completion body too thin (see above).

set -uo pipefail

usage() {
    cat <<'USAGE'
usage: cc-event-emit.sh (--dir <events-dir> | --to-session <id>) --verb <verb> [options]

  --dir <path>         Events directory to write into (must already exist).
  --to-session <id>    Address by session id: resolves to
                       <tree-dir>/<id>.events (see --tree-dir).
  --verb <verb>        Event verb: lowercase [a-z0-9-], e.g. blocker,
                       question, status, completion, decision, spawned.
  --severity <s>       info | normal | critical (default: normal).
  --title <text>       Heading line (default: the verb).
  --body <text>        Event body, inline.
  --body-file <path>   Event body from a file; `-` reads stdin.
  --session-id <id>    EMITTER session id. Default: $CC_SESSION_ID, then the
                       nearest .cc-mode above $PWD. Refused if unresolvable.
  --tree-dir <path>    Sessions dir for --to-session
                       (default ~/vault/20-surface/company/tree/sessions).
  --allow-thin         Permit a completion body under 3 non-empty lines.
  -h, --help           Show this help.

CONTENT CONVENTION — the events channel carries decisions, not pointers:
  * completion: >= 3 non-empty body lines — (1) outcome per ticket/deliverable,
    (2) what needs the parent's action (or "none"), (3) the report path.
    Enforced here; --allow-thin overrides on the record.
  * blocker/question: what you need AND what you already ruled out.
  * emitted_at / event_id are stamped by this helper and never hand-authored.
USAGE
}

EVENTS_DIR=""
TO_SESSION=""
VERB=""
SEVERITY="normal"
TITLE=""
BODY=""
BODY_SET=0
BODY_FILE=""
ARG_SID=""
TREE_DIR="$HOME/vault/20-surface/company/tree/sessions"
ALLOW_THIN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) [ $# -ge 2 ] || { echo "ERROR: --dir needs a value" >&2; exit 2; }
               EVENTS_DIR="$2"; shift 2 ;;
        --dir=*) EVENTS_DIR="${1#*=}"; shift ;;
        --to-session) [ $# -ge 2 ] || { echo "ERROR: --to-session needs a value" >&2; exit 2; }
               TO_SESSION="$2"; shift 2 ;;
        --to-session=*) TO_SESSION="${1#*=}"; shift ;;
        --verb) [ $# -ge 2 ] || { echo "ERROR: --verb needs a value" >&2; exit 2; }
               VERB="$2"; shift 2 ;;
        --verb=*) VERB="${1#*=}"; shift ;;
        --severity) [ $# -ge 2 ] || { echo "ERROR: --severity needs a value" >&2; exit 2; }
               SEVERITY="$2"; shift 2 ;;
        --severity=*) SEVERITY="${1#*=}"; shift ;;
        --title) [ $# -ge 2 ] || { echo "ERROR: --title needs a value" >&2; exit 2; }
               TITLE="$2"; shift 2 ;;
        --title=*) TITLE="${1#*=}"; shift ;;
        --body) [ $# -ge 2 ] || { echo "ERROR: --body needs a value" >&2; exit 2; }
               BODY="$2"; BODY_SET=1; shift 2 ;;
        --body=*) BODY="${1#*=}"; BODY_SET=1; shift ;;
        --body-file) [ $# -ge 2 ] || { echo "ERROR: --body-file needs a value" >&2; exit 2; }
               BODY_FILE="$2"; shift 2 ;;
        --body-file=*) BODY_FILE="${1#*=}"; shift ;;
        --session-id) [ $# -ge 2 ] || { echo "ERROR: --session-id needs a value" >&2; exit 2; }
               ARG_SID="$2"; shift 2 ;;
        --session-id=*) ARG_SID="${1#*=}"; shift ;;
        --tree-dir) [ $# -ge 2 ] || { echo "ERROR: --tree-dir needs a value" >&2; exit 2; }
               TREE_DIR="$2"; shift 2 ;;
        --tree-dir=*) TREE_DIR="${1#*=}"; shift ;;
        --allow-thin) ALLOW_THIN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# ------------------------------------------------------------- validation --
if [ -z "$VERB" ]; then
    echo "ERROR: --verb is required" >&2; exit 2
fi
if ! [[ "$VERB" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "ERROR: verb must match [a-z][a-z0-9-]* (it becomes part of a filename); got: $VERB" >&2
    exit 2
fi
case "$SEVERITY" in
    info|normal|critical) ;;
    *) echo "ERROR: severity must be info|normal|critical; got: $SEVERITY" >&2; exit 2 ;;
esac

if [ -n "$EVENTS_DIR" ] && [ -n "$TO_SESSION" ]; then
    echo "ERROR: pass --dir or --to-session, not both" >&2; exit 2
fi
if [ -n "$TO_SESSION" ]; then
    if ! [[ "$TO_SESSION" =~ ^[0-9a-f]{22}$ ]]; then
        echo "ERROR: --to-session must be a 22-hex session id; got: $TO_SESSION" >&2; exit 2
    fi
    EVENTS_DIR="$TREE_DIR/${TO_SESSION}.events"
fi
if [ -z "$EVENTS_DIR" ]; then
    echo "ERROR: an events directory is required (--dir or --to-session)" >&2; exit 2
fi
if [ ! -d "$EVENTS_DIR" ]; then
    # Deliberately NOT mkdir'd here: an events dir is created by the tree-slot
    # writer when the addressed session starts. A missing dir means the address
    # is wrong (typo, dead session), and inventing it would hide that.
    echo "ERROR: events dir does not exist: $EVENTS_DIR" >&2
    echo "       (dirs are created by cc-tree-slot-write.sh at session start;" >&2
    echo "        a missing one means the addressee is wrong, not that you should mkdir)" >&2
    exit 4
fi

# Emitter identity: explicit arg > $CC_SESSION_ID > nearest .cc-mode.
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
if [ -z "$SID" ]; then
    echo "ERROR: cannot resolve the emitting session's id" >&2
    echo "       (no --session-id, no \$CC_SESSION_ID, no .cc-mode above $PWD)" >&2
    exit 3
fi
if ! [[ "$SID" =~ ^[0-9a-f]{22}$ ]]; then
    echo "ERROR: emitter session id is not 22-hex: $SID" >&2; exit 3
fi

# ------------------------------------------------------------------- body --
if [ -n "$BODY_FILE" ]; then
    if [ "$BODY_FILE" = "-" ]; then
        BODY=$(cat)
    else
        [ -f "$BODY_FILE" ] || { echo "ERROR: body file not found: $BODY_FILE" >&2; exit 2; }
        BODY=$(cat "$BODY_FILE")
    fi
elif [ "$BODY_SET" -eq 0 ] && [ ! -t 0 ]; then
    BODY=$(cat)
fi

if [ "$VERB" = "completion" ] && [ "$ALLOW_THIN" -eq 0 ]; then
    nonempty=$(printf '%s\n' "$BODY" | grep -c '[^[:space:]]' || true)
    if [ "${nonempty:-0}" -lt 3 ]; then
        echo "REFUSED: a completion event must carry the outcome, not a pointer to it." >&2
        echo "  Minimum 3 non-empty body lines: (1) outcome per ticket/deliverable," >&2
        echo "  (2) what needs the parent's action (or 'none'), (3) the report path." >&2
        echo "  Got ${nonempty:-0} non-empty line(s). Pass --allow-thin to override" >&2
        echo "  on the record. (AI_ST-74: 5/10 audit children shipped substance" >&2
        echo "  only in reports; the event channel alone was insufficient.)" >&2
        exit 5
    fi
fi

[ -z "$TITLE" ] && TITLE="$VERB"
# The title is a single heading line; line breaks in it would corrupt the
# frontmatter/body structure downstream greps rely on.
TITLE=${TITLE//$'\n'/ }
TITLE=${TITLE//$'\r'/}

# ------------------------------------------------- monotonic, atomic name --
# n = max(epoch, highest existing leading number + 1). See header.
epoch=$(date +%s)
max=0
for f in "$EVENTS_DIR"/[0-9]*-*.md; do
    [ -e "$f" ] || continue
    base=${f##*/}
    lead=${base%%-*}
    # Strip leading zeros so 0028 compares as 28, not octal.
    lead=$((10#$lead))
    [ "$lead" -gt "$max" ] && max=$lead
done
n=$epoch
[ "$n" -le "$max" ] && n=$((max + 1))

stamp=$(date -Is)

tmp=$(mktemp "$EVENTS_DIR/.cc-event.XXXXXX") || {
    echo "ERROR: cannot write in $EVENTS_DIR" >&2; exit 4; }
cat > "$tmp" <<EOF
---
event_id: $n
session_id: $SID
emitted_at: $stamp
verb: $VERB
severity: $SEVERITY
---

# $TITLE

$BODY
EOF

# Land the file with ln (atomic, refuses to clobber). If another writer took
# the name — or any file shares the leading number, which would break the
# strictly-increasing cursor — advance and retry.
while :; do
    taken=0
    for f in "$EVENTS_DIR/$n-"*.md; do [ -e "$f" ] && { taken=1; break; }; done
    if [ "$taken" -eq 0 ] && ln "$tmp" "$EVENTS_DIR/$n-$VERB.md" 2>/dev/null; then
        break
    fi
    n=$((n + 1))
    # event_id must match the filename's leading number; rewrite it.
    sed -i "1,4s/^event_id: .*/event_id: $n/" "$tmp"
done
rm -f "$tmp"

printf '%s\n' "$EVENTS_DIR/$n-$VERB.md"
