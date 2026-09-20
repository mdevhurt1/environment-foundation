#!/usr/bin/env bash
# Regenerate the compacted memory index at ~/vault/20-surface/claude-memory/MEMORY.md.
#
# WHY (AI_ST-69, 2026-09-03): the index is injected into EVERY session by
# cc-memory-inject.sh, so its size is a per-session context tax. This script
# rebuilds it as one line per memory —
#     - [[name]] — <hook>
# where the hook is the memory's frontmatter `description:` cut at a clause
# boundary (<=72 chars). The full description stays in the file; the index
# carries scent, not content. Measured 2026-09-03: 424 entries -> 48.6KB
# (~14.2K tokens with @anthropic-ai/tokenizer), vs 239KB (~65K tokens) for
# the essay-style index it replaced.
#
# Idempotent and content-derived: run it after adding, removing, or
# re-describing memories. It writes MEMORY.md in place.

set -euo pipefail

MEM_DIR="${1:-$HOME/vault/20-surface/claude-memory}"

[ -d "$MEM_DIR" ] || { echo "cc-memory-index-regen: $MEM_DIR does not exist" >&2; exit 1; }

python3 - "$MEM_DIR" <<'EOF'
import os, re, sys
mem = sys.argv[1]

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

rows = []
for f in sorted(os.listdir(mem)):
    if f == 'MEMORY.md' or not f.endswith('.md'):
        continue
    txt = open(os.path.join(mem, f), encoding='utf-8', errors='replace').read()
    m = re.search(r'^description:\s*(.+?)$', txt, re.M)
    d = m.group(1).strip() if m else f[:-3].replace('_', ' ')
    rows.append((f[:-3], hook(d)))

head = """# Project Memory Index

<!-- COMPACTED (AI_ST-69). One line per memory: [[name]] — hook.
     The hook is scent only; the memory's full one-line description lives in
     its file's frontmatter, and the content lives in the file. Regenerate
     after adding/removing/re-describing memories:
       bash ~/.claude/cc-memory-index-regen.sh
     Do NOT hand-write essays into this file; it is loaded into every session. -->

"""
body = ''.join(f"- [[{s}]] — {h}\n" for s, h in rows)
out = os.path.join(mem, 'MEMORY.md')
with open(out, 'w', encoding='utf-8') as fh:
    fh.write(head + body)
print(f"cc-memory-index-regen: wrote {out}: {len(rows)} entries, {os.path.getsize(out)} bytes")
EOF
