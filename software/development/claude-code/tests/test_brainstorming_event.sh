#!/usr/bin/env bash
# Description: Behavioral tests for the brainstorming skill's spec-written event (AI_ST-65) — the SKILL.md block is extracted and RUN, and its output must match the cc-event-emit.sh format rather than a hand-authored file.
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

SKILL="$MODULE_DIR/canonical/skills/brainstorming/SKILL.md"
EMIT="$MODULE_DIR/canonical/shell/cc-event-emit.sh"

t_begin "brainstorming: the spec-written event (AI_ST-65)"

# =========================================================================
# WHY THIS FILE EXISTS (AI_ST-65)
#
# The skill used to hand-author its spec-written event: a sequential
# NNNN- filename, a hand-typed `ts:` field, and no `session_id`. Both
# halves are the exact defects cc-event-emit.sh was written to remove
# (AI_ST-74) — a NNNN- name landing in a dir that already holds an
# epoch-named event compares below the parent's `.read-up-to` cursor and
# is unread forever, and hand-typed stamps were wrong 4 times in 6 in the
# 2026-09-03 audit. Documentation drifts, so this file does not read the
# prose: it EXTRACTS the skill's emit block and runs it.
# =========================================================================

# --- 1. the skill no longer hand-authors an event -----------------------

skill_text=$(cat "$SKILL")
assert_contains "brainstorming: the emit block invokes cc-event-emit.sh" \
    "cc-event-emit.sh" "$skill_text"
assert_not_contains "brainstorming: no hand-written event heredoc remains" \
    'cat > "$events_dir' "$skill_text"
assert_not_contains "brainstorming: no sequential NNNN- event naming remains" \
    '${next}-spec-written.md' "$skill_text"
assert_not_contains "brainstorming: no hand-typed ts: field remains" \
    'ts: $(date -Iseconds)' "$skill_text"
assert_not_contains "brainstorming: the events dir is not mkdir'd behind the helper" \
    'mkdir -p "$events_dir"' "$skill_text"

# --- 2. extract the block and RUN it ------------------------------------
#
# The block is the fenced ```bash region that follows the "Emit it with the
# stamping helper" paragraph. Pull exactly that one, so a later edit that
# reintroduces hand-authoring fails here rather than passing on prose.

D=$(t_tmpdir) || exit 1
block="$D/emit-block.sh"
awk '
  /^Emit it with the stamping helper/ { armed = 1; next }
  armed && /^```bash$/ { infence = 1; armed = 0; next }
  infence && /^```$/   { exit }
  infence             { print }
' "$SKILL" > "$block"

[ -s "$block" ] \
    && t_pass "brainstorming: the emit block was found and extracted" \
    || t_fail "brainstorming: the emit block was found and extracted"

# A fake HOME so the block's `~/.claude/skills/../shell/cc-event-emit.sh`
# path resolves the way it does on a configured machine — which also pins
# that the documented path is the deployed one, not a repo-relative guess.
export HOME="$D/home"
SID="bbbbbbbbbbbbbbbbbbbbbb"
EV="$HOME/vault/20-surface/company/tree/sessions/${SID}.events"
mkdir -p "$HOME/.claude/shell" "$EV"
cp "$EMIT" "$HOME/.claude/shell/cc-event-emit.sh"
mkdir -p "$HOME/.claude/skills"

# The dir already holds an epoch-named event, which is the case that broke
# the old sequential naming: the new event must sort ABOVE it.
prior=$(( $(date +%s) - 10 ))
printf -- '---\nevent_id: %s\n---\n' "$prior" > "$EV/$prior-spawned.md"

session_id="$SID"
task_dir="$HOME/vault/20-surface/company/tasks/demo"
mkdir -p "$task_dir"
export session_id task_dir

# Deliberately WRONG ambient identity. The helper's fallback order is
# --session-id > $CC_SESSION_ID > .cc-mode, so a block that omits the flag
# stamps whatever session happens to be running it — which, for a skill run
# inside one session about a spec belonging to another, is the wrong answer.
# This value must not appear in the emitted event.
export CC_SESSION_ID="cccccccccccccccccccccc"

out=$(bash "$block" 2>&1); rc=$?
assert_eq "brainstorming: the emit block exits 0" "0" "$rc"

ev=$(find "$EV" -maxdepth 1 -name '*-spec-written.md' 2>/dev/null | head -1)
[ -n "$ev" ] \
    && t_pass "brainstorming: a spec-written event was written" \
    || { t_fail "brainstorming: a spec-written event was written"; t_finish; exit 1; }

fm() { { grep -m1 "^$2:" "$1" || true; } | sed "s/^$2:[[:space:]]*//"; }
base=$(basename "$ev")
lead=${base%%-*}

# --- 3. the format is cc-event-emit.sh's, field for field ---------------

assert_eq "brainstorming: the event carries the session_id from .cc-mode, not \$CC_SESSION_ID" \
    "$SID" "$(fm "$ev" session_id)"
assert_eq "brainstorming: verb is spec-written" \
    "spec-written" "$(fm "$ev" verb)"
assert_eq "brainstorming: severity is info" \
    "info" "$(fm "$ev" severity)"
assert_eq "brainstorming: event_id matches the filename's leading number" \
    "$lead" "$(fm "$ev" event_id)"

# emitted_at, not ts — the field name the readers grep for.
[ -n "$(fm "$ev" emitted_at)" ] \
    && t_pass "brainstorming: the event is stamped emitted_at" \
    || t_fail "brainstorming: the event is stamped emitted_at"
[ -z "$(fm "$ev" ts)" ] \
    && t_pass "brainstorming: the legacy hand-typed ts: field is gone" \
    || t_fail "brainstorming: the legacy hand-typed ts: field is gone"

# The stamp is machine-true, not typed: within a minute of now.
now=$(date +%s)
stamped=$(date -d "$(fm "$ev" emitted_at)" +%s 2>/dev/null || echo 0)
[ "$stamped" -gt 0 ] && [ $(( now - stamped )) -lt 60 ] && [ $(( now - stamped )) -ge -60 ] \
    && t_pass "brainstorming: emitted_at is machine-stamped, not hand-typed" \
    || t_fail "brainstorming: emitted_at is machine-stamped, not hand-typed (got $(fm "$ev" emitted_at))"

# The naming rule, which is the half that poisoned the read marker.
[ "$lead" -gt "$prior" ] \
    && t_pass "brainstorming: the event name sorts ABOVE the epoch-named prior event" \
    || t_fail "brainstorming: the event name sorts ABOVE the epoch-named prior event ($lead vs $prior)"
case "$base" in
    [0-9][0-9][0-9][0-9]-spec-written.md)
        t_fail "brainstorming: the name is not the old 4-digit sequential form" ;;
    *)  t_pass "brainstorming: the name is not the old 4-digit sequential form" ;;
esac

# The body must carry the spec path — the one thing the parent needs.
assert_contains "brainstorming: the body names the spec path" \
    "$task_dir/spec.md" "$(cat "$ev")"

# --- 4. a missing events dir is surfaced, not mkdir'd -------------------
#
# The helper refuses (exit 4) on a missing dir because that means the
# addressee is wrong. The skill must not paper over it.

rm -rf "$EV"
out2=$(bash "$block" 2>&1); rc2=$?
assert_eq "brainstorming: a missing events dir fails the block" "4" "$rc2"
[ ! -d "$EV" ] \
    && t_pass "brainstorming: a missing events dir is NOT invented" \
    || t_fail "brainstorming: a missing events dir is NOT invented"
assert_contains "brainstorming: the refusal names the tree-slot writer as the fix" \
    "cc-tree-slot-write.sh" "$out2"

t_finish
