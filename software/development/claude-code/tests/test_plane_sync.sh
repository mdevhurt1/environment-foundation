#!/usr/bin/env bash
# Description: Behavioral tests for canonical/shell/cc-plane-sync.sh — usage refusals, identity resolution precedence, the fail-soft network contract, and the real HTTP flows against a loopback fake Plane (INFRA-49).
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, python3, coreutils, canonical/shell/cc-plane-sync.sh

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

# Overridable so mutate.sh can point this file at a deliberately broken copy.
PLANE_SYNC_UNDER_TEST="${PLANE_SYNC_UNDER_TEST:-$MODULE_DIR/canonical/shell/cc-plane-sync.sh}"

t_begin "cc-plane-sync.sh: refusals, identity precedence, fail-soft, and the HTTP flows"

# =========================================================================
# WHY THIS FILE EXISTS
#
# cc-plane-sync.sh is 550 lines that run on the ONLY code path executed
# every session — the bookends — and it landed the same day as the test
# harness with zero tests (audit F3, INFRA-49). Its contract is peculiar
# and easy to regress in either direction:
#
#   * exit 2 is reserved for usage errors, refused BEFORE any request;
#   * every network/auth/lookup failure must warn and exit 0, because a
#     bookend that hard-fails on an HTTP 000 makes every session in the
#     company unstartable during a UDM IPS event (INFRA-37);
#   * writes must be verified by re-fetch, never trusted from the write
#     response (feedback_fresh_status_checks).
#
# Nothing here touches the live Plane: the HTTP cases run against a
# loopback fake (CC_PLANE_BASE seam), the auth cases against a sandbox
# $HOME, and every .cc-mode is a fixture passed via --mode-file.
# =========================================================================

SYNC="$PLANE_SYNC_UNDER_TEST"
FIX=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }

# A sandbox HOME. With no settings.local.json it exercises the no-key soft
# path; later a fixture key file makes the HTTP cases reachable.
FAKEHOME="$FIX/home"
mkdir -p "$FAKEHOME/.claude"

# Fixture .cc-mode files (always passed via --mode-file so the real
# worktree's .cc-mode above cwd can never leak into a test).
MODE_PLAIN="$FIX/mode-plain";      printf 'session_id=aaaaaaaaaaaaaaaaaaaaaa\nslug=notanissue\n' > "$MODE_PLAIN"
MODE_SLUGREF="$FIX/mode-slugref";  printf 'session_id=aaaaaaaaaaaaaaaaaaaaaa\nslug=TST-8\n'      > "$MODE_SLUGREF"
MODE_TASKMD="$FIX/mode-taskmd";    printf 'session_id=aaaaaaaaaaaaaaaaaaaaaa\nslug=mytask\n'     > "$MODE_TASKMD"
MODE_PIN="$FIX/mode-pin";          printf 'session_id=aaaaaaaaaaaaaaaaaaaaaa\nslug=mytask\nplane_issue=TST-8\n' > "$MODE_PIN"

# Task-folder fixture for precedence 3 (plane.md back-reference).
TASKS="$FIX/tasks"
mkdir -p "$TASKS/mytask"
printf 'plane: TST-7\n' > "$TASKS/mytask/plane.md"

# run_sync <extra env...> -- <args...>
# Proxy vars are stripped: the fake server lives on loopback and an ambient
# http_proxy would route the request off-box and fail the wrong way.
run_sync() {
    local -a envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
        HOME="$FAKEHOME" CC_PLANE_TASKS_DIR="$TASKS" CC_PLANE_SLOTS_DIR="$FIX/slots" \
        "${envs[@]}" bash "$SYNC" "$@"
}

# --- 1. usage errors: exit 2, refused before any request ------------------
t_run run_sync X=1 --
assert_eq "no subcommand refuses with exit 2" "2" "$T_RC"

t_run run_sync X=1 -- frobnicate
assert_eq "unknown subcommand refuses with exit 2" "2" "$T_RC"
assert_contains "unknown subcommand is named in the refusal" "frobnicate" "$T_ERR"

t_run run_sync X=1 -- finish
assert_eq "finish without a disposition refuses with exit 2" "2" "$T_RC"

t_run run_sync X=1 -- finish sideways
assert_eq "finish with an invalid disposition refuses with exit 2" "2" "$T_RC"

t_run run_sync X=1 -- finish done --issue TST-7
assert_eq "finish without --note refuses with exit 2" "2" "$T_RC"
assert_contains "the --note refusal explains itself" "audit line" "$T_ERR"

t_run run_sync X=1 -- resolve --issue
assert_eq "an option with a missing value refuses with exit 2" "2" "$T_RC"
assert_contains "the missing value names its flag" "--issue requires a value" "$T_ERR"

t_run run_sync X=1 -- resolve stray-positional
assert_eq "an unexpected positional refuses with exit 2" "2" "$T_RC"

t_run run_sync X=1 -- --help
assert_eq "--help exits 0" "0" "$T_RC"
assert_contains "--help prints the usage text" "usage: cc-plane-sync.sh" "$T_OUT"

# --- 2. session-id assertion: refuse a mismatch before any write ----------
t_run run_sync X=1 -- start --mode-file "$MODE_PLAIN" --session-id bbbbbbbbbbbbbbbbbbbbbb
assert_eq "asserted session id mismatching .cc-mode refuses with exit 2" "2" "$T_RC"
assert_contains "the refusal names the asserted id" "bbbbbbbbbbbbbbbbbbbbbb" "$T_ERR"
assert_contains "the refusal names the .cc-mode id" "aaaaaaaaaaaaaaaaaaaaaa" "$T_ERR"

# --- 3. auth soft-fails: no key / empty key warn and exit 0 ---------------
t_run run_sync X=1 -- start --issue TST-7
assert_eq "missing settings.local.json exits 0 (bookend not blocked)" "0" "$T_RC"
assert_contains "missing key warns and says it is continuing" "no Plane API key" "$T_ERR"

printf '{"env":{"PLANE_API_KEY":""}}\n' > "$FAKEHOME/.claude/settings.local.json"
t_run run_sync X=1 -- start --issue TST-7
assert_eq "empty API key exits 0" "0" "$T_RC"
assert_contains "empty key warns distinctly" "key is empty" "$T_ERR"

# From here on the sandbox carries a fixture key.
printf '{"env":{"PLANE_API_KEY":"test-key-not-real"}}\n' > "$FAKEHOME/.claude/settings.local.json"

# --- 4. no resolvable issue reference: says so, exits 0, no request -------
t_run run_sync X=1 -- start --mode-file "$MODE_PLAIN"
assert_eq "session with no issue reference exits 0" "0" "$T_RC"
assert_contains "and says why nothing was synced" "no Plane issue for this session" "$T_OUT"

# --- 5. unreachable Plane: warn naming INFRA-37, exit 0 -------------------
# Port 9 (discard) on loopback refuses the connection immediately.
t_run run_sync CC_PLANE_BASE=http://127.0.0.1:9/api/v1 -- resolve --issue TST-7
assert_eq "unreachable Plane exits 0 (the IPS-event contract)" "0" "$T_RC"
assert_contains "unreachable warn names the known cause" "INFRA-37" "$T_ERR"

# --- 6. the HTTP flows, against a loopback fake Plane ---------------------
cat > "$FIX/fake-plane.py" <<'PYEOF'
import json, datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

states = [
    {"id": "s1", "name": "Todo",        "group": "unstarted"},
    {"id": "s2", "name": "In Progress", "group": "started"},
    {"id": "s3", "name": "Done",        "group": "completed"},
    # The started group holds three distinct states, exactly like the live
    # INFRA project. Only "In Progress" asserts someone is working right now
    # (INFRA-73); the other two are deliberate resting states.
    {"id": "s4", "name": "In Review",   "group": "started"},
    {"id": "s5", "name": "Blocked",     "group": "started"},
]
_now = datetime.datetime.now(datetime.timezone.utc)
OLD = (_now - datetime.timedelta(days=30)).isoformat()
NEW = _now.isoformat()
issues = {
    "i1": {"id": "i1", "sequence_id": 7, "name": "Fixture seven", "state": "s1",
           "priority": "medium", "target_date": None},
    "i2": {"id": "i2", "sequence_id": 8, "name": "Fixture eight", "state": "s1",
           "priority": "none", "target_date": None},
    # health fixtures: one issue per started state, all quiet for 30 days,
    # plus a fresh In Review issue that a live slot claims (i6).
    "i3": {"id": "i3", "sequence_id": 9,  "name": "Quiet in-progress", "state": "s2",
           "priority": "none", "target_date": None, "updated_at": OLD},
    "i4": {"id": "i4", "sequence_id": 10, "name": "Parked in review",  "state": "s4",
           "priority": "none", "target_date": None, "updated_at": OLD},
    "i5": {"id": "i5", "sequence_id": 11, "name": "Waiting blocked",   "state": "s5",
           "priority": "none", "target_date": None, "updated_at": OLD},
    "i6": {"id": "i6", "sequence_id": 12, "name": "Live in review",    "state": "s4",
           "priority": "none", "target_date": None, "updated_at": NEW},
}
comments = {"i1": [], "i2": []}

def page(res):
    return {"results": res, "next_page_results": False,
            "next_cursor": None, "total_count": len(res)}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _authed(self):
        if self.headers.get("X-Api-Key"):
            return True
        self._send({"detail": "Authentication credentials were not provided."}, 401)
        return False

    def do_GET(self):
        if not self._authed():
            return
        p = self.path.split("?")[0]
        if p == "/api/v1/workspaces/homelab/projects/":
            self._send(page([{"id": "p1", "identifier": "TST", "name": "Test"}]))
        elif p == "/api/v1/workspaces/homelab/projects/p1/states/":
            self._send(page(states))
        elif p == "/api/v1/workspaces/homelab/projects/p1/issues/":
            self._send(page(list(issues.values())))
        elif p.endswith("/comments/"):
            iid = p.rstrip("/").split("/")[-2]
            self._send(page(comments.get(iid, [])))
        else:
            iid = p.rstrip("/").split("/")[-1]
            if iid in issues:
                self._send(issues[iid])
            else:
                self._send({"error": "The requested resource does not exist."}, 404)

    def do_PATCH(self):
        if not self._authed():
            return
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        iid = self.path.rstrip("/").split("/")[-1]
        if iid in issues:
            issues[iid].update(body)
            self._send(issues[iid])
        else:
            self._send({"error": "The requested resource does not exist."}, 404)

    def do_POST(self):
        if not self._authed():
            return
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        p = self.path.rstrip("/")
        if p.endswith("/comments"):
            iid = p.split("/")[-2]
            comments.setdefault(iid, []).append(body)
            self._send({"id": "c%d" % len(comments[iid])})
        else:
            self._send({"error": "The requested resource does not exist."}, 404)

srv = HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PYEOF

python3 "$FIX/fake-plane.py" > "$FIX/port" 2>/dev/null &
SERVER_PID=$!
trap '[ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null' EXIT

for _ in $(seq 1 50); do
    [ -s "$FIX/port" ] && break
    sleep 0.1
done
PORT=$(cat "$FIX/port" 2>/dev/null)

if [ -z "$PORT" ]; then
    t_fail "fake Plane server failed to start — HTTP cases cannot run"
    t_finish
    exit $?
fi
BASE="CC_PLANE_BASE=http://127.0.0.1:$PORT/api/v1"

# resolve: read-only, prints the machine-readable identity block.
t_run run_sync "$BASE" -- resolve --issue TST-7
assert_eq "resolve exits 0" "0" "$T_RC"
assert_contains "resolve maps the ref to project/issue ids" "resolved TST-7 -> TST/i1" "$T_OUT"
assert_contains "resolve emits plane_issue=" "plane_issue=TST-7" "$T_OUT"
assert_contains "resolve emits the state group" "plane_state_group=unstarted" "$T_OUT"

# start: PATCH into the started group, verified by re-fetch.
t_run run_sync "$BASE" -- start --issue TST-7
assert_eq "start exits 0" "0" "$T_RC"
assert_contains "start reports the verified transition" \
    "TST-7: Todo -> In Progress (verified by re-fetch)" "$T_OUT"

# start again: idempotent, no write.
t_run run_sync "$BASE" -- start --issue TST-7
assert_eq "second start exits 0" "0" "$T_RC"
assert_contains "second start declines to write" "no write needed" "$T_OUT"

# start --dry-run: reports the would-be PATCH and leaves the issue alone.
t_run run_sync "$BASE" -- start --dry-run --issue TST-8
assert_contains "dry-run start announces itself" "DRY RUN: would PATCH TST-8" "$T_OUT"
t_run run_sync "$BASE" -- resolve --issue TST-8
assert_contains "dry-run start wrote nothing (re-read confirms unstarted)" \
    "plane_state_group=unstarted" "$T_OUT"

# finish done: state -> completed plus one audit comment, both re-verified.
t_run run_sync "$BASE" -- finish done --note "closing note" --issue TST-7
assert_eq "finish done exits 0" "0" "$T_RC"
assert_contains "finish done lands on the completed state" "now Done (completed)" "$T_OUT"
assert_contains "finish done posts and counts the audit comment" "1 comment(s)" "$T_OUT"

# finish progress: comment only, state deliberately untouched.
t_run run_sync "$BASE" -- finish progress --note "still going" --issue TST-8
assert_eq "finish progress exits 0" "0" "$T_RC"
t_run run_sync "$BASE" -- resolve --issue TST-8
assert_contains "finish progress leaves the state group alone" \
    "plane_state_group=unstarted" "$T_OUT"

# --- 7. identity resolution precedence, observed through resolve ----------
t_run run_sync "$BASE" -- resolve --mode-file "$MODE_SLUGREF"
assert_contains "precedence 4: an issue-shaped slug resolves" "plane_issue=TST-8" "$T_OUT"

t_run run_sync "$BASE" -- resolve --mode-file "$MODE_TASKMD"
assert_contains "precedence 3: the task folder's plane.md resolves" "plane_issue=TST-7" "$T_OUT"

t_run run_sync "$BASE" -- resolve --mode-file "$MODE_PIN"
assert_contains "precedence 2: .cc-mode plane_issue= beats plane.md" "plane_issue=TST-8" "$T_OUT"

t_run run_sync "$BASE" -- resolve --issue TST-7 --mode-file "$MODE_PIN"
assert_contains "precedence 1: --issue beats everything" "plane_issue=TST-7" "$T_OUT"

# --- 8. lookup failures stay soft even with the server up -----------------
t_run run_sync "$BASE" -- resolve --issue TST-999
assert_eq "unknown issue exits 0" "0" "$T_RC"
assert_contains "unknown issue warns with the ref" "no issue TST-999" "$T_ERR"

t_run run_sync "$BASE" -- resolve --issue NOPE-1
assert_eq "unknown project exits 0" "0" "$T_RC"
assert_contains "unknown project warns with the identifier" "NOPE" "$T_ERR"

# --- 9. health: retired cycle check + started-state semantics -------------
# INFRA-72: cycle tracking is retired — health must not fetch cycles or print
# any cycle verdict. INFRA-73: only the state NAME "In Progress" asserts a
# live session; In Review and Blocked are deliberate resting states and must
# not be reported as zombie or stalled. The board-vs-fleet "behind" check
# stays at group level: a live session on an In Review issue is fine.
#
# Fixture board at this point: i1 Done, i2 unstarted (TST-8), i3 In Progress
# quiet 30d (TST-9), i4 In Review quiet 30d (TST-10), i5 Blocked quiet 30d
# (TST-11), i6 In Review fresh (TST-12).
SLOTS="$FIX/slots"
mkdir -p "$SLOTS"
printf -- '---\nsession_id: sess-live-12\ntask_id: TST-12\nstatus: running\n---\n' \
    > "$SLOTS/sess-live-12.md"

t_run run_sync "$BASE" -- health --mode-file "$MODE_PLAIN"
assert_eq "health exits 0" "0" "$T_RC"
assert_not_contains "health no longer warns NO ACTIVE CYCLE (INFRA-72)" \
    "NO ACTIVE CYCLE" "$T_OUT"
assert_not_contains "health prints no cycle verdict at all (check retired)" \
    "active cycle" "$T_OUT"
# The board line must not read OK above a finding it is printing. This
# fixture has TST-9 In Progress with no live session -- the run emits the
# zombie finding two assertions below, and before AI_ST-99 the line above it
# still said OK. A summary that contradicts its own detail is the false-clean
# pattern in feedback_a_check_that_cannot_fail_is_a_false_clean.
assert_contains "board line is WARN when a zombie is reported" \
    "TST board health: WARN" "$T_OUT"
assert_contains "a quiet In Progress issue with no live session is still a zombie" \
    "TST-9 is In Progress but no live session" "$T_OUT"
assert_not_contains "an In Review issue appears nowhere in health output (INFRA-73)" \
    "TST-10" "$T_OUT"
assert_not_contains "a Blocked issue appears nowhere in health output (INFRA-73)" \
    "TST-11" "$T_OUT"
assert_contains "the quiet leash counts only In Progress issues" \
    "1 stale-started" "$T_OUT"
assert_not_contains "an In Review issue with a live session is not behind" \
    "live session on TST-12" "$T_OUT"

# A live session on an issue that never started must still flag: the
# "behind" side of check 3 keeps the whole started group.
printf -- '---\nsession_id: sess-live-8\ntask_id: TST-8\nstatus: running\n---\n' \
    > "$SLOTS/sess-live-8.md"
t_run run_sync "$BASE" -- health --mode-file "$MODE_PLAIN"
assert_contains "a live session on an unstarted issue still flags as behind" \
    "live session on TST-8 but the issue is not in a started state" "$T_OUT"
assert_contains "board line is WARN when a session runs ahead of the board" \
    "TST board health: WARN" "$T_OUT"
rm -f "$SLOTS/sess-live-8.md" "$SLOTS/sess-live-12.md"

# --- health reads plane_issue, not just task_id (AI_ST-99) -----------------
# A slot whose task_id is a DESCRIPTIVE slug but which carries an explicit
# plane_issue must count as a live session on that issue. This is the case
# that was invisible before AI_ST-99: cmd_health substituted task_id, so a
# session linked by .cc-mode or by a task folder's plane.md contributed
# nothing to the fleet set, and the board silently reported less than it saw.
printf -- '---\nsession_id: sess-desc\ntask_id: some-descriptive-slug\nplane_issue: TST-12\nstatus: running\n---\n' \
    > "$SLOTS/sess-desc.md"
t_run run_sync "$BASE" -- health --mode-file "$MODE_PLAIN"
assert_contains "a descriptive-slug slot with plane_issue counts as live" \
    "1 live session(s)" "$T_OUT"
assert_not_contains "and its In Review issue is not a zombie" \
    "TST-12 is In Progress" "$T_OUT"

# plane_issue beats task_id when both are present and disagree.
printf -- '---\nsession_id: sess-both\ntask_id: TST-8\nplane_issue: TST-12\nstatus: running\n---\n' \
    > "$SLOTS/sess-both.md"
t_run run_sync "$BASE" -- health --mode-file "$MODE_PLAIN"
assert_not_contains "plane_issue wins over task_id" \
    "live session on TST-8" "$T_OUT"
rm -f "$SLOTS/sess-both.md"

# A slot with NO plane_issue still resolves by task_id: slots written before
# AI_ST-99 must keep counting, or the fix would blind the check it repairs.
#
# sess-old claims TST-9, NOT TST-12. The summary counts distinct ISSUES with
# a live session (len(proj_live)), so putting both slots on TST-12 would print
# "1 live session(s)" whether or not the task_id fallback fired -- a case that
# cannot fail is the very false clean this ticket is about. On TST-9 the count
# genuinely reaches 2, and TST-9 stops being reported as a zombie, which is
# true ONLY if the fallback resolved it.
printf -- '---\nsession_id: sess-old\ntask_id: TST-9\nstatus: running\n---\n' \
    > "$SLOTS/sess-old.md"
t_run run_sync "$BASE" -- health --mode-file "$MODE_PLAIN"
assert_contains "a pre-AI_ST-99 slot still counts via task_id" \
    "2 live session(s)" "$T_OUT"
assert_not_contains "...and the issue it claims is no longer a zombie" \
    "TST-9 is In Progress but no live session" "$T_OUT"
rm -f "$SLOTS/sess-old.md"

# --- the coverage line: name the blind spot (AI_ST-99) --------------------
# The reason this check reported a clean it had not measured was that nothing
# said how much of the fleet it could see. One live session linked and one
# not looks identical to two linked, unless the run says so.
printf -- '---\nsession_id: sess-unlinked\ntask_id: plane-system-of-record\nstatus: running\n---\n' \
    > "$SLOTS/sess-unlinked.md"
t_run run_sync "$BASE" -- health --mode-file "$MODE_PLAIN"
assert_contains "coverage names the running total" \
    "2 running slot(s)" "$T_OUT"
assert_contains "coverage names how many carry a reference" \
    "1 carrying a Plane reference" "$T_OUT"
assert_contains "coverage names the blind spot" \
    "1 unlinked" "$T_OUT"
rm -f "$SLOTS/sess-unlinked.md" "$SLOTS/sess-desc.md"

# --- adopt: writes both halves of the back-reference (AI_ST-99) ------------
# The mechanism has existed since the convention shipped and adoption stood at
# 1 task folder in 138. adopt is the missing verb: it writes the folder's
# plane.md AND back-fills .cc-mode, so the link survives both this session and
# the next one.
ADOPT_MODE="$FIX/adopt.cc-mode"
printf 'mode=branched\nslug=adopt-me\nstarted_at=x\nparent_repo=/r\nsession_id=cccccccccccccccccccccc\nparent_id=\nmodel=\nmodel_source=\nperm_mode=\nperm_mode_source=\nplane_issue=\n' \
    > "$ADOPT_MODE"
mkdir -p "$TASKS/adopt-me"

t_run run_sync "$BASE" -- adopt TST-12 --mode-file "$ADOPT_MODE"
assert_eq "adopt exits 0" "0" "$T_RC"
assert_contains "adopt names both files it wrote" "plane.md" "$T_OUT"
assert_contains "the folder back-reference is written" \
    "plane: TST-12" "$(cat "$TASKS/adopt-me/plane.md" 2>/dev/null)"
assert_contains "the folder back-reference carries a URL" \
    "plane_url:" "$(cat "$TASKS/adopt-me/plane.md" 2>/dev/null)"
assert_contains "the empty .cc-mode line is REPLACED, not duplicated" \
    "plane_issue=TST-12" "$(cat "$ADOPT_MODE")"
assert_eq "the .cc-mode still has exactly one plane_issue line" "1" \
    "$(grep -c '^plane_issue=' "$ADOPT_MODE")"
assert_eq "the .cc-mode is still 11 lines" "11" "$(wc -l < "$ADOPT_MODE")"

# Idempotent: running it again changes nothing and does not append.
t_run run_sync "$BASE" -- adopt TST-12 --mode-file "$ADOPT_MODE"
assert_eq "re-adopting the same reference exits 0" "0" "$T_RC"
assert_eq "re-adopting does not duplicate the line" "1" \
    "$(grep -c '^plane_issue=' "$ADOPT_MODE")"

# A reference the board does not hold must not be written anywhere. An
# unverified reference is how a bad link propagates into the tree and the
# health check that reads it.
t_run run_sync "$BASE" -- adopt TST-9999 --mode-file "$ADOPT_MODE"
assert_eq "adopting an unknown issue still exits 0 (fail-soft)" "0" "$T_RC"
assert_not_contains "an unknown issue is not written to .cc-mode" \
    "TST-9999" "$(cat "$ADOPT_MODE")"

# Usage: refused before any request, like every other usage error here.
t_run run_sync X=1 -- adopt
assert_eq "adopt without a reference refuses with exit 2" "2" "$T_RC"
t_run run_sync X=1 -- adopt not-an-issue
assert_eq "adopt with a malformed reference refuses with exit 2" "2" "$T_RC"

kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
SERVER_PID=""

t_finish
