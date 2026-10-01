#!/usr/bin/env bash
# Regenerate the compacted memory index at ~/vault/20-surface/claude-memory/MEMORY.md.
#
# WHY (AI_ST-69, 2026-09-03): the index is the recall surface every session
# reads, so its size is a per-session context tax. This script rebuilds it as
# one line per memory —
#     - [[name]] — <hook>
# The hook is scent, not content. An entry already in the index keeps its
# hook (sessions hand-write sharper hooks than a mechanical cut); a new file's
# hook is its frontmatter `description:` cut at a clause boundary (<=72 chars).
# A file with no `description:` is never given a synthesized hook: it gets the
# placeholder `(no description)` (so the one-line-per-file invariant holds), a
# stderr warning on regen, and an offender line on --check. A placeholder is
# replaced on the next regen once the file has a description.
#
# Installed as ~/.claude/cc-memory-index-regen.sh by agents/scripts/install.sh;
# that link is the stable path skills and the index header name.
#
# RESTORED (AI_ST-116, 2026-10-01): parked by the 2026-09-19 reset, which left
# every session hand-editing one shared index. Writes are now serialized and
# atomic: an flock on .MEMORY.md.lock beside the index (dotfile, hidden from Obsidian), then write-temp-and-mv
# in the same directory, so concurrent sessions cannot interleave or truncate.
#
# Usage:
#   cc-memory-index-regen.sh [MEM_DIR]          regenerate (sorted, idempotent)
#   cc-memory-index-regen.sh --check [MEM_DIR]  assert the per-file invariant
#       both ways (every memory file has exactly one line, every line has a
#       file; no file lacks a description); lists offenders and exits 1,
#       writes nothing.

set -euo pipefail

mode=regen
if [ "${1:-}" = "--check" ]; then mode=check; shift; fi
MEM_DIR="${1:-$HOME/vault/20-surface/claude-memory}"

[ -d "$MEM_DIR" ] || { echo "cc-memory-index-regen: $MEM_DIR does not exist" >&2; exit 1; }

# Regen only: --check reads, and os.replace means it never sees a half-written index.
if [ "$mode" = regen ]; then
    exec 9>"$MEM_DIR/.MEMORY.md.lock"
    flock -w 30 9 || { echo "cc-memory-index-regen: could not lock $MEM_DIR/.MEMORY.md.lock within 30s" >&2; exit 1; }
fi

python3 - "$MEM_DIR" "$mode" <<'EOF'
import os, re, sys, tempfile
mem, mode = sys.argv[1], sys.argv[2]
out = os.path.join(mem, 'MEMORY.md')
LINE = re.compile(r'^- \[\[([^\]]+)\]\] — (.*)$')
NODESC = '(no description)'

def description(stem):
    txt = open(os.path.join(mem, stem + '.md'), encoding='utf-8', errors='replace').read()
    m = re.search(r'^description:\s*(.+?)\s*$', txt, re.M)
    d = m.group(1).strip().strip('"\'') if m else ''
    return d or None

def hook(d):
    if len(d) <= 72:
        return d
    strong = None
    for m in re.finditer(r'(; | — | -- | - |\. )', d):
        if 30 <= m.start() <= 72:
            strong = m.start()
    if strong:
        return d[:strong].rstrip()
    weak = None
    for m in re.finditer(r'(, |: )', d):
        if 30 <= m.start() <= 60:
            weak = m.start()
    if weak:
        return d[:weak].rstrip()
    return d[:60].rsplit(' ', 1)[0].rstrip(' ,;:—-') + '…'

stems = sorted(f[:-3] for f in os.listdir(mem) if f.endswith('.md') and f != 'MEMORY.md')

existing, counts = {}, {}
old = open(out, encoding='utf-8').read() if os.path.exists(out) else ''
for ln in old.splitlines():
    m = LINE.match(ln)
    if m:
        counts[m.group(1)] = counts.get(m.group(1), 0) + 1
        existing.setdefault(m.group(1), m.group(2))

if mode == 'check':
    missing = [s for s in stems if s not in counts]
    dupes = sorted(s for s, n in counts.items() if n > 1)
    orphans = sorted(s for s in counts if s not in set(stems))
    nodesc = [s for s in stems if description(s) is None]
    for label, xs in (('file with no index line', missing), ('duplicate index line', dupes),
                      ('index line with no file', orphans), ('file with no description', nodesc)):
        for x in xs:
            print(f"{label}: {x}")
    ok = not (missing or dupes or orphans or nodesc)
    print(f"cc-memory-index-regen --check: {len(stems)} files, {sum(counts.values())} lines: {'OK' if ok else 'FAIL'}")
    sys.exit(0 if ok else 1)

rows = []
for s in stems:
    if s in existing and existing[s] != NODESC:
        rows.append((s, existing[s]))
        continue
    d = description(s)
    if d is None:
        print(f"cc-memory-index-regen: {s}.md has no description: indexed as '{NODESC}'", file=sys.stderr)
    rows.append((s, hook(d) if d else NODESC))

head = """# Project Memory Index

<!-- COMPACTED (AI_ST-69). One line per memory: [[name]] — hook.
     The hook is scent only; the memory's full one-line description lives in
     its file's frontmatter, and the content lives in the file. Regenerate
     after adding/removing/re-describing memories (locked, atomic, keeps
     existing hooks; --check asserts every file has one line and vice versa):
       bash ~/.claude/cc-memory-index-regen.sh
     (that link is made by environment-foundation agents/scripts/install.sh).
     Do NOT hand-write essays into this file. -->

"""
body = ''.join(f"- [[{s}]] — {h}\n" for s, h in rows)
fd, tmp = tempfile.mkstemp(dir=mem, prefix='.MEMORY.md.')
with os.fdopen(fd, 'w', encoding='utf-8') as fh:
    fh.write(head + body)
os.chmod(tmp, os.stat(out).st_mode & 0o777 if os.path.exists(out) else 0o644)
os.replace(tmp, out)
print(f"cc-memory-index-regen: wrote {out}: {len(rows)} entries, {os.path.getsize(out)} bytes")
EOF
