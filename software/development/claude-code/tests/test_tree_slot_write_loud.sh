#!/usr/bin/env bash
# Description: Tests that cc-tree-slot-write.sh fails LOUDLY when the slot cannot be written (INFRA-68) — a genuine write failure must name itself, name the consequence, retry once, and exit non-zero, while the legitimate bare-launch no-ops stay warn-and-exit-0.
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

WRITE_SH="${WRITE_SH_UNDER_TEST:-$MODULE_DIR/canonical/shell/cc-tree-slot-write.sh}"

t_begin "cc-tree-slot-write.sh: a failed slot write is loud, retried once, and non-zero"

# =========================================================================
# WHY THIS FILE EXISTS (INFRA-68)
#
# On 2026-09-04 session aabd7e4c460747558046f2 ran a full lifecycle with no
# slot file and no spawned event. It was invisible to the company-status scan
# and to the reclaim gate for its whole life. The root cause was upstream of
# this script (session-start Step 3 was never invoked at all), but the audit
# it triggered found this script's own failure path just as quiet: a genuine
# write failure died on a raw `mkdir: Permission denied` from set -e, with no
# statement of what had been lost and no second attempt.
#
# The slot is the session's ONLY tree presence. Losing it is not a cosmetic
# failure — it removes the session from every downstream consumer. So the
# failure path is held to three things here: say ERROR, name the session and
# the consequence, and try a second time before giving up.
#
# The legitimate no-ops must NOT become loud. A bare launch (no .cc-mode) and
# a legacy .cc-mode (no session_id) are expected states, not faults; they stay
# exit 0. Tests 5 and 6 pin that, because the easy over-correction here is to
# make every early return fatal and break every non-wrapper launch on the box.
# =========================================================================

WORK=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }

# A worktree whose .cc-mode is valid in every field, so nothing but the write
# itself can be responsible for a failure.
mk_worktree() {
    local wt="$1" sid="${2:-1111111111111111111111}"
    mkdir -p "$wt"
    cat > "$wt/.cc-mode" <<EOF
mode=branched
slug=T-42
started_at=2026-09-04T13:00:00-04:00
parent_repo=/nonexistent/parent-repo
session_id=$sid
parent_id=
model=opus
model_source=env
EOF
}

# Run the writer against a throwaway HOME, from inside $wt, with no ambient
# CC_SESSION_ID. Captures stdout+stderr together: the operator sees one stream.
run_writer() {
    local home="$1" wt="$2"; shift 2
    ( cd "$wt" && env -u CC_SESSION_ID HOME="$home" PATH="${STUB_PATH:-$PATH}" \
        bash "$WRITE_SH" "$@" 2>&1 )
}

# --- 1. an unwritable tree: loud, specific, non-zero ----------------------
H1="$WORK/h1"; SESS1="$H1/vault/20-surface/company/tree/sessions"
mkdir -p "$SESS1"; mk_worktree "$WORK/wt1"
chmod 500 "$SESS1"
out=$(run_writer "$H1" "$WORK/wt1"); rc=$?
chmod 700 "$SESS1"

assert_ne "an unwritable tree does not exit 0" 0 "$rc"
assert_contains "the failure says ERROR, not just a raw mkdir message" "ERROR" "$out"
assert_contains "the failure names the session whose slot was lost" \
    "1111111111111111111111" "$out"
assert_contains "the failure names the slot path it could not write" \
    "$SESS1/1111111111111111111111.md" "$out"
# The operator must be told what the missing slot COSTS, or the message reads
# as a routine warning and gets scrolled past -- which is exactly how the
# 2026-09-04 incident survived its own close-time WARN.
assert_contains "the failure names the consequence (invisible to the status scan)" \
    "INVISIBLE" "$out"

# --- 2. a transient failure is retried once and recovers ------------------
# Determinism over timing: a stub `mkdir` earlier on PATH fails its FIRST call
# and delegates every later call to the real one. Without a retry the script
# gives up on that first failure and writes nothing; with one it succeeds. No
# sleeps, no races -- the attempt count is the only variable.
H2="$WORK/h2"; SESS2="$H2/vault/20-surface/company/tree/sessions"
mkdir -p "$SESS2"; mk_worktree "$WORK/wt2" "2222222222222222222222"
STUBDIR="$WORK/stub"; mkdir -p "$STUBDIR"
cat > "$STUBDIR/mkdir" <<EOF
#!/usr/bin/env bash
# Fail once, then behave. \$COUNTER survives across calls in the same run.
COUNTER="$WORK/mkdir.calls"
n=\$(cat "\$COUNTER" 2>/dev/null || echo 0)
printf '%s' "\$((n+1))" > "\$COUNTER"
if [ "\$n" -eq 0 ]; then
    echo "mkdir: simulated transient failure" >&2
    exit 1
fi
exec /bin/mkdir "\$@"
EOF
chmod +x "$STUBDIR/mkdir"
rm -f "$WORK/mkdir.calls"

STUB_PATH="$STUBDIR:$PATH"
out=$(run_writer "$H2" "$WORK/wt2"); rc=$?
unset STUB_PATH

assert_eq "a transient write failure is retried and the run succeeds" 0 "$rc"
assert_eq "the slot exists after the retry" "yes" \
    "$( [ -s "$SESS2/2222222222222222222222.md" ] && echo yes || echo no )"
assert_contains "the retry is reported, not silent" "retry" "$out"

# --- 3. the retry is bounded: a permanent failure still gives up ----------
# A retry loop that never terminates is a worse bug than the one it fixes.
H3="$WORK/h3"; SESS3="$H3/vault/20-surface/company/tree/sessions"
mkdir -p "$SESS3"; mk_worktree "$WORK/wt3" "3333333333333333333333"
chmod 500 "$SESS3"
out=$(timeout 20 bash -c '
    cd "$2" && env -u CC_SESSION_ID HOME="$1" bash "$3" 2>&1
' _ "$H3" "$WORK/wt3" "$WRITE_SH"); rc=$?
chmod 700 "$SESS3"
assert_ne "a permanently unwritable tree still terminates non-zero" 0 "$rc"
assert_ne "it terminates rather than looping until the timeout kills it" 124 "$rc"

# --- 4. the success line is bound to a slot that actually exists ----------
# feedback_bind_the_success_message_to_the_operation: never print a success
# string on its own line after the operation it claims. The slot is read back
# before "tree slot:" is printed.
H4="$WORK/h4"; SESS4="$H4/vault/20-surface/company/tree/sessions"
mkdir -p "$SESS4"; mk_worktree "$WORK/wt4" "4444444444444444444444"
out=$(run_writer "$H4" "$WORK/wt4"); rc=$?
assert_eq "a clean write exits 0" 0 "$rc"
assert_contains "a clean write reports the slot" "tree slot:" "$out"
assert_eq "and the file it names is non-empty on disk" "yes" \
    "$( [ -s "$SESS4/4444444444444444444444.md" ] && echo yes || echo no )"
assert_contains "the slot records the session id" "session_id: 4444444444444444444444" \
    "$(cat "$SESS4/4444444444444444444444.md" 2>/dev/null)"
assert_not_contains "a clean write says nothing about errors" "ERROR" "$out"

# --- 5. bare launch: no .cc-mode is NOT a failure ------------------------
H5="$WORK/h5"; mkdir -p "$H5/vault/20-surface/company/tree/sessions"
mkdir -p "$WORK/bare"          # deliberately no .cc-mode anywhere above it
out=$( cd "$WORK/bare" && env -u CC_SESSION_ID HOME="$H5" bash "$WRITE_SH" 2>&1 ); rc=$?
assert_eq "a bare launch (no .cc-mode) still exits 0" 0 "$rc"
assert_contains "and says so plainly" "no .cc-mode found" "$out"
assert_not_contains "a bare launch is not an ERROR" "ERROR" "$out"

# --- 6. legacy .cc-mode with no session_id: still a warn-and-continue -----
H6="$WORK/h6"; mkdir -p "$H6/vault/20-surface/company/tree/sessions"
mkdir -p "$WORK/wt6"
printf 'mode=exploration\nslug=legacy\n' > "$WORK/wt6/.cc-mode"
out=$(run_writer "$H6" "$WORK/wt6"); rc=$?
assert_eq "a legacy .cc-mode without session_id exits 0" 0 "$rc"
assert_contains "and warns rather than erroring" "WARN" "$out"
assert_not_contains "a legacy .cc-mode is not an ERROR" "ERROR" "$out"

t_finish
