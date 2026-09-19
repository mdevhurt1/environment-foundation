#!/usr/bin/env bash
# render-transcript.sh <input.jsonl> <output.md> [<session-goal>]
# Best-effort JSONL -> markdown converter for Claude Code transcript files.
# Handles the real Claude Code JSONL schema where each line is a wrapped event:
#   {"type":"user"|"assistant", "message":{"role":..., "content":...}, ...}
# Content may be a string (plain message) or an array of typed blocks
# (text, tool_use, tool_result, thinking). Thinking blocks are silently skipped.
# Sidechain (subagent) and meta events are excluded to keep the main thread readable.

set -euo pipefail

[ $# -ge 2 ] || { echo "usage: $0 <input.jsonl> <output.md> [<session-goal>]" >&2; exit 64; }
in="$1"
out="$2"
goal="${3:-}"

[ -r "$in" ] || { echo "cannot read $in" >&2; exit 66; }

{
    echo "---"
    echo "title: ${goal:-Claude session}"
    echo "source: $in"
    echo "rendered: $(date -Iseconds)"
    echo "---"
    echo
    echo "# ${goal:-Claude Session Transcript}"
    echo

    # Each line is a JSON event. Filter to user/assistant turns on the main
    # thread only. Skip meta events (internal CLI command wrappers) and sidechains.
    #
    # Content is either:
    #   string  -> render directly (skip internal <command-name>/local-command tags)
    #   array   -> iterate; render text blocks inline, summarize tool_use/tool_result,
    #              skip thinking blocks (signature noise, no prose value)
    jq -r '
      select((.type == "user" or .type == "assistant")
             and (.isSidechain // false | not)
             and (.isMeta // false | not))
      | .message as $m
      | if ($m.content | type) == "string" then
          # Skip internal CLI command/local-command wrappers
          if ($m.content | startswith("<command-name>"))
             or ($m.content | startswith("<local-command")) then
            empty
          else
            "## " + $m.role + "\n\n" + $m.content + "\n"
          end
        else
          ([$m.content[] |
             if .type == "text" then .text
             elif .type == "tool_use" then
               "**Tool:** " + .name + "\n```json\n" + (.input | tojson) + "\n```"
             elif .type == "tool_result" then
               "**Tool result:** " + ((.content | tostring)[0:500])
               + (if (.content | tostring | length) > 500 then " …(truncated)" else "" end)
             else empty end
            ] | join("\n\n")) as $body
          | if ($body | length) == 0 then empty
            else "## " + $m.role + "\n\n" + $body + "\n" end
        end
    ' "$in"
} > "$out"

echo "rendered $(wc -l < "$in") lines -> $out" >&2
