#!/usr/bin/env bash
# cc-ring-scan — read-only survey of the vault's surface ring.
#
# Called by the ring-maintenance skill (Phase 1). Reads the surface ring and
# prints a sectioned, tab-separated report to stdout. Classifies findings into
# auto-appliable fixes, proposals, report-only observations, and anomalies.
#
# THIS SCRIPT NEVER WRITES. No mv, rm, mkdir, touch, or redirection to any
# path. The EA executes every mutation; this script only surveys. Keep it that
# way — the read-only property is what makes it safe to run at any time.
#
# Exit 2 if the vault is not mounted. Otherwise exit 0 even when findings
# exist; findings are data, not errors.

set -euo pipefail

VAULT="$HOME/vault"
SURFACE="$VAULT/20-surface"
MEM="$SURFACE/claude-memory"
TREE="$SURFACE/company/tree/sessions"
TASKS="$SURFACE/company/tasks"
STATE="$SURFACE/company/_command-center/state"
MARKER="$STATE/.ring-maintenance-last-run"

SLOT_AGE_DAYS=${SLOT_AGE_DAYS:-14}
TASK_AGE_DAYS=${TASK_AGE_DAYS:-30}
BRIEF_AGE_DAYS=${BRIEF_AGE_DAYS:-30}
HEALTH_KEEP=${HEALTH_KEEP:-8}

if [ ! -d "$VAULT" ]; then
    echo "FAIL: vault not mounted at $VAULT" >&2
    exit 2
fi

now=$(date +%s)

ANOM=()
anom() { ANOM+=("$1"$'\t'"$2"); }

# ---- index sync (AUTO) ----
# Missing = file exists but MEMORY.md contains no line mentioning its basename.
# A file without description: frontmatter is NOT auto-addable — nothing
# synthesizes a description — so it is reported instead.
mem_files=0
MEM_ADD=()
MEM_NODESC=()
while IFS= read -r f; do
    b=$(basename "$f")
    [ "$b" = "MEMORY.md" ] && continue
    mem_files=$((mem_files + 1))
    if ! grep -qF "$b" "$MEM/MEMORY.md" 2>/dev/null; then
        d=$( { grep -m1 '^description:' "$f" || true; } | sed 's/^description: *//')
        if [ -z "$d" ]; then
            MEM_NODESC+=("$b")
        else
            MEM_ADD+=("$b"$'\t'"$d")
        fi
    fi
done < <(find "$MEM" -maxdepth 1 -name '*.md' -type f | sort)

# Dead = an index link target that no longer exists on disk.
MEM_DEAD=()
while IFS= read -r p; do
    [ -z "$p" ] && continue
    [ -f "$MEM/$p" ] || MEM_DEAD+=("$p")
done < <( { grep -oE '\]\([^)]*\.md\)' "$MEM/MEMORY.md" || true; } \
          | sed 's/^](//; s/)$//' | sort -u)

mem_indexed=$( { grep -c '^- \[' "$MEM/MEMORY.md" || true; } )
mem_sep_legacy=$( { grep -c ') -- ' "$MEM/MEMORY.md" || true; } )

# ---- tree slots (PROPOSE) ----
# Two passes. The first records the parent_id of every running slot so the
# second can refuse to archive a live child's parent — archiving it would
# silently break event delivery to a session that is still working.
declare -A RUNNING_PARENTS=()
declare -A RUNNING_TASKS=()
while IFS= read -r s; do
    st=$( { grep -m1 '^status:' "$s" || true; } | sed 's/^status: *//')
    [ "$st" = "running" ] || continue
    pid=$( { grep -m1 '^parent_id:' "$s" || true; } | sed 's/^parent_id: *//')
    [ -n "$pid" ] && RUNNING_PARENTS["$pid"]=1
    tid=$( { grep -m1 '^task_id:' "$s" || true; } | sed 's/^task_id: *//')
    [ -n "$tid" ] && RUNNING_TASKS["$tid"]=1
done < <(find "$TREE" -maxdepth 1 -name '*.md' -type f)

slots_total=0
slots_running=0
slots_terminal=0
SLOT_PROP=()
while IFS= read -r s; do
    slots_total=$((slots_total + 1))
    sid=$(basename "$s" .md)
    st=$( { grep -m1 '^status:' "$s" || true; } | sed 's/^status: *//')
    case "$st" in
        running)
            slots_running=$((slots_running + 1))
            continue
            ;;
        completed|abandoned|ended-by-user)
            slots_terminal=$((slots_terminal + 1))
            ;;
        *)
            anom "$s" "unrecognised status '$st'"
            continue
            ;;
    esac

    # Age from ended_at when present; abandoned slots often lack it, so fall
    # back to file mtime.
    ts=""
    ea=$( { grep -m1 '^ended_at:' "$s" || true; } | sed 's/^ended_at: *//')
    if [ -n "$ea" ]; then
        ts=$(date -d "$ea" +%s 2>/dev/null || echo "")
    fi
    [ -z "$ts" ] && ts=$(stat -c %Y "$s")
    age=$(( (now - ts) / 86400 ))
    [ "$age" -ge "$SLOT_AGE_DAYS" ] || continue

    if [ -n "${RUNNING_PARENTS[$sid]:-}" ]; then
        anom "$s" "terminal but is parent of a running slot — not eligible"
        continue
    fi

    ev="no"
    [ -d "${s%.md}.events" ] && ev="yes"
    SLOT_PROP+=("$sid"$'\t'"$st"$'\t'"$age"$'\t'"$ev")
done < <(find "$TREE" -maxdepth 1 -name '*.md' -type f | sort)

# ---- task folders (PROPOSE) ----
# Eligible = no file modified within TASK_AGE_DAYS AND no running slot claims
# that task_id. The running-slot check is what stops this archiving the folder
# of a session that is working right now.
tasks_count=0
tasks_bytes=0
TASK_PROP=()
while IFS= read -r t; do
    [ "$(basename "$t")" = "_archive" ] && continue
    tasks_count=$((tasks_count + 1))
    tid=$(basename "$t")
    bytes=$(du -sb "$t" 2>/dev/null | cut -f1)
    [ -z "$bytes" ] && bytes=0
    tasks_bytes=$((tasks_bytes + bytes))

    [ -n "${RUNNING_TASKS[$tid]:-}" ] && continue

    newest=$(find "$t" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
    if [ -z "$newest" ]; then
        anom "$t" "task folder contains no files"
        continue
    fi
    newest=${newest%.*}
    age=$(( (now - newest) / 86400 ))
    [ "$age" -ge "$TASK_AGE_DAYS" ] || continue
    TASK_PROP+=("$tid"$'\t'"$age"$'\t'"$bytes")
done < <(find "$TASKS" -mindepth 1 -maxdepth 1 -type d | sort)

# ---- state/ hygiene (PROPOSE) ----
# state/ is this skill's own working directory, so it is in remit — otherwise
# ring-health reports accumulate forever in the one place nothing collects.
# The protected set is never eligible under any age.
state_files=0
briefs_elig=0
STATE_PROP=()
PROTECTED="promotion-queue.md .ring-maintenance-last-run netmon"

is_protected() {
    local n="$1" p
    for p in $PROTECTED; do [ "$n" = "$p" ] && return 0; done
    return 1
}

if [ -d "$STATE" ]; then
    while IFS= read -r f; do
        n=$(basename "$f")
        state_files=$((state_files + 1))
        is_protected "$n" && continue
        case "$n" in
            *-brief.md)
                age=$(( (now - $(stat -c %Y "$f")) / 86400 ))
                if [ "$age" -ge "$BRIEF_AGE_DAYS" ]; then
                    STATE_PROP+=("$n"$'\t'"brief"$'\t'"$age")
                    briefs_elig=$((briefs_elig + 1))
                fi
                ;;
        esac
    done < <(find "$STATE" -maxdepth 1 -type f | sort)
fi

# ring-health reports: keep the most recent HEALTH_KEEP by the YYYY-MM-DD in
# the FILENAME, not by mtime — LiveSync rewrites mtimes and would reorder them.
health_reports=0
if [ -d "$STATE" ]; then
    mapfile -t HEALTH < <(find "$STATE" -maxdepth 1 -name 'ring-health-*.md' \
                          -printf '%f\n' 2>/dev/null | sort -r)
    health_reports=${#HEALTH[@]}
    i=0
    for h in ${HEALTH[@]+"${HEALTH[@]}"}; do
        i=$((i + 1))
        [ "$i" -le "$HEALTH_KEEP" ] && continue
        STATE_PROP+=("$h"$'\t'"health-report"$'\t'"0")
    done
fi

# ---- promotion backlog (AUTO fold + PROPOSE markers) ----
# The glob is promotion-* not promotion-candidates-*: the files present use
# three different naming patterns and the narrower glob catches only two.
QUEUE="$STATE/promotion-queue.md"
FOLD=()
if [ -d "$STATE" ]; then
    while IFS= read -r f; do
        n=$(basename "$f")
        [ "$n" = "promotion-queue.md" ] && continue
        # *-brief.md belongs to the state-hygiene remit (PROPOSE archive), not
        # the promotion fold — a session brief auto-folded into the queue
        # would inject its own bullet lines as if they were candidates.
        case "$n" in *-brief.md) continue ;; esac
        FOLD+=("$n")
    done < <(find "$STATE" -maxdepth 1 -name 'promotion-*.md' -type f | sort)
fi

queue_entries=0
[ -f "$QUEUE" ] && queue_entries=$( { grep -c '^- ' "$QUEUE" || true; } )

# Marker grep is PROPOSE, never AUTO — it is noisy by nature.
MARKERS=()
while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    MARKERS+=("$hit")
done < <( { grep -rniE 'promotion.candidate' "$MEM" "$TASKS" 2>/dev/null || true; } \
          | sed 's/:/\t/; s/:/\t/' | cut -c1-300)

# ---- dead links / orphans (REPORT-ONLY) ----
# An unresolved [[link]] is NOT an error by itself: the auto-memory protocol
# says it marks something worth writing later. Only near-misses are typos, so
# only those are listed. Distance <= 2 or case-insensitive exact.
mapfile -t NOTE_NAMES < <(find "$VAULT" -name '*.md' -type f -printf '%f\n' \
                          2>/dev/null | sed 's/\.md$//' | sort -u)

lev_near() {
    # $1 = candidate link text. Prints "name<TAB>distance" for the closest
    # match when distance <= 2, else prints nothing.
    printf '%s\n' ${NOTE_NAMES[@]+"${NOTE_NAMES[@]}"} | awk -v t="$1" '
    function lev(a, b,   la, lb, i, j, c, prev, cur) {
        la = length(a); lb = length(b)
        if (la == 0) return lb
        if (lb == 0) return la
        for (j = 0; j <= lb; j++) prev[j] = j
        for (i = 1; i <= la; i++) {
            cur[0] = i
            for (j = 1; j <= lb; j++) {
                c = (substr(a, i, 1) == substr(b, j, 1)) ? 0 : 1
                cur[j] = prev[j] + 1
                if (cur[j-1] + 1 < cur[j]) cur[j] = cur[j-1] + 1
                if (prev[j-1] + c < cur[j]) cur[j] = prev[j-1] + c
            }
            for (j = 0; j <= lb; j++) prev[j] = cur[j]
        }
        return prev[lb]
    }
    BEGIN { best = 99; bestn = "" }
    {
        if (tolower($0) == tolower(t)) { print $0 "\t0"; found = 1; exit }
        d = lev(tolower($0), tolower(t))
        if (d < best) { best = d; bestn = $0 }
    }
    END { if (!found && best <= 2) print bestn "\t" best }
    '
}

# Resolve against a hash set, not a linear scan, and near-match each DISTINCT
# link exactly once. lev_near spawns an awk pass over every note name, so
# calling it per link occurrence rather than per distinct link would make this
# O(occurrences x notes) — minutes on a vault this size.
declare -A NOTE_SET=()
for n in ${NOTE_NAMES[@]+"${NOTE_NAMES[@]}"}; do NOTE_SET["$n"]=1; done

DEADLINKS=()
unresolved_total=0
while IFS=$'\t' read -r link src; do
    [ -z "$link" ] && continue
    [ -n "${NOTE_SET[$link]:-}" ] && continue
    unresolved_total=$((unresolved_total + 1))
    near=$(lev_near "$link")
    [ -n "$near" ] && DEADLINKS+=("$(basename "$src")"$'\t'"$link"$'\t'"$near")
done < <( { grep -rnoE '\[\[[^]]+\]\]' "$SURFACE" 2>/dev/null || true; } \
          | sed 's/:[0-9]*:/\t/' | sed 's/\[\[//; s/\]\]//' \
          | awk -F'\t' '{ print $2 "\t" $1 }' | sort -u -t$'\t' -k1,1 )

# Orphan = a memory file no other memory file links to.
ORPHANS=()
while IFS= read -r f; do
    b=$(basename "$f" .md)
    [ "$b" = "MEMORY" ] && continue
    if ! grep -rqF "[[$b]]" "$MEM" 2>/dev/null; then
        ORPHANS+=("$b")
    fi
done < <(find "$MEM" -maxdepth 1 -name '*.md' -type f | sort)

# ---- canon leak (REPORT-ONLY) ----
# The vault is not a git repo, so mtime against the last-run marker is the only
# available detector. Approved Phase 2 writes to 10-middle WILL appear here on
# the following run — the EA cross-references the canon-writes log in prior
# ring-health reports to separate explained from unexplained. LiveSync also
# touches mtimes, so this is "eyeball these", never an alarm.
LEAKS=()
if [ -f "$MARKER" ]; then
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        LEAKS+=("${f#"$VAULT"/}"$'\t'"$(stat -c %y "$f" | cut -d. -f1)")
    done < <(find "$VAULT/00-core" "$VAULT/10-middle" "$VAULT/40-journal" \
                  -type f -name '*.md' -newer "$MARKER" 2>/dev/null | sort)
else
    anom "$MARKER" "no last-run marker — canon-leak baseline only, nothing reported"
fi

# ---- emit ----
emit_section() {
    printf '## %s\n' "$1"
    shift
    [ "$#" -eq 0 ] || printf '%s\n' "$@"
    printf '\n'
}

printf '## metrics\n'
printf 'memory.files=%s\n'            "$mem_files"
printf 'memory.indexed=%s\n'          "$mem_indexed"
printf 'memory.missing=%s\n'          "${#MEM_ADD[@]}"
printf 'memory.dead=%s\n'             "${#MEM_DEAD[@]}"
printf 'memory.no_description=%s\n'   "${#MEM_NODESC[@]}"
printf 'memory.separator_legacy=%s\n' "$mem_sep_legacy"
printf 'slots.total=%s\n'             "$slots_total"
printf 'slots.running=%s\n'           "$slots_running"
printf 'slots.terminal=%s\n'          "$slots_terminal"
printf 'slots.eligible=%s\n'          "${#SLOT_PROP[@]}"
printf 'tasks.count=%s\n'             "$tasks_count"
printf 'tasks.bytes=%s\n'             "$tasks_bytes"
printf 'tasks.eligible=%s\n'          "${#TASK_PROP[@]}"
printf 'state.files=%s\n'           "$state_files"
printf 'state.briefs_eligible=%s\n' "$briefs_elig"
printf 'state.health_reports=%s\n'  "$health_reports"
printf 'queue.entries=%s\n'         "$queue_entries"
printf 'links.unresolved=%s\n'      "$unresolved_total"
printf '\n'

emit_section "auto.index_add"    ${MEM_ADD[@]+"${MEM_ADD[@]}"}
emit_section "auto.index_drop"   ${MEM_DEAD[@]+"${MEM_DEAD[@]}"}
emit_section "report.no_description" ${MEM_NODESC[@]+"${MEM_NODESC[@]}"}
emit_section "propose.slots"     ${SLOT_PROP[@]+"${SLOT_PROP[@]}"}
emit_section "propose.tasks"     ${TASK_PROP[@]+"${TASK_PROP[@]}"}
emit_section "auto.promotion_fold" ${FOLD[@]+"${FOLD[@]}"}
emit_section "propose.state"       ${STATE_PROP[@]+"${STATE_PROP[@]}"}
emit_section "propose.markers"     ${MARKERS[@]+"${MARKERS[@]}"}
emit_section "report.dead_links"   ${DEADLINKS[@]+"${DEADLINKS[@]}"}
emit_section "report.orphans"      ${ORPHANS[@]+"${ORPHANS[@]}"}
emit_section "report.canon_leak"   ${LEAKS[@]+"${LEAKS[@]}"}
emit_section "anomalies"         ${ANOM[@]+"${ANOM[@]}"}
