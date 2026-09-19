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
# Exit 2 if the vault is not mounted. Exit 3 if the index-sync self-consistency
# guard trips (INFRA-78) — an impossible metric combination, which means this
# scanner and MEMORY.md disagree about format and no AUTO action may be
# trusted. Exit 4 if the stdout consumer closes the pipe mid-report (INFRA-88)
# — whatever was captured is truncated and must be discarded. Otherwise exit 0
# even when findings exist; findings are data, not errors.
#
# The report ends with a bare "## end" line. That is a TERMINATOR, not a 14th
# section: a capture whose last line is not "## end" is truncated, however
# complete it looks. On 2026-09-05 the report was consumed through
# `... | tee file | head -100`; head exited, tee died of SIGPIPE, this script
# died of SIGPIPE mid-emit, and head's exit 0 hid all of it — the truncated
# file read as a scan that "dropped" its last two sections, one of which is
# the canon-leak safety check.
#
# Progress is traced to stderr, one line per section; stdout carries only the
# report.

set -euo pipefail

# A consumer that exits early kills this script with SIGPIPE on its next
# write, and the default disposition is a SILENT death — the shape of the
# 2026-09-05 incident (INFRA-88). Make it loud: reset the disposition first
# so the failure message cannot recurse into a second SIGPIPE when stderr is
# merged into the same dead pipe, then exit with the dedicated status. The
# handler is a trap, not an ignore, so child processes inherit the default
# disposition and the script's internal pipelines are unaffected.
trap 'trap "" PIPE; printf "FAIL: ring-scan: output consumer closed the pipe mid-report — the report is TRUNCATED; discard it and re-run\n" >&2 || true; exit 4' PIPE

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

# Progress goes to stderr, one line per section. The script computes into bash
# arrays and prints nothing until the emit block, so before this a long run was
# indistinguishable from a hang -- which cost real diagnostic time during the
# 2026-09-04 pass (INFRA-77). stdout stays machine-parseable.
trace() { printf 'ring-scan: %s\n' "$*" >&2; }

# norm_link <raw wiki-link text> -- sets $NL to the note stem it refers to.
#
# Obsidian link grammar is [[path/to/note#heading^block|alias]], and the vault
# uses every part of it: 102 links in claude-memory alone carry an alias or a
# path. Before INFRA-77 the raw text was looked up verbatim against a set of
# bare basenames, so those links could never resolve -- 2,209 of 2,719 links on
# the live vault were falsely unresolved, each one paying for a full-corpus
# Levenshtein scan it did not need.
#
# Sets a global rather than printing, because this runs once per link
# occurrence and $(...) would fork a subshell every time.
#
NL=""
norm_link() {
    local s="$1"
    s="${s%%|*}"      # alias:  note|display text
    s="${s%%#*}"      # heading anchor
    s="${s%%^*}"      # block reference
    # Strip trailing backslashes AFTER those splits, not before. The vault's
    # _index.md files write [[20-surface/claude-memory/MEMORY\|`display`]] --
    # an ESCAPED PIPE -- so the backslash only becomes trailing once the alias
    # has been removed. Stripping first silently misses every one of them. The
    # escaped-bracket form [[MEMORY\]] is covered by the same strip, because
    # the splits above are no-ops on it.
    while [ -n "$s" ] && [ "${s: -1}" = '\' ]; do s="${s%?}"; done
    s="${s##*/}"      # path -> basename
    s="${s%.md}"      # an explicit extension is still the same note
    NL="$s"
}

# ---- index sync (AUTO) ----
# MEMORY.md is written by cc-memory-index-regen.sh as one line per memory:
#     - [[stem]] — hook
# That script is the FORMAT AUTHORITY. This scanner must agree with it; when
# the two disagree, this file is the one that is wrong.
#
# INFRA-78: this block used to ask `grep -qF "<stem>.md" MEMORY.md`. The
# AI_ST-69 compaction rewrote the index to extensionless wiki-links, so the
# fixed-string grep stopped matching and ALL 471 files were reported missing --
# an AUTO action, applied without asking, that would have appended a duplicate
# of the entire index in the superseded format. Compare on the filename STEM
# and read the index by extracting [[...]] targets, per the 2026-09-04
# CLAUDE.md amendment that inline links resolve on the filename stem.
trace "index sync"

# Read ENTRY lines only, and only their leading wiki-link. The file's own
# header comment documents the format with a literal "[[name]] — hook"
# example, so a whole-file grep for [[...]] adopts `name` as an index target
# and then reports it dead — the index's documentation would show up as a
# proposed AUTO deletion.
#
# Being strict here is also what keeps the guard below honest: if the format
# drifts again, this extractor yields nothing while mem_indexed still counts
# the entry lines, which is exactly the impossible combination the guard
# catches. A lenient parser would absorb the drift silently.
declare -A IDX=()
while IFS= read -r stem; do
    [ -z "$stem" ] && continue
    norm_link "$stem"
    [ -n "$NL" ] && IDX["$NL"]=1
done < <( { sed -n 's/^- \[\[\([^]]*\)\]\].*/\1/p' "$MEM/MEMORY.md" 2>/dev/null || true; } )

# A file without description: frontmatter is NOT auto-addable — nothing
# synthesizes a description — so it is reported instead.
mem_files=0
MEM_NODESC=()
ADD_STEMS=()
ADD_DESCS=()
while IFS= read -r f; do
    b=$(basename "$f")
    [ "$b" = "MEMORY.md" ] && continue
    mem_files=$((mem_files + 1))
    stem="${b%.md}"
    [ -n "${IDX[$stem]:-}" ] && continue
    d=$( { grep -m1 '^description:' "$f" || true; } | sed 's/^description: *//')
    if [ -z "$d" ]; then
        MEM_NODESC+=("$stem")
    else
        ADD_STEMS+=("$stem")
        ADD_DESCS+=("$d")
    fi
done < <(find "$MEM" -maxdepth 1 -name '*.md' -type f | sort)

# Emit each addition as the LINE TO APPEND, in the compacted format, with the
# hook cut by the same rule cc-memory-index-regen.sh uses. A fix written in the
# old format would itself reintroduce the drift it exists to repair, and a fix
# with an uncut hook would be reformatted by the next regen — so the row is
# built to be byte-identical to what the generator would have written.
#
# gawk's length()/substr() are character-oriented in a UTF-8 locale, matching
# Python's, which is what lets this mirror the generator's rule exactly around
# the em-dash. One awk process, and only when there is something to add.
MEM_ADD=()
if [ "${#ADD_STEMS[@]}" -gt 0 ]; then
    while IFS= read -r row; do
        [ -n "$row" ] && MEM_ADD+=("$row")
    done < <(
        for i in "${!ADD_STEMS[@]}"; do
            printf '%s\t%s\n' "${ADD_STEMS[$i]}" "${ADD_DESCS[$i]}"
        done | awk -F'\t' '
        function rstrip(x) { sub(/[ \t]+$/, "", x); return x }
        function hookify(d,   n, s, off, p, strong, weak, cut, i, ch) {
            n = length(d)
            if (n <= 72) return d
            strong = -1; off = 0; s = d
            while (match(s, /(; | — | -- | - |\. )/)) {
                p = off + RSTART - 1
                if (p >= 30 && p <= 72) strong = p
                off = off + RSTART - 1 + RLENGTH
                if (off >= n) break
                s = substr(d, off + 1)
            }
            if (strong >= 0) return rstrip(substr(d, 1, strong))
            weak = -1; off = 0; s = d
            while (match(s, /(, |: )/)) {
                p = off + RSTART - 1
                if (p >= 30 && p <= 60) weak = p
                off = off + RSTART - 1 + RLENGTH
                if (off >= n) break
                s = substr(d, off + 1)
            }
            if (weak >= 0) return rstrip(substr(d, 1, weak))
            cut = substr(d, 1, 60)
            i = length(cut)
            while (i > 0 && substr(cut, i, 1) != " ") i--
            if (i > 0) cut = substr(cut, 1, i - 1)
            while (length(cut) > 0) {
                ch = substr(cut, length(cut), 1)
                if (ch == " " || ch == "," || ch == ";" || ch == ":" || ch == "—" || ch == "-")
                    cut = substr(cut, 1, length(cut) - 1)
                else break
            }
            return cut "…"
        }
        { printf "- [[%s]] — %s\n", $1, hookify($2) }'
    )
fi

# Dead = an index entry whose file no longer exists.
#
# INFRA-78: this used to extract markdown-link targets with
# grep -oE '\]\([^)]*\.md\)' — syntax the compacted index has not contained
# since AI_ST-69. It therefore always found zero, so memory.dead=0 was a false
# clean: the check was structurally incapable of returning anything else.
MEM_DEAD=()
if [ "${#IDX[@]}" -gt 0 ]; then
    for t in "${!IDX[@]}"; do
        [ -f "$MEM/$t.md" ] || MEM_DEAD+=("$t")
    done
fi
if [ "${#MEM_DEAD[@]}" -gt 1 ]; then
    mapfile -t MEM_DEAD < <(printf '%s\n' "${MEM_DEAD[@]}" | sort)
fi

mem_indexed=$( { grep -c '^- \[' "$MEM/MEMORY.md" || true; } )
mem_sep_legacy=$( { grep -c ') -- ' "$MEM/MEMORY.md" || true; } )
mem_missing=${#MEM_ADD[@]}

# ---- fail-closed self-consistency guard (AUTO tier, INFRA-78) ----
# Every memory file reported BOTH absent from the index and counted in it. No
# real index is in that state: it is the arithmetic signature of this scanner
# and MEMORY.md disagreeing about format.
#
# This guard deliberately does NOT encode the 2026-09-04 drift — it encodes the
# SHAPE of that class of fault, so it still fires for the next format change,
# which by definition nobody has thought of yet. Remit 1 is AUTO, applied
# without asking, and it writes a file injected into every session; an AUTO
# tier with that reach has to fail closed rather than guess.
#
# Abort here, before the expensive dead-link survey, so the failure is loud and
# fast rather than loud and forty minutes late.
if [ "$mem_missing" -gt 0 ] \
   && [ "$mem_missing" -eq "$mem_files" ] \
   && [ "$mem_indexed" -eq "$mem_files" ]; then
    {
        printf 'FAIL: cc-ring-scan self-consistency check failed — refusing to emit AUTO actions.\n'
        printf '      memory.files=%s memory.indexed=%s memory.missing=%s\n' \
            "$mem_files" "$mem_indexed" "$mem_missing"
        printf '      Every memory file is reported both indexed AND missing. That cannot be\n'
        printf '      true of a real index; it is the signature of a format mismatch between\n'
        printf '      this scanner and MEMORY.md (INFRA-78, 2026-09-04).\n'
        printf '      Applying auto.index_add in this state would append a duplicate of the\n'
        printf '      whole index. Nothing has been emitted.\n'
        printf '      Compare the index against its format authority before re-running:\n'
        printf '        %s\n' "$MEM/MEMORY.md"
        printf '        ~/.claude/cc-memory-index-regen.sh\n'
    } >&2
    exit 3
fi

# ---- tree slots (PROPOSE) ----
# Two passes. The first records the parent_id of every running slot so the
# second can refuse to archive a live child's parent — archiving it would
# silently break event delivery to a session that is still working.
trace "tree slots"
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
trace "task folders"
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

    # awk max, not `sort -rn | head -1`: head reads one ~8 KiB block, prints
    # line 1 and exits, so sort's next write hits a closed pipe and dies of
    # SIGPIPE (141) — which pipefail promotes to the pipeline's status and
    # errexit turns into a silent abort with no output at all. Measured to
    # fire from ~400 files in a folder, reliably by ~600. awk reads to EOF,
    # so nothing is ever killed mid-write.
    newest=$(find "$t" -type f -printf '%T@\n' 2>/dev/null \
             | awk 'NR==1 || $1+0 > m+0 { m=$1 } END { if (NR) print m }')
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
trace "state hygiene"
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
trace "promotion backlog"
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
#
# AI_ST-94: a walked section keeps its heading, so before stamping existed
# every pass re-found, re-triaged, and sometimes re-promoted sections an
# earlier walk had already dispositioned — the 2026-09-04 pass re-queued six,
# two of which re-entered canon against a prior ruling. The ring-maintenance
# walk (Phase 2) now stamps processed headings `[WALKED YYYY-MM-DD]`, and this
# grep drops stamped lines. The date is matched as digits, not as a literal:
# prose *about* the stamp convention writes "[WALKED YYYY-MM-DD]" and must
# still surface as the noise it is, never masquerade as a disposition.
MARKERS=()
while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    MARKERS+=("$hit")
# The excludes drop the grep's own exhaust: saved copies of previous scan
# output, editor/backup copies, archived task folders, and preserved
# LiveSync-conflict / loop copies of MEMORY.md. On 2026-09-02, ~31 of 37
# rows were these self-quotations — noise dense enough to hide the six real
# duplicates the pass then mis-queued.
done < <( { grep -rniE 'promotion.candidate' "$MEM" "$TASKS" \
                 --exclude='scan-output.txt' --exclude='*.bak' \
                 --exclude-dir='_archive' --exclude-dir='obsidian-conflicts' \
                 --exclude-dir='memory-loop' 2>/dev/null || true; } \
          | { grep -v '\[WALKED [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\]' || true; } \
          | sed 's/:/\t/; s/:/\t/' | cut -c1-300)

# ---- dead links / orphans (REPORT-ONLY) ----
# An unresolved [[link]] is NOT an error by itself: the auto-memory protocol
# says it marks something worth writing later. Only near-misses are typos, so
# only those are listed. Distance <= 2 or case-insensitive exact.
trace "dead links: extracting and normalising"

mapfile -t NOTE_NAMES < <(find "$VAULT" -name '*.md' -type f -printf '%f\n' \
                          2>/dev/null | sed 's/\.md$//' | sort -u)
declare -A NOTE_SET=()
for n in ${NOTE_NAMES[@]+"${NOTE_NAMES[@]}"}; do NOTE_SET["$n"]=1; done

# One entry per DISTINCT normalised link, remembering the first file it was
# seen in. Normalising before the dedupe is what collapses the live vault's
# 2,719 raw occurrences to a few hundred real questions.
declare -A LINK_SRC=()
while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    # rec is "path:line:[[link]]". Split on the LAST "[[" rather than the first
    # ":" so a path containing a colon does not corrupt the source name.
    head="${rec%%\[\[*}"
    raw="${rec#"$head"}"
    raw="${raw#\[\[}"; raw="${raw%\]\]}"
    head="${head%:}"; src="${head%:*}"
    norm_link "$raw"
    [ -z "$NL" ] && continue
    [ -n "${LINK_SRC[$NL]:-}" ] || LINK_SRC["$NL"]="${src##*/}"
done < <( { grep -rnoE '\[\[[^]]+\]\]' "$SURFACE" 2>/dev/null || true; } )

UNRES=()
unresolved_total=0
while IFS= read -r l; do
    [ -z "$l" ] && continue
    unresolved_total=$((unresolved_total + 1))
    UNRES+=("$l")
done < <(
    if [ "${#LINK_SRC[@]}" -gt 0 ]; then
        for l in "${!LINK_SRC[@]}"; do
            [ -n "${NOTE_SET[$l]:-}" ] || printf '%s\n' "$l"
        done
    fi | sort
)

# Near-match every unresolved link in ONE awk pass, not one process per link.
#
# Two costs were stacked here before INFRA-77: ~2,200 awk spawns, each scanning
# the whole 2,666-name corpus at ~1.26 s, for a projected ~46 min. The corpus is
# now loaded once and bucketed BY NAME LENGTH, because Levenshtein distance is
# at least the difference in lengths — so a name whose length differs by more
# than 2 cannot possibly be within 2 and never needs the O(n*m) inner loop.
DEADLINKS=()
if [ "${#UNRES[@]}" -gt 0 ]; then
    trace "dead links: near-matching ${#UNRES[@]} unresolved against ${#NOTE_NAMES[@]} names"
    SPLIT=$'\x1e'
    while IFS=$'\t' read -r cand bestn dist; do
        [ -z "$cand" ] && continue
        DEADLINKS+=("${LINK_SRC[$cand]}"$'\t'"$cand"$'\t'"$bestn"$'\t'"$dist")
    done < <(
        {
            printf '%s\n' ${NOTE_NAMES[@]+"${NOTE_NAMES[@]}"}
            printf '%s\n' "$SPLIT"
            printf '%s\n' "${UNRES[@]}"
        } | awk -v sep="$SPLIT" '
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
        $0 == sep { phase = 1; next }
        phase == 0 {
            L = length($0)
            k = ++cnt[L]
            name[L, k] = $0
            low[L, k] = tolower($0)
            next
        }
        {
            t = $0; lt = tolower(t); L = length(t)
            best = 99; bestn = ""
            for (d = -2; d <= 2 && best > 0; d++) {
                M = L + d
                if (!(M in cnt)) continue
                for (i = 1; i <= cnt[M]; i++) {
                    if (low[M, i] == lt) { best = 0; bestn = name[M, i]; break }
                    dd = lev(low[M, i], lt)
                    if (dd < best) { best = dd; bestn = name[M, i] }
                }
            }
            if (best <= 2 && bestn != "") print t "\t" bestn "\t" best
        }'
    )
fi

# Orphan = a memory file no OTHER memory file links to.
#
# INFRA-78, third defect of the same class: this used to run
# `grep -rqF "[[$stem]]" "$MEM"` once per memory file. MEMORY.md lives inside
# $MEM and carries [[stem]] for every indexed file, so the index always
# satisfied the search and report.orphans was structurally always empty — the
# same false clean as memory.dead. The literal also could not see the 102
# aliased or path-bearing links the memory corpus actually uses.
#
# Build the inbound-link set once, excluding the index, and normalise it.
trace "orphans"
declare -A MEM_LINKED=()
while IFS= read -r raw; do
    [ -z "$raw" ] && continue
    raw="${raw#*\[\[}"; raw="${raw%\]\]}"
    norm_link "$raw"
    [ -n "$NL" ] && MEM_LINKED["$NL"]=1
done < <( { grep -rhoE '\[\[[^]]+\]\]' --exclude=MEMORY.md "$MEM" 2>/dev/null || true; } )

ORPHANS=()
while IFS= read -r f; do
    b=$(basename "$f" .md)
    [ "$b" = "MEMORY" ] && continue
    [ -n "${MEM_LINKED[$b]:-}" ] || ORPHANS+=("$b")
done < <(find "$MEM" -maxdepth 1 -name '*.md' -type f | sort)

# ---- canon leak (REPORT-ONLY) ----
# The vault is not a git repo, so mtime against the last-run marker is the only
# available detector. Approved Phase 2 writes to 10-middle WILL appear here on
# the following run — the EA cross-references the canon-writes log in prior
# ring-health reports to separate explained from unexplained. LiveSync also
# touches mtimes, so this is "eyeball these", never an alarm.
trace "canon leak"
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
trace "emitting report"

emit_section() {
    printf '## %s\n' "$1"
    shift
    [ "$#" -eq 0 ] || printf '%s\n' "$@"
    printf '\n'
}

printf '## metrics\n'
printf 'memory.files=%s\n'            "$mem_files"
printf 'memory.indexed=%s\n'          "$mem_indexed"
printf 'memory.missing=%s\n'          "$mem_missing"
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

# Terminator, not a section. A capture that does not end with this line is
# truncated and must be discarded — without it, the 2026-09-05 tail loss was
# indistinguishable from a scan with nothing to say in its last two sections
# (INFRA-88). The ring-maintenance skill's Step 2 verifies it before any
# finding is consumed.
printf '## end\n'
