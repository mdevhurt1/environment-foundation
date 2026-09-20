#!/usr/bin/env bash
# memory-delta.sh — end-conversation Step 1: list memory files touched since
# this session started (started_at from the nearest .cc-mode; bare sessions
# fall back to the last 6 hours). Extracted from the Step 1 inline block
# (INFRA-52) so the skill body stops paying its byte cost every close.

mode_file=$(dir=$(pwd); while [ "$dir" != / ]; do [ -f "$dir/.cc-mode" ] && echo "$dir/.cc-mode" && break; dir=$(dirname "$dir"); done)
started_at=$(grep '^started_at=' "$mode_file" 2>/dev/null | cut -d= -f2-)
if [ -n "$started_at" ]; then
  find ~/vault/20-surface/claude-memory/ -name '*.md' ! -name MEMORY.md -newermt "$started_at"
else
  echo "(no .cc-mode started_at — bare session; falling back to last 6 hours)"
  find ~/vault/20-surface/claude-memory/ -name '*.md' ! -name MEMORY.md -mmin -360
fi
