#!/usr/bin/env bash
# cc-index-regen — rebuild the surface ring's five generated _index.md files
# from disk, so an archive move can never strand a note.
#
# Called by the ring-maintenance skill (Step 4, after the last archive move).
# Rebuilds, deterministically from what is on disk:
#
#     company/tree/_index.md                    live session slots, by task_id
#     company/tree/sessions/_archive/_index.md  archived slots, by task_id
#     company/tasks/_index.md                   live task folders, every note
#     company/tasks/_archive/_index.md          archived task folders, every note
#     company/_command-center/_index.md         the EA's directory, every note
#
# WHY (INFRA-91, 2026-09-16): the 2026-09-03 cartography pass wrote these five
# by hand and nothing regenerated them. Two ring-maintenance passes then moved
# 241 notes into _archive/ directories; each move turned a path-bearing index
# link into a dead one (1,092 of them, 882 in tasks/_index.md alone) and left
# the moved note with no incoming link. Measured with Obsidian's link
# semantics, 471 notes were disconnected from the graph by index rot alone.
#
# Contract:
#   * One path-bearing wikilink per note file under each root -- exactly one,
#     across all five indexes together -- so a note is never stranded and a
#     basename collision (every task folder has a report.md) resolves to the
#     right file. `.events/` directories are skipped by design: event files
#     are hidden from the graph by the vault's Excluded-files filter, not
#     indexed.
#   * Grouped by task_id (slots) or by task folder (notes), like the hand-
#     written indexes were. Existing prose in an index is disposable.
#   * Idempotent with a STABLE stamp: an index is rewritten only when its
#     listing changed, and `generated:` is refreshed only then. So the date
#     reads "when this listing last changed", not "when the script last ran",
#     and a second run is a byte-for-byte no-op.
#   * Writes exactly the five paths above and nothing else, all under
#     ~/vault/20-surface/. Never creates a directory: an absent _archive/ is
#     reported as a skip -- the archive dirs are the ring-maintenance moves'
#     to create on first use.
#   * --dry-run prints what would change and writes nothing.
#   * --measure is strictly read-only: it counts the notes that have no
#     resolved wikilink in or out, whole vault, with `.events/` excluded the
#     way the graph excludes them. This is the before/after metric the
#     ring-maintenance health report carries.
#
# Exit 2 if the vault is not mounted. Exit 1 on a usage error. Otherwise 0,
# in every mode.
#
# Usage: cc-index-regen.sh [--dry-run | --measure [--list]] [-h|--help]

set -euo pipefail

VAULT="$HOME/vault"
SURFACE="$VAULT/20-surface"

usage() {
    sed -n 's/^# Usage: //p' "$0"
}

MODE=write
LIST=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) MODE=dry ;;
        --measure) MODE=measure ;;
        --list)    LIST=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "cc-index-regen: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

if [ ! -d "$SURFACE/company" ]; then
    echo "FAIL: vault not mounted at $VAULT (no 20-surface/company)" >&2
    exit 2
fi

# Today's date is passed in rather than read inside python so a test can pin
# it; it is only stamped onto an index whose listing actually changed.
STAMP="${CC_INDEX_REGEN_STAMP:-$(date +%F)}"

python3 - "$VAULT" "$MODE" "$STAMP" "$LIST" <<'EOF'
import os, re, sys

VAULT, MODE, STAMP, LIST = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
SURFACE = os.path.join(VAULT, "20-surface")
COMPANY = os.path.join(SURFACE, "company")
GENERATED_BY = "cc-index-regen.sh"

# Vault-relative path of the five outputs. Every write is checked against this
# list AND against the 20-surface/ prefix; nothing else is ever opened for
# writing.
OUT_TREE = "20-surface/company/tree/_index.md"
OUT_TREE_ARCHIVE = "20-surface/company/tree/sessions/_archive/_index.md"
OUT_TASKS = "20-surface/company/tasks/_index.md"
OUT_TASKS_ARCHIVE = "20-surface/company/tasks/_archive/_index.md"
OUT_CC = "20-surface/company/_command-center/_index.md"
OUTPUTS = {OUT_TREE, OUT_TREE_ARCHIVE, OUT_TASKS, OUT_TASKS_ARCHIVE, OUT_CC}

LINK_RE = re.compile(r"\[\[([^\]]+?)\]\]")
FM_RE = re.compile(r"\A---\n(.*?)\n---\n", re.S)


def vrel(abspath):
    return os.path.relpath(abspath, VAULT)


def skip_dir(name):
    # Dot-directories are invisible to Obsidian; .events/ dirs are excluded
    # from the graph by remedy 1 and never indexed by design.
    return name.startswith(".") or name.endswith(".events")


def notes_under(root, exclude_subtrees=()):
    """Every *.md under root (vault-relative paths), skipping dot-dirs,
    .events/ dirs, the given subtrees, and the five generated outputs."""
    found = []
    if not os.path.isdir(root):
        return found
    ex = {os.path.normpath(e) for e in exclude_subtrees}
    for cur, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs
                         if not skip_dir(d) and os.path.normpath(os.path.join(cur, d)) not in ex)
        for f in sorted(files):
            if not f.endswith(".md"):
                continue
            rel = vrel(os.path.join(cur, f))
            if rel in OUTPUTS:
                continue
            found.append(rel)
    return sorted(found)


def read(rel):
    try:
        with open(os.path.join(VAULT, rel), encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def frontmatter(text):
    m = FM_RE.match(text)
    fm = {}
    if not m:
        return fm
    for line in m.group(1).splitlines():
        if ":" in line and not line.startswith((" ", "\t")):
            k, v = line.split(":", 1)
            fm[k.strip()] = v.strip()
    return fm


def clean(s, limit=110):
    # A title lands after the link on the same line; it must not open a
    # second wikilink or break the alias grammar.
    s = re.sub(r"[\[\]|]", " ", s)
    s = re.sub(r"\s+", " ", s).strip(" #-—·")
    if len(s) > limit:
        s = s[:limit].rsplit(" ", 1)[0].rstrip(" ,;:—-") + "…"
    return s


def title_of(rel, text):
    fm = frontmatter(text)
    if fm.get("title"):
        return clean(fm["title"])
    body = FM_RE.sub("", text, count=1)
    for line in body.splitlines():
        if line.startswith("# "):
            return clean(line[2:])
    return ""


def link(rel, alias):
    return "[[%s|%s]]" % (rel[:-3], alias.replace("|", "/").replace("]", ")"))


def date_only(s):
    return (s or "")[:10]


# --- slots -----------------------------------------------------------------

def slot_entry(rel):
    """A tree slot note -> (task_id, line). Non-slot notes return None."""
    text = read(rel)
    fm = frontmatter(text)
    if "session_id" not in fm or "status" not in fm:
        return None
    sid = os.path.basename(rel)[:-3]
    tid = fm.get("task_id") or ""
    bits = [fm.get("status") or "?", fm.get("mode") or "?"]
    if fm.get("started_at"):
        span = date_only(fm["started_at"])
        if fm.get("ended_at"):
            span += " → " + date_only(fm["ended_at"])
        bits.append(span)
    line = "- %s — %s" % (link(rel, "`%s`" % sid[:8]), " · ".join(bits))
    return tid, line


def build_slot_index(out_rel, root, exclude, heading_path, purpose, up, down, task_ids_with_folder):
    notes = notes_under(root, exclude)
    groups, loose, statuses = {}, [], {}
    for rel in notes:
        e = slot_entry(rel)
        if e is None:
            loose.append(rel)
            continue
        tid, line = e
        groups.setdefault(tid, []).append(line)
        st = frontmatter(read(rel)).get("status") or "?"
        statuses[st] = statuses.get(st, 0) + 1
    nslots = sum(len(v) for v in groups.values())
    lines = []
    lines.append("# `%s` — index" % heading_path)
    lines.append("")
    lines.append(purpose)
    lines.append("")
    lines.append("Generated by `%s`; regenerate rather than edit. One link per slot file, "
                 "grouped by `task_id`. Each slot's `<id>.events` directory is not indexed: event "
                 "notes are hidden from the graph by the vault's Excluded-files filter (INFRA-91)." % GENERATED_BY)
    lines.append("")
    lines.append("| | count |")
    lines.append("|---|---|")
    lines.append("| slot files | %d |" % nslots)
    for st in sorted(statuses):
        lines.append("| status `%s` | %d |" % (st, statuses[st]))
    lines.append("| distinct `task_id`s | %d |" % len([k for k in groups if k]))
    if "" in groups:
        lines.append("| slots with no `task_id` | %d |" % len(groups[""]))
    lines.append("")
    lines.append("## Slots by task")
    lines.append("")
    for tid in sorted((k for k in groups if k), key=str.lower):
        folder = task_ids_with_folder.get(tid)
        if folder:
            lines.append("### %s — %s" % (tid, folder))
        else:
            lines.append("### %s" % tid)
        lines.append("")
        lines.extend(groups[tid])
        lines.append("")
    if "" in groups:
        lines.append("### (no task_id)")
        lines.append("")
        lines.extend(groups[""])
        lines.append("")
    if loose:
        lines.append("## Other notes")
        lines.append("")
        for rel in loose:
            alias = os.path.relpath(rel, os.path.dirname(out_rel))[:-3]
            t = title_of(rel, read(rel))
            lines.append("- %s%s" % (link(rel, alias), " — " + t if t else ""))
        lines.append("")
    lines.append("## Navigation")
    lines.append("")
    lines.extend(up)
    lines.extend(down)
    lines.append("")
    return lines


# --- task folders ----------------------------------------------------------

def build_folder_index(out_rel, root, exclude, heading_path, purpose, up, down, slot_pointer):
    notes = notes_under(root, exclude)
    base = os.path.relpath(root, VAULT)
    groups, loose = {}, []
    for rel in notes:
        inner = os.path.relpath(rel, base)
        if "/" in inner:
            groups.setdefault(inner.split("/", 1)[0], []).append(rel)
        else:
            loose.append(rel)
    lines = []
    lines.append("# `%s` — index" % heading_path)
    lines.append("")
    lines.append(purpose)
    lines.append("")
    lines.append("Generated by `%s`; regenerate rather than edit. Every note in every folder "
                 "gets exactly one path-bearing link, so a folder that moves between `tasks/` and "
                 "`tasks/_archive/` is re-linked on the next run instead of stranded (INFRA-91)." % GENERATED_BY)
    lines.append("")
    lines.append("| | count |")
    lines.append("|---|---|")
    lines.append("| folders | %d |" % len(groups))
    lines.append("| notes | %d |" % len(notes))
    lines.append("")
    lines.append("## Folders")
    lines.append("")
    for tid in sorted(groups, key=str.lower):
        ptr = slot_pointer(tid)
        lines.append("### %s (%d)%s" % (tid, len(groups[tid]), " — " + ptr if ptr else ""))
        lines.append("")
        for rel in groups[tid]:
            alias = os.path.relpath(rel, os.path.join(base, tid))[:-3]
            t = title_of(rel, read(rel))
            lines.append("- %s%s" % (link(rel, alias), " — " + t if t else ""))
        lines.append("")
    if loose:
        lines.append("## Loose notes")
        lines.append("")
        for rel in loose:
            alias = os.path.relpath(rel, base)[:-3]
            t = title_of(rel, read(rel))
            lines.append("- %s%s" % (link(rel, alias), " — " + t if t else ""))
        lines.append("")
    lines.append("## Navigation")
    lines.append("")
    lines.extend(up)
    lines.extend(down)
    lines.append("")
    return lines


# --- command-center ----------------------------------------------------------

def build_cc_index(out_rel, root, heading_path, purpose, up, down):
    notes = notes_under(root)
    base = os.path.relpath(root, VAULT)
    groups = {}
    for rel in notes:
        d = os.path.dirname(os.path.relpath(rel, base))
        groups.setdefault(d, []).append(rel)
    lines = []
    lines.append("# `%s` — index" % heading_path)
    lines.append("")
    lines.append(purpose)
    lines.append("")
    lines.append("Generated by `%s`; regenerate rather than edit. Every note under this "
                 "directory, `state/_archive/` included, gets exactly one path-bearing link, so "
                 "a brief archived by ring-maintenance is re-linked on the next run (INFRA-91)." % GENERATED_BY)
    lines.append("")
    lines.append("| | count |")
    lines.append("|---|---|")
    lines.append("| notes | %d |" % len(notes))
    for d in sorted(groups):
        lines.append("| `%s` | %d |" % (d + "/" if d else "./", len(groups[d])))
    lines.append("")
    for d in sorted(groups):
        lines.append("## `%s`" % (d + "/" if d else "./"))
        lines.append("")
        for rel in groups[d]:
            alias = os.path.relpath(rel, base)[:-3]
            t = title_of(rel, read(rel))
            lines.append("- %s%s" % (link(rel, alias), " — " + t if t else ""))
        lines.append("")
    lines.append("## Navigation")
    lines.append("")
    lines.extend(up)
    lines.extend(down)
    lines.append("")
    return lines


# --- render / diff / write ---------------------------------------------------

def render(out_rel, title, body_lines):
    fm = ["---", "title: %s" % title, "type: index", "generated: %s" % STAMP,
          "generated_by: %s" % GENERATED_BY, "---", ""]
    return "\n".join(fm + body_lines)


def strip_stamp(text):
    return re.sub(r"^generated: .*$", "generated: *", text, count=1, flags=re.M)


def link_targets(text):
    return sorted(m.group(1).split("|", 1)[0] for m in LINK_RE.finditer(text))


def emit(out_rel, new_text):
    abspath = os.path.join(VAULT, out_rel)
    assert out_rel in OUTPUTS, out_rel
    assert os.path.realpath(abspath).startswith(os.path.realpath(SURFACE) + os.sep), out_rel
    old_text = read(out_rel) if os.path.exists(abspath) else None
    if old_text is not None and strip_stamp(old_text) == strip_stamp(new_text):
        print("cc-index-regen: unchanged  %s" % out_rel)
        return
    old_links = set(link_targets(old_text or ""))
    new_links = set(link_targets(new_text))
    added, removed = sorted(new_links - old_links), sorted(old_links - new_links)
    verb = "would write" if MODE == "dry" else "wrote"
    print("cc-index-regen: %s  %s  (+%d -%d links%s)" % (
        verb, out_rel, len(added), len(removed), "" if old_text is not None else ", new file"))
    if MODE == "dry":
        for t in added[:20]:
            print("    + %s" % t)
        if len(added) > 20:
            print("    + … %d more" % (len(added) - 20))
        for t in removed[:20]:
            print("    - %s" % t)
        if len(removed) > 20:
            print("    - … %d more" % (len(removed) - 20))
        return
    # In-place write, not a temp-file rename: a rename is a delete-plus-create
    # to the LiveSync layer, and these rewrites should look like edits.
    with open(abspath, "w", encoding="utf-8") as fh:
        fh.write(new_text)


# --- measure -----------------------------------------------------------------

def measure():
    """Disconnected notes, whole vault, Obsidian link semantics.

    A note is connected if any wikilink in or out of it resolves. A link with
    a slash resolves by vault path (exact, then as a path suffix); a bare link
    resolves by basename, case-insensitively. Dot-directories and .events/
    directories are excluded, as the graph excludes them."""
    notes = []
    for cur, dirs, files in os.walk(VAULT):
        dirs[:] = sorted(d for d in dirs if not skip_dir(d))
        for f in files:
            if f.endswith(".md"):
                notes.append(vrel(os.path.join(cur, f)))
    noteset = set(notes)
    by_base, by_suffix = {}, {}
    for p in notes:
        by_base.setdefault(os.path.basename(p)[:-3].lower(), []).append(p)
    lowered = {p.lower(): p for p in notes}

    def resolve(raw):
        s = raw.split("\\|")[0].split("|")[0].split("#")[0].split("^")[0].strip()
        if not s:
            return None
        if s.endswith(".md"):
            s = s[:-3]
        if "/" in s:
            cand = s + ".md"
            if cand in noteset:
                return cand
            low = cand.lower()
            hits = [lowered[k] for k in lowered if k.endswith("/" + low) or k == low]
            return sorted(hits, key=len)[0] if hits else None
        lst = by_base.get(s.lower())
        return sorted(lst)[0] if lst else None

    connected = set()
    for p in notes:
        for m in LINK_RE.finditer(read(p)):
            t = resolve(m.group(1))
            if t and t != p:
                connected.add(p)
                connected.add(t)
    disc = sorted(n for n in notes if n not in connected)
    print("cc-index-regen: measure  notes=%d connected=%d disconnected=%d  (dot-dirs and .events/ excluded)"
          % (len(notes), len(notes) - len(disc), len(disc)))
    if LIST:
        for n in disc:
            print("    %s" % n)


if MODE == "measure":
    measure()
    sys.exit(0)

# --- assemble the five ---------------------------------------------------------

TREE = os.path.join(COMPANY, "tree")
TREE_ARCHIVE = os.path.join(TREE, "sessions", "_archive")
TASKS = os.path.join(COMPANY, "tasks")
TASKS_ARCHIVE = os.path.join(TASKS, "_archive")
CC = os.path.join(COMPANY, "_command-center")

live_folders = sorted(d for d in os.listdir(TASKS) if os.path.isdir(os.path.join(TASKS, d))
                      and d != "_archive" and not skip_dir(d)) if os.path.isdir(TASKS) else []
arch_folders = sorted(d for d in os.listdir(TASKS_ARCHIVE) if os.path.isdir(os.path.join(TASKS_ARCHIVE, d))
                      and not skip_dir(d)) if os.path.isdir(TASKS_ARCHIVE) else []

# Cross-tier pointers go to the OTHER index's heading, never to a note file:
# every note keeps exactly one incoming link, and the pointer still lands one
# click from the folder's listing.
folder_ptr = {}
for tid in live_folders:
    folder_ptr[tid] = "[[%s#%s|tasks/%s/]]" % (OUT_TASKS[:-3], tid, tid)
for tid in arch_folders:
    folder_ptr.setdefault(tid, "[[%s#%s|tasks/_archive/%s/]]" % (OUT_TASKS_ARCHIVE[:-3], tid, tid))

slot_tids_live, slot_tids_arch = set(), set()
for rel in notes_under(TREE, [TREE_ARCHIVE]):
    e = slot_entry(rel)
    if e and e[0]:
        slot_tids_live.add(e[0])
for rel in notes_under(TREE_ARCHIVE):
    e = slot_entry(rel)
    if e and e[0]:
        slot_tids_arch.add(e[0])


def slot_pointer(tid):
    parts = []
    if tid in slot_tids_live:
        parts.append("[[%s#%s|live sessions]]" % (OUT_TREE[:-3], tid))
    if tid in slot_tids_arch:
        parts.append("[[%s#%s|archived sessions]]" % (OUT_TREE_ARCHIVE[:-3], tid))
    return ", ".join(parts)


UP_COMPANY = ["- **Up:** [[20-surface/company/_index|company/]]"]
CARTO = "- **Origin:** the hand-written 2026-09-03 indexes are described in the surface-cartography report; this file is generated (INFRA-91)."

plan = []
if os.path.isdir(TREE):
    plan.append((OUT_TREE, "company/tree — index", lambda: build_slot_index(
        OUT_TREE, TREE, [TREE_ARCHIVE], "company/tree/",
        "**Purpose.** The org chart of the agentic workflow: one slot file per live session under "
        "`sessions/`, written by `cc-tree-slot-write.sh` and the bookends. Each slot's own "
        "`<id>.events` directory sits beside it and is not indexed.",
        UP_COMPANY,
        ["- **Down:** [[%s|sessions/_archive/]]" % OUT_TREE_ARCHIVE[:-3], CARTO], folder_ptr)))
else:
    print("cc-index-regen: skip  %s  (directory absent)" % OUT_TREE)

if os.path.isdir(TREE_ARCHIVE):
    plan.append((OUT_TREE_ARCHIVE, "company/tree/sessions/_archive — index", lambda: build_slot_index(
        OUT_TREE_ARCHIVE, TREE_ARCHIVE, [], "company/tree/sessions/_archive/",
        "**Purpose.** Session slots folded away by ring-maintenance once their shift closed. "
        "Grouped by `task_id` because that is the question this directory answers: which sessions "
        "worked on X, and how did each end?",
        ["- **Up:** [[%s|company/tree/]]" % OUT_TREE[:-3]], [CARTO], folder_ptr)))
else:
    print("cc-index-regen: skip  %s  (directory absent)" % OUT_TREE_ARCHIVE)

if os.path.isdir(TASKS):
    plan.append((OUT_TASKS, "company/tasks — index", lambda: build_folder_index(
        OUT_TASKS, TASKS, [TASKS_ARCHIVE], "company/tasks/",
        "**Purpose.** One folder per task, named by `task_id` — the Plane issue ID when the task "
        "has one, otherwise the `.cc-mode` slug of the session that produced it. A folder usually "
        "holds `brief.md` and `report.md` plus task-specific evidence.",
        UP_COMPANY,
        ["- **Down:** [[%s|tasks/_archive/]]" % OUT_TASKS_ARCHIVE[:-3],
         "- **Sessions:** [[%s|company/tree/]]" % OUT_TREE[:-3], CARTO], slot_pointer)))
else:
    print("cc-index-regen: skip  %s  (directory absent)" % OUT_TASKS)

if os.path.isdir(TASKS_ARCHIVE):
    plan.append((OUT_TASKS_ARCHIVE, "company/tasks/_archive — index", lambda: build_folder_index(
        OUT_TASKS_ARCHIVE, TASKS_ARCHIVE, [], "company/tasks/_archive/",
        "**Purpose.** Closed-out task folders, moved here by ring-maintenance. Same shape as a "
        "live task folder.",
        ["- **Up:** [[%s|company/tasks/]]" % OUT_TASKS[:-3]],
        ["- **Sessions:** [[%s|tree/sessions/_archive/]]" % OUT_TREE_ARCHIVE[:-3], CARTO], slot_pointer)))
else:
    print("cc-index-regen: skip  %s  (directory absent)" % OUT_TASKS_ARCHIVE)

if os.path.isdir(CC):
    plan.append((OUT_CC, "company/_command-center — index", lambda: build_cc_index(
        OUT_CC, CC, "company/_command-center/",
        "**Purpose.** The EA's own working directory — the cwd of every `command-center`-mode "
        "session: its standing instructions, the briefs it writes when dispatching, its runtime "
        "state, the promotion queue `ring-maintenance` consumes, and the archive of all of those. "
        "Read-only from other sessions.",
        UP_COMPANY,
        ["- **Down:** [[20-surface/company/tree/_index|company/tree/]], [[20-surface/company/tasks/_index|company/tasks/]]", CARTO])))
else:
    print("cc-index-regen: skip  %s  (directory absent)" % OUT_CC)

for out_rel, title, build in plan:
    emit(out_rel, render(out_rel, title, build()))
EOF
