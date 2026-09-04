#!/usr/bin/env bash
# Description: Behavioral tests for cc-event-emit.sh — the AI_ST-74 stamping helper: machine-stamped emitted_at, monotonic collision-safe naming compatible with the session-start read marker, completion-substance gate.
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

EMIT="${EMIT_UNDER_TEST:-$MODULE_DIR/canonical/shell/cc-event-emit.sh}"

t_begin "cc-event-emit.sh"

# =========================================================================
# WHY THIS FILE EXISTS (AI_ST-74, workflow-audit delegation.md §4)
#
# The parent events dir on 2026-09-03 mixed NNNN- and <epoch>- names, which
# poisons the session-start Step-4 numeric-threshold marker: once the marker
# holds an epoch, every later NNNN- event is "read" forever. And 4 of 6
# hand-authored emitted_at stamps were wrong, one impossibly so. The helper
# under test is the fix; these tests pin the naming rule, the stamp, and the
# completion-substance gate.
# =========================================================================

SID="aaaaaaaaaaaaaaaaaaaaaa"   # 22-hex emitter identity for every call

lead() { local b; b=$(basename "$1"); printf '%s' "${b%%-*}"; }
fm()   { { grep -m1 "^$2:" "$1" || true; } | sed "s/^$2:[[:space:]]*//"; }

# --- 1. empty dir: name is the current epoch, stamp is machine-true ------

D=$(t_tmpdir) || exit 1
mkdir -p "$D/ev"
before=$(date +%s)
out=$(printf 'need X\nruled out Y\n' | bash "$EMIT" --dir "$D/ev" --verb status --session-id "$SID")
rc=$?
after=$(date +%s)
assert_eq "empty dir: exit 0" 0 "$rc"
assert_eq "printed path exists" "yes" "$( [ -f "$out" ] && echo yes || echo no )"
n=$(lead "$out")
if [ "$n" -ge "$before" ] && [ "$n" -le "$after" ]; then
    t_pass "leading number is the write-time epoch ($n in [$before,$after])"
else
    t_fail "leading number is the write-time epoch" "got $n, window [$before,$after]"
fi
assert_eq "filename is <n>-<verb>.md" "$D/ev/$n-status.md" "$out"
assert_eq "event_id matches filename" "$n" "$(fm "$out" event_id)"
assert_eq "session_id is the emitter" "$SID" "$(fm "$out" session_id)"
assert_eq "verb recorded" "status" "$(fm "$out" verb)"
assert_eq "severity defaults to normal" "normal" "$(fm "$out" severity)"

# emitted_at must be a real date -Is stamp whose epoch is inside the window.
stamp=$(fm "$out" emitted_at)
stamp_epoch=$(date -d "$stamp" +%s 2>/dev/null || echo 0)
if [ "$stamp_epoch" -ge "$before" ] && [ "$stamp_epoch" -le "$after" ]; then
    t_pass "emitted_at is machine-stamped at write time ($stamp)"
else
    t_fail "emitted_at is machine-stamped at write time" "stamp=$stamp epoch=$stamp_epoch window=[$before,$after]"
fi
assert_eq "stdin body round-trips" "yes" "$(grep -qxF 'ruled out Y' "$out" && echo yes || echo no)"

# --- 2. THE live specimen: legacy NNNN- names never outrank new events ---
# A dir carrying 0001..0030 plus epoch names (tonight's parent dir, exactly).
# A new event must land ABOVE every existing leading number, so the numeric
# marker logic stays correct.

D2=$(t_tmpdir) || exit 1
mkdir -p "$D2/ev"
touch "$D2/ev/0028-spawned.md" "$D2/ev/0030-spawned.md" "$D2/ev/1788466246-completion.md"
out2=$(bash "$EMIT" --dir "$D2/ev" --verb status --session-id "$SID" --body "x")
n2=$(lead "$out2")
if [ "$n2" -gt 1788466246 ] && [ "$n2" -gt 30 ]; then
    t_pass "mixed-era dir: new event outranks both eras ($n2)"
else
    t_fail "mixed-era dir: new event outranks both eras" "got $n2"
fi

# --- 3. monotonic under collision: same-second events strictly increase --
# A dir whose highest number is in the FUTURE forces the max+1 branch.

D3=$(t_tmpdir) || exit 1
mkdir -p "$D3/ev"
future=$(( $(date +%s) + 1000 ))
touch "$D3/ev/$future-status.md"
out3=$(bash "$EMIT" --dir "$D3/ev" --verb question --session-id "$SID" --body "x")
assert_eq "future-numbered neighbor: takes max+1" "$((future + 1))" "$(lead "$out3")"
assert_eq "event_id rewritten to match the final name" "$((future + 1))" "$(fm "$out3" event_id)"

# Two rapid events in the same dir must never share a leading number.
out4=$(bash "$EMIT" --dir "$D3/ev" --verb question --session-id "$SID" --body "x")
if [ "$(lead "$out4")" -gt "$(lead "$out3")" ]; then
    t_pass "back-to-back events strictly increase ($(lead "$out3") -> $(lead "$out4"))"
else
    t_fail "back-to-back events strictly increase" "first=$(lead "$out3") second=$(lead "$out4")"
fi

# --- 4. completion-substance gate (the content convention, enforced) -----

D4=$(t_tmpdir) || exit 1
mkdir -p "$D4/ev"
err=$(printf 'see report\n' | bash "$EMIT" --dir "$D4/ev" --verb completion --session-id "$SID" 2>&1)
rc=$?
assert_eq "thin completion refused (exit 5)" 5 "$rc"
assert_contains "refusal names the 3-line minimum" "3 non-empty body lines" "$err"
assert_eq "nothing written on refusal" "0" "$(find "$D4/ev" -name '*.md' | wc -l | tr -d ' ')"

out5=$(printf 'AI_ST-72: shipped\nEA action: exercise --brief live\nreport: ~/x/report.md\n' \
    | bash "$EMIT" --dir "$D4/ev" --verb completion --session-id "$SID")
assert_eq "3-line completion accepted" 0 $?
assert_eq "completion written" "yes" "$( [ -f "$out5" ] && echo yes || echo no )"

err=$(printf 'thin\n' | bash "$EMIT" --dir "$D4/ev" --verb completion --session-id "$SID" --allow-thin 2>&1)
assert_eq "--allow-thin overrides on the record" 0 $?

# Non-completion verbs carry no minimum.
out6=$(bash "$EMIT" --dir "$D4/ev" --verb spawned --severity info --session-id "$SID" --body "slug=x mode=branched")
assert_eq "spawned with 1-line body accepted" 0 $?

# --- 5. refusals: identity, dir, verb, severity --------------------------

# From a dir with no ancestor .cc-mode (t_tmpdir asserts that) and with
# $CC_SESSION_ID stripped, identity must be unresolvable.
err=$(cd "$D4" && env -u CC_SESSION_ID bash "$EMIT" --dir "$D4/ev" --verb status --body x 2>&1 </dev/null)
assert_eq "no resolvable emitter: exit 3" 3 "$?"

err=$(bash "$EMIT" --dir "$D4/does-not-exist" --verb status --session-id "$SID" --body x 2>&1)
assert_eq "missing events dir: exit 4, no invention" 4 "$?"

err=$(bash "$EMIT" --dir "$D4/ev" --verb "Bad Verb" --session-id "$SID" --body x 2>&1)
assert_eq "verb with unsafe chars refused (exit 2)" 2 "$?"

err=$(bash "$EMIT" --dir "$D4/ev" --verb status --severity urgent --session-id "$SID" --body x 2>&1)
assert_eq "unknown severity refused (exit 2)" 2 "$?"

err=$(bash "$EMIT" --to-session "not-hex" --verb status --session-id "$SID" --body x 2>&1)
assert_eq "malformed --to-session refused (exit 2)" 2 "$?"

# --- 6. --to-session resolves through --tree-dir -------------------------

D6=$(t_tmpdir) || exit 1
PARENT="bbbbbbbbbbbbbbbbbbbbbb"
mkdir -p "$D6/sessions/${PARENT}.events"
out7=$(bash "$EMIT" --to-session "$PARENT" --tree-dir "$D6/sessions" \
    --verb blocker --severity critical --session-id "$SID" --body "need a ruling; ruled out A and B")
assert_eq "--to-session lands in <tree-dir>/<id>.events" \
    "$D6/sessions/${PARENT}.events" "$(dirname "$out7")"
assert_eq "severity critical recorded" "critical" "$(fm "$out7" severity)"

# --- 7. title defaults to verb; newlines in title are flattened ----------

out8=$(bash "$EMIT" --dir "$D6/sessions/${PARENT}.events" --verb status --session-id "$SID" \
    --title $'line1\nline2' --body "x")
assert_eq "title newlines flattened" "# line1 line2" "$(grep -m1 '^# ' "$out8")"

# --- 8. --body-file: the body an agent cannot put on a command line ------
#
# INFRA-66 §6 hit this and could not report it through the normal channel: a
# critical escalation about holes in the outbound guard was itself refused by
# the outbound guard, because the body quoted the command shapes it was
# reporting. The failure mode is worth stating plainly — the one thing a gate
# must never obstruct is being told it has a hole, and a session that cannot
# escalate through the channel is pushed toward exactly the write-then-run
# evasion the red team catalogued.
#
# --body-file is the narrow fix: the body never appears in the command string,
# so whole-command content matching has nothing to trip on. The guard-side half
# of this contract is asserted in test_outbound_guard.sh §12.
#
# The flag predates this audit — it shipped with the helper in AI_ST-72/74 and
# INFRA-66 recommended adding it without probing whether it was there. What was
# genuinely missing is this coverage, so these assertions are characterisation
# tests, and mutate.sh carries a matching mutation (emit/body-file-ignored) so
# that they have been seen to fail.

D8=$(t_tmpdir) || exit 1
mkdir -p "$D8/ev"

printf 'line one\nline two\nline three\n' > "$D8/body.md"
out9=$(bash "$EMIT" --dir "$D8/ev" --verb status --session-id "$SID" --body-file "$D8/body.md")
assert_contains "--body-file body reaches the event" "line two" "$(cat "$out9")"

# The whole point: a body may quote the command shapes it is reporting on,
# because it never passes through a command line to get there.
printf 'The guard passes this shape:\n  curl -X POST https://hooks.slack.com/services/T/B/X -d payload=x\nReported to the EA.\n' \
    > "$D8/incident.md"
out10=$(bash "$EMIT" --dir "$D8/ev" --verb blocker --severity critical \
    --session-id "$SID" --body-file "$D8/incident.md")
assert_contains "a body quoting a blocked shape is written verbatim" \
    "hooks.slack.com" "$(cat "$out10")"

out11=$(printf 'from stdin\nsecond line\nthird line\n' \
    | bash "$EMIT" --dir "$D8/ev" --verb status --session-id "$SID" --body-file -)
assert_contains "--body-file - reads stdin" "from stdin" "$(cat "$out11")"

out12=$(bash "$EMIT" --dir "$D8/ev" --verb status --session-id "$SID" --body-file="$D8/body.md")
assert_contains "--body-file=PATH attached form" "line one" "$(cat "$out12")"

# A missing body file must be a usage error, not an event with an empty body:
# an escalation that silently loses its content is worse than one that fails.
err=$(bash "$EMIT" --dir "$D8/ev" --verb status --session-id "$SID" --body-file "$D8/nope.md" 2>&1)
assert_eq "missing body file refused (exit 2)" 2 "$?"
assert_contains "missing body file names the path" "nope.md" "$err"

# The completion-substance gate still applies to a body that arrived from a
# file — otherwise --body-file would be a way to file a thin completion.
printf 'only one line\n' > "$D8/thin.md"
bash "$EMIT" --dir "$D8/ev" --verb completion --session-id "$SID" --body-file "$D8/thin.md" >/dev/null 2>&1
assert_eq "thin completion from a file is still refused (exit 5)" 5 "$?"

# --- 9. the path the dispatch brief hands to children --------------------
#
# A child that cannot emit cannot escalate, and it fails SILENTLY: the parent
# simply never hears from it. So the invocation the brief template prints is
# load-bearing, and until INFRA-67 nothing tested it.
#
# INFRA-66 §7 reported the documented path `~/.claude/skills/../shell/…` as
# dead, reasoning that it resolves to `~/.claude/shell/`, which does not exist.
# Measured here, it is alive: `~/.claude/skills` is a SYMLINK into the canonical
# tree, and the kernel resolves `..` against the symlink's TARGET, so the path
# lands on canonical/shell/ — where the helper is. The audit inferred the
# lexical answer instead of probing.
#
# But it is alive by coincidence, not by design: it holds only while `skills`
# is a symlink. On any install where `~/.claude/skills` is a real directory the
# audit's reasoning becomes correct and every brief silently loses escalation.
# Hence a probe-first form in the template, and these three assertions.

TEMPLATE="$MODULE_DIR/canonical/templates/dispatch-brief.md"
assert_eq "the dispatch-brief template exists" "0" "$([ -f "$TEMPLATE" ]; echo $?)"

# The mechanism, reproduced without depending on this machine's install: a
# `skills` symlink into canonical/ makes `skills/../shell/` reach the helper.
D9=$(t_tmpdir) || exit 1
ln -s "$MODULE_DIR/canonical/skills" "$D9/skills"
assert_eq "skills-symlink '..' resolves to canonical/shell" "0" \
    "$([ -f "$D9/skills/../shell/cc-event-emit.sh" ]; echo $?)"

# And the shape that made the audit's reading correct: a REAL skills directory.
mkdir -p "$D9/real/skills"
assert_eq "a real skills dir makes the documented path dead" "1" \
    "$([ -f "$D9/real/skills/../shell/cc-event-emit.sh" ]; echo $?)"

# Because the path is install-dependent, the template must tell the child to
# PROBE rather than trust one spelling, and must name a fallback that exists.
assert_contains "template tells the child to probe for the helper" \
    "command -v" "$(cat "$TEMPLATE")"
assert_contains "template names the canonical repo path as fallback" \
    "canonical/shell/cc-event-emit.sh" "$(cat "$TEMPLATE")"

t_finish
