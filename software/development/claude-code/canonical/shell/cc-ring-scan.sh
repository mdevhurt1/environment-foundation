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
printf '\n'

emit_section "auto.index_add"    ${MEM_ADD[@]+"${MEM_ADD[@]}"}
emit_section "auto.index_drop"   ${MEM_DEAD[@]+"${MEM_DEAD[@]}"}
emit_section "report.no_description" ${MEM_NODESC[@]+"${MEM_NODESC[@]}"}
emit_section "propose.slots"     ${SLOT_PROP[@]+"${SLOT_PROP[@]}"}
emit_section "propose.tasks"     ${TASK_PROP[@]+"${TASK_PROP[@]}"}
emit_section "anomalies"         ${ANOM[@]+"${ANOM[@]}"}
