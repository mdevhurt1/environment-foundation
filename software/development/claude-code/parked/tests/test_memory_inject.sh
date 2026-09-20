#!/usr/bin/env bash
# Description: Behavioral tests for cc-memory-inject.sh (SessionStart memory-index injector) and cc-memory-index-regen.sh (compacted index generator) — the AI_ST-69 load-side machinery.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, jq, python3, coreutils

set -uo pipefail   # NOT -e: every assertion must run and report.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MODULE_DIR/../../.." && pwd)"
# shellcheck source=./harness.sh
# shellcheck disable=SC1091
source "$TESTS_DIR/harness.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"
require_not_root

INJECT_UNDER_TEST="${INJECT_UNDER_TEST:-$MODULE_DIR/canonical/shell/cc-memory-inject.sh}"
REGEN_UNDER_TEST="${REGEN_UNDER_TEST:-$MODULE_DIR/canonical/shell/cc-memory-index-regen.sh}"

t_begin "cc-memory-inject.sh / cc-memory-index-regen.sh"

# =========================================================================
# WHY THIS FILE EXISTS
#
# AI_ST-69's audit finding: the auto-memory location override moved memory
# WRITES to the vault, but nothing moved the LOADS — sessions silently read
# zero memories for months. The injector is the repair. Its failure modes
# are all silent (a hook that emits invalid JSON is dropped; a hook that
# exits non-zero can break session start; an unescaped quote truncates the
# context), so each is pinned here.
# =========================================================================

# --- fixture: a fake $HOME with a vault index ----------------------------

FAKE_HOME=$(t_tmpdir) || exit 1
MEM_DIR="$FAKE_HOME/vault/20-surface/claude-memory"
mkdir -p "$MEM_DIR"

printf '# Project Memory Index\n\n- [[alpha_note]] — first "quoted" hook\n- [[beta_note]] — back\\slash and\ttab\n' \
    > "$MEM_DIR/MEMORY.md"

# --- 1. happy path: valid JSON envelope, content round-trips -------------

t_run env HOME="$FAKE_HOME" bash "$INJECT_UNDER_TEST"
assert_eq "injector exits 0 with index present" "0" "$T_RC"

happy_json="$T_OUT"
assert_rc "injector output is valid JSON" 0 \
    jq -e . <<<"$happy_json"

hook_event=$(jq -r '.hookSpecificOutput.hookEventName' <<<"$happy_json" 2>/dev/null)
assert_eq "hookEventName is SessionStart" "SessionStart" "$hook_event"

ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$happy_json" 2>/dev/null)
assert_contains "context carries the index body" "[[alpha_note]]" "$ctx"
assert_contains "quotes survive the JSON escaping" 'first "quoted" hook' "$ctx"
assert_contains "backslashes survive the JSON escaping" 'back\slash' "$ctx"
assert_contains "context names the store path" "claude-memory" "$ctx"

# --- 2. missing index: emit nothing, exit 0 (never break session start) --

EMPTY_HOME=$(t_tmpdir) || exit 1
t_run env HOME="$EMPTY_HOME" bash "$INJECT_UNDER_TEST"
assert_eq "missing index exits 0" "0" "$T_RC"
assert_eq "missing index emits nothing" "" "$T_OUT"

# --- 3. size guard: oversize index warns instead of injecting ------------

BIG_HOME=$(t_tmpdir) || exit 1
mkdir -p "$BIG_HOME/vault/20-surface/claude-memory"
head -c 80001 /dev/zero | tr '\0' 'x' > "$BIG_HOME/vault/20-surface/claude-memory/MEMORY.md"

t_run env HOME="$BIG_HOME" bash "$INJECT_UNDER_TEST"
assert_eq "oversize index exits 0" "0" "$T_RC"
big_json="$T_OUT"
assert_rc "oversize output is still valid JSON" 0 \
    jq -e . <<<"$big_json"
big_ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$big_json" 2>/dev/null)
assert_contains "oversize context is the warning, not the file" "MEMORY-INDEX WARNING" "$big_ctx"
assert_contains "warning names the regen helper" "cc-memory-index-regen.sh" "$big_ctx"
assert_not_contains "oversize file body is NOT injected" "xxxxxxxxxx" "$big_ctx"

# --- 4. regen: builds one [[name]] line per memory from frontmatter ------

REGEN_DIR=$(t_tmpdir) || exit 1
cat > "$REGEN_DIR/reference_short.md" <<'EOF'
---
name: reference_short
description: A short hook that fits whole
metadata:
  type: reference
---
body
EOF
cat > "$REGEN_DIR/reference_long.md" <<'EOF'
---
name: reference_long
description: This description is deliberately much longer than the seventy-two character cap; everything after the first clause boundary must be cut from the index line, because the index carries scent, not content
metadata:
  type: reference
---
body
EOF
printf 'old index to be replaced\n' > "$REGEN_DIR/MEMORY.md"
printf 'not a memory\n' > "$REGEN_DIR/notes.txt"

t_run bash "$REGEN_UNDER_TEST" "$REGEN_DIR"
assert_eq "regen exits 0" "0" "$T_RC"

idx=$(cat "$REGEN_DIR/MEMORY.md")
assert_contains "short description kept whole" \
    "- [[reference_short]] — A short hook that fits whole" "$idx"
assert_contains "long description present as an entry" "[[reference_long]]" "$idx"
assert_not_contains "long description tail is cut" "scent, not content" "$idx"
assert_not_contains "MEMORY.md does not index itself" "[[MEMORY]]" "$idx"
assert_not_contains "non-markdown files are not indexed" "notes" "$idx"
assert_contains "header warns against essays" "Do NOT hand-write essays" "$idx"

line_count=$(grep -c '^- \[\[' "$REGEN_DIR/MEMORY.md")
assert_eq "exactly one line per memory file" "2" "$line_count"

# --- 5. regen output stays under the injector's size guard ---------------
# The two scripts form one loop: regen writes what inject loads. A regen
# whose output tripped the guard would silently disable recall again.

regen_size=$(wc -c < "$REGEN_DIR/MEMORY.md")
if [ "$regen_size" -le 80000 ]; then
    t_pass "regen fixture output (${regen_size}B) is under the 80000B inject guard"
else
    t_fail "regen fixture output (${regen_size}B) exceeds the 80000B inject guard"
fi

# --- 6. regen refuses a missing directory --------------------------------

t_run bash "$REGEN_UNDER_TEST" "$REGEN_DIR/does-not-exist"
assert_eq "regen exits 1 on missing dir" "1" "$T_RC"

t_finish
