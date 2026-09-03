#!/usr/bin/env bash
# Description: Behavioral tests for cc-ea-log.sh — the AI_ST-73 one-line-per-action EA trail: line format, append-only behavior, identity resolution, scrubbing.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, coreutils

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

EALOG="${EALOG_UNDER_TEST:-$MODULE_DIR/canonical/shell/cc-ea-log.sh}"

t_begin "cc-ea-log.sh"

# =========================================================================
# WHY THIS FILE EXISTS (AI_ST-73)
#
# The 2026-09-03 audit could not attribute the EA's largest time block
# (1h50m43s, 27% of the session) to mechanics or judgement because no
# artifact recorded EA actions. This trail is the fix; what these tests pin
# is that every line is machine-stamped, five-field, greppable, and that the
# helper never mangles or blocks — a broken logger that aborts a dispatch
# would cost more than the gap it measures.
# =========================================================================

SID="cccccccccccccccccccccc"

D=$(t_tmpdir) || exit 1
LOG="$D/state/ea-actions.log"

# --- 1. line format: five ` | `-separated fields, machine stamp ----------

before=$(date +%s)
bash "$EALOG" --file "$LOG" --session-id "$SID" --task INFRA-43 dispatch "window created, brief delivered"
rc=$?
after=$(date +%s)
assert_eq "append exits 0" 0 "$rc"
assert_eq "log file created (with parent dir)" "yes" "$( [ -f "$LOG" ] && echo yes || echo no )"
assert_eq "exactly one line" "1" "$(wc -l < "$LOG" | tr -d ' ')"

line=$(cat "$LOG")
IFS='|' read -r f1 f2 f3 f4 f5 <<<"$line"
strip() { printf '%s' "$1" | sed 's/^ *//;s/ *$//'; }
stamp_epoch=$(date -d "$(strip "$f1")" +%s 2>/dev/null || echo 0)
if [ "$stamp_epoch" -ge "$before" ] && [ "$stamp_epoch" -le "$after" ]; then
    t_pass "field 1 is a machine ISO stamp"
else
    t_fail "field 1 is a machine ISO stamp" "line: $line"
fi
assert_eq "field 2 is the session id" "$SID" "$(strip "$f2")"
assert_eq "field 3 is the verb" "dispatch" "$(strip "$f3")"
assert_eq "field 4 is the task" "INFRA-43" "$(strip "$f4")"
assert_eq "field 5 is the text" "window created, brief delivered" "$(strip "$f5")"

# --- 2. append-only: a second call adds a line, never truncates ----------

bash "$EALOG" --file "$LOG" --session-id "$SID" merge
assert_eq "second call appends" "2" "$(wc -l < "$LOG" | tr -d ' ')"
assert_contains "first line survives" "window created" "$(cat "$LOG")"
tail_line=$(tail -1 "$LOG")
assert_contains "task defaults to -" "| merge | - |" "$tail_line"

# --- 3. scrubbing: newlines in text collapse to one line -----------------

bash "$EALOG" --file "$LOG" --session-id "$SID" note "$(printf 'multi\nline\ntext')"
assert_eq "newline-laden text still appends exactly one line" "3" "$(wc -l < "$LOG" | tr -d ' ')"
assert_contains "text flattened" "multi line text" "$(tail -1 "$LOG")"

# --- 4. identity resolution order + never-block ---------------------------

# .cc-mode above cwd resolves when no arg/env given.
mkdir -p "$D/wt/deep"
printf 'mode=branched\nsession_id=%s\n' "dddddddddddddddddddddd" > "$D/wt/.cc-mode"
( cd "$D/wt/deep" && env -u CC_SESSION_ID bash "$EALOG" --file "$LOG" brief "from cc-mode" )
assert_contains "identity from nearest .cc-mode" "| dddddddddddddddddddddd | brief |" "$(tail -1 "$LOG")"

# CC_SESSION_ID beats the .cc-mode.
( cd "$D/wt/deep" && CC_SESSION_ID="eeeeeeeeeeeeeeeeeeeeee" bash "$EALOG" --file "$LOG" brief "from env" )
assert_contains "\$CC_SESSION_ID outranks .cc-mode" "| eeeeeeeeeeeeeeeeeeeeee | brief |" "$(tail -1 "$LOG")"

# No identity at all: records "-" and still exits 0 — the trail must never
# block the action it is recording.
( cd "$D" && env -u CC_SESSION_ID bash "$EALOG" --file "$LOG" teardown "no identity" )
assert_eq "no identity: still appends, exit 0" 0 $?
assert_contains "no identity recorded as -" "| - | teardown |" "$(tail -1 "$LOG")"

# --- 5. refusals ----------------------------------------------------------

err=$(bash "$EALOG" --file "$LOG" 2>&1)
assert_eq "missing verb refused (exit 2)" 2 "$?"
err=$(bash "$EALOG" --file "$LOG" "Bad Verb" text 2>&1)
assert_eq "unsafe verb refused (exit 2)" 2 "$?"
assert_eq "refusals never wrote a line" "6" "$(wc -l < "$LOG" | tr -d ' ')"

# --- 6. $CC_EA_LOG_FILE steers the default path --------------------------

CC_EA_LOG_FILE="$D/alt.log" bash "$EALOG" --session-id "$SID" flip AI_ST-19
assert_eq "\$CC_EA_LOG_FILE honoured" "1" "$(wc -l < "$D/alt.log" | tr -d ' ')"

t_finish
