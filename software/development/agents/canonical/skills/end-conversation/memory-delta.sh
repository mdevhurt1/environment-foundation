#!/usr/bin/env bash
# memory-delta.sh [<start-time>] — end-conversation Step 1: list memory files
# touched since this session started. <start-time> is anything `find
# -newermt` accepts (e.g. "2026-10-01 14:42"); without it, fall back to the
# last 6 hours.

mem=~/vault/20-surface/claude-memory/
if [ -n "${1:-}" ]; then
  find "$mem" -name '*.md' ! -name MEMORY.md -newermt "$1"
else
  echo "(no start time given; falling back to last 6 hours)"
  find "$mem" -name '*.md' ! -name MEMORY.md -mmin -360
fi
