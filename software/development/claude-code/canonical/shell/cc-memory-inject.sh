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
# SIZE GUARD: if MEMORY.md regrows past MAX_BYTES (essays pasted into index
# lines is exactly how it reached 239KB/65K tokens before AI_ST-69), inject
# a loud one-line warning instead of the file, so the bloat is surfaced
# rather than silently taxing every session's context window. Regenerate
# with cc-memory-index-regen.sh to compact it again.

set -euo pipefail

MEMORY_MD="$HOME/vault/20-surface/claude-memory/MEMORY.md"
MAX_BYTES=80000

# A missing vault or index must not break session start — emit nothing, exit 0.
[ -r "$MEMORY_MD" ] || exit 0

escape_for_json() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

size=$(wc -c < "$MEMORY_MD")
if [ "$size" -gt "$MAX_BYTES" ]; then
    context="MEMORY-INDEX WARNING: ${MEMORY_MD} is ${size} bytes (limit ${MAX_BYTES}) and was NOT injected. The index has re-bloated past the AI_ST-69 compaction budget. Read it explicitly only if you need recall, and regenerate it with: bash ~/.claude/cc-memory-index-regen.sh"
else
    body=$(cat "$MEMORY_MD")
    escaped=$(escape_for_json "$body")
    context="<memory-index>\nYour persistent memory index (~/vault/20-surface/claude-memory/). Each line is one memory: [[name]] maps to <name>.md in that directory. When a task touches something listed here, Read that file before re-deriving or re-asking. Memories reflect what was true when written — verify referents (paths, hashes, flags) before recommending them.\n\n${escaped}\n</memory-index>"
fi

# printf, not a heredoc: bash 5.3+ hangs on heredocs here (obra/superpowers#571).
printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "SessionStart",\n    "additionalContext": "%s"\n  }\n}\n' "$context"
