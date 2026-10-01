#!/usr/bin/env bash
# SessionStart hook: inject the compacted memory index into every session.
#
# WHY THIS EXISTS (AI_ST-69, 2026-09-03)
# --------------------------------------
# The auto-memory location override (CLAUDE.md) moved memory WRITES to
# ~/vault/20-surface/claude-memory/, but the harness only auto-loads
# MEMORY.md from the default ~/.claude/projects/<encoded-cwd>/memory/
# location — which the override left empty everywhere. Sessions therefore
# loaded ZERO of the 400+ accumulated memories. This hook closes the loop:
# it emits the vault index as SessionStart additionalContext, so every
# session starts with the recall surface the memory protocol assumes.
#
# The index it injects is the COMPACTED form (one [[name]] — hook line per
# memory, ~14K tokens measured 2026-09-03). Full memory bodies stay in
# their files; sessions Read the files the index points them at.
#
# POINTER, NOT PAYLOAD (AI_ST-123, 2026-10-01 hotfix): the index outgrew the
# SessionStart channel. At ~65KB the harness saved the payload to disk and
# injected only a 2KB preview (~2% of the lines), with the preamble still
# claiming the whole index was present. A byte budget only postpones that,
# since the index grows a line per memory, so the hook now emits a short
# instruction to Read MEMORY.md, plus its line count so a partial read shows.

set -euo pipefail

MEMORY_MD="$HOME/vault/20-surface/claude-memory/MEMORY.md"

# A missing vault or index must not break session start — emit nothing, exit 0.
[ -r "$MEMORY_MD" ] || exit 0

lines=$(grep -c '^- \[\[' "$MEMORY_MD" || true)
context="<memory-index>\nYour persistent memory index is NOT inlined here (it outgrew the SessionStart channel). Before any task that could touch it, Read ${MEMORY_MD} in full: ${lines} memory lines, one [[name]] — hook per line, where [[name]] maps to <name>.md in that directory. If you see fewer lines than that, keep reading. When a task touches a memory, Read that file before re-deriving or re-asking. Memories reflect what was true when written — verify referents (paths, hashes, flags) before recommending them.\n</memory-index>"

# printf, not a heredoc: bash 5.3+ hangs on heredocs here (obra/superpowers#571).
printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "SessionStart",\n    "additionalContext": "%s"\n  }\n}\n' "$context"
