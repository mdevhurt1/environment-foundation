#!/usr/bin/env bash
# cc-plane-sync — keep Plane honest from the session bookends.
#
# Plane is the status surface; the vault task folder is the substance. This
# helper is the mechanism that keeps the first half true, because it runs on
# the only code path that runs every session: the bookends.
#
#   session-start     Step 5a  `start`   — read, reconcile, one write
#   end-conversation  Step 2a  `resolve` then `finish` — closing state + comment
#   ring-maintenance  Step 2a  `health`  — three read-only staleness checks
#
# Design source: ~/vault/20-surface/company/tasks/plane-system-of-record/
# convention.md (2026-08-11), implemented as written. Section references below
# are to that document.
#
# FAIL SOFT, ALWAYS. Plane sits across the UDM from this workstation and its
# IPS drops inter-VLAN HTTP sessions under load (INFRA-37). A bookend that
# hard-fails on an HTTP 000 makes every session in the company unstartable
# during an IPS event. Every subcommand warns and exits 0 on any network,
# auth, or lookup failure. Non-zero exit is reserved for usage errors, which
# are caught before any request is made.
#
# NEVER GUESS A COUNT FROM A WRITE RESPONSE. The API rate-limits bursts with
# {"error_code":5900,...} -- a 2-key dict that silently reads as length 2 if
# parsed as a result set. Every write here re-fetches and reports the value
# the server actually holds. See
# ~/vault/20-surface/claude-memory/feedback_fresh_status_checks.md
#
# --- identity resolution (convention S2) ------------------------------------
#
# The issue reference for this session, highest precedence first:
#   1. --issue <REF>                 explicit, wins over everything
#   2. .cc-mode  plane_issue=REF     optional; written by a launcher that knew
#   3. <task folder>/plane.md  plane: REF    the vault->Plane back-reference
#   4. .cc-mode  slug=REF            when the slug is already issue-shaped
#
# (4) is the branch that fires today and did not exist when the convention was
# written. Branched sessions are launched as `cc-branch INFRA-41`, so slug and
# task_id are already the Plane issue ID -- the first branch of the CLAUDE.md
# "Task identity" contract, satisfied directly. The convention proposed a new
# .cc-mode plane_issue= field because in 2026-08 every task folder was
# slug-derived; that field remains supported by (2) for a slug-named task that
# acquires an issue later, but it is no longer required.
#
# A session with no resolvable reference is not an error. Short ad-hoc work
# legitimately has no Plane issue; the helper says so and exits 0.

set -euo pipefail

VAULT="$HOME/vault/20-surface/company"
# Both directory roots are overridable so the identity chain and the fleet
# side of `health` can be exercised against fixtures. Never point either at
# the live vault in a test.
TASKS_DIR="${CC_PLANE_TASKS_DIR:-$VAULT/tasks}"
# Overridable so `health`'s fleet side can be exercised against a fixture tree
# instead of the live one. Never point this at the live tree in a test.
SLOTS_DIR="${CC_PLANE_SLOTS_DIR:-$VAULT/tree/sessions}"
# Overridable for the same reason as the two directories above: the tests
# point it at a loopback fake so the HTTP layer can be exercised without a
# live Plane. Never point it at the real instance from a test.
PLANE_BASE="${CC_PLANE_BASE:-http://plane.homelab/api/v1}"
WORKSPACE="${CC_PLANE_WORKSPACE:-homelab}"

# Staleness thresholds (convention S4). Environment-overridable for a one-off
# pass; leave unset for the normal run.
STARTED_QUIET_DAYS="${STARTED_QUIET_DAYS:-7}"
BACKLOG_QUIET_DAYS="${BACKLOG_QUIET_DAYS:-21}"

usage() {
    cat <<'USAGE'
usage: cc-plane-sync.sh <subcommand> [options]

Subcommands:
  resolve                 Print the resolved identity and the issue's current
                          line. Reads only; makes no writes at all.
  start                   session-start's write. If the issue sits in a
                          `backlog` or `unstarted` state group, PATCH it into
                          the project's `started` state. Nothing else: no
                          creation, no priority change, no close. Idempotent.
  finish <disposition>    end-conversation's write. Disposition is one of
                          done | blocked | progress. PATCHes the state (for
                          `progress`, leaves it alone) and posts one audit
                          comment. Requires --note.
  health [--workspace W]  The three read-only staleness checks. Never mutates
                          anything. Prints one board-health line per project
                          plus the findings.

Options:
  --issue <REF>           Force the issue reference (e.g. INFRA-41), skipping
                          identity resolution.
  --note <TEXT>           Audit line for `finish`. Required for that command.
  --mode-file <path>      Read identity from this .cc-mode rather than walking
                          up from the current working directory.
  --session-id <id>       Assert this session's id; a mismatch against the
                          resolved .cc-mode is refused before any write.
  --workspace <slug>      Plane workspace slug (default: homelab).
  --dry-run               Resolve and report what would be written; write
                          nothing. Applies to `start` and `finish`.
  -h, --help              Show this help.

Exit status is 0 for every network, auth, or lookup failure -- these warn and
continue by design. Non-zero means a usage error, refused before any request.
USAGE
}

warn() { printf 'plane-sync: WARN %s\n' "$*" >&2; }
say()  { printf 'plane-sync: %s\n' "$*"; }

# ---- argument parsing (before any network work) ----------------------------

SUBCMD="${1:-}"
[ -n "$SUBCMD" ] || { usage >&2; exit 2; }
case "$SUBCMD" in
    -h|--help) usage; exit 0 ;;
    resolve|start|finish|health) shift ;;
    *) printf 'plane-sync: unknown subcommand: %s\n\n' "$SUBCMD" >&2; usage >&2; exit 2 ;;
esac

DISPOSITION=""
if [ "$SUBCMD" = finish ]; then
    DISPOSITION="${1:-}"
    case "$DISPOSITION" in
        done|blocked|progress) shift ;;
        "") printf 'plane-sync: finish requires a disposition (done|blocked|progress)\n' >&2; exit 2 ;;
        *)  printf 'plane-sync: invalid disposition: %s\n' "$DISPOSITION" >&2; exit 2 ;;
    esac
fi

ISSUE_REF=""; NOTE=""; MODE_FILE=""; ASSERT_SESSION=""; DRY_RUN=0

# An option whose value is missing must say so, not die on `shift 2` under
# `set -e` with an empty message.
need_val() {  # need_val <flag> <value...>
    [ $# -ge 2 ] && [ -n "$2" ] && return 0
    printf 'plane-sync: %s requires a value\n' "$1" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --issue)      need_val "$@"; ISSUE_REF="$2"; shift 2 ;;
        --note)       need_val "$@"; NOTE="$2"; shift 2 ;;
        --mode-file)  need_val "$@"; MODE_FILE="$2"; shift 2 ;;
        --session-id) need_val "$@"; ASSERT_SESSION="$2"; shift 2 ;;
        --workspace)  need_val "$@"; WORKSPACE="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) printf 'plane-sync: unexpected argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ "$SUBCMD" = finish ] && [ -z "$NOTE" ]; then
    printf 'plane-sync: finish requires --note (the audit line is the point)\n' >&2
    exit 2
fi

# ---- identity resolution (no network) --------------------------------------

find_mode_file() {
    [ -n "$MODE_FILE" ] && { printf '%s\n' "$MODE_FILE"; return; }
    local dir; dir=$(pwd)
    while [ "$dir" != / ]; do
        [ -f "$dir/.cc-mode" ] && { printf '%s\n' "$dir/.cc-mode"; return; }
        dir=$(dirname "$dir")
    done
}

# No grep|head|cut here: this file sets pipefail, and an early-exit consumer
# on the right of a pipe SIGPIPE-aborts once the producer outgrows a read
# block (doctor.sh check 9). awk reads the file directly and stops itself.
mode_get() {  # mode_get <key> <file>
    [ -f "$2" ] || return 0
    awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$2"
}

is_issue_ref() {  # PROJECTKEY-123
    [[ "$1" =~ ^[A-Z][A-Z0-9_]*-[0-9]+$ ]]
}

MODEF=$(find_mode_file || true)
SESSION_ID=""; SLUG=""
if [ -n "$MODEF" ]; then
    SESSION_ID=$(mode_get session_id "$MODEF")
    SLUG=$(mode_get slug "$MODEF")
fi

# Refuse a session-id mismatch before writing anything. A helper that resolves
# .cc-mode from cwd writes another lane's data the moment the caller has cd'd.
if [ -n "$ASSERT_SESSION" ] && [ -n "$SESSION_ID" ] && [ "$ASSERT_SESSION" != "$SESSION_ID" ]; then
    printf 'plane-sync: refusing — asserted session %s but %s says %s\n' \
        "$ASSERT_SESSION" "$MODEF" "$SESSION_ID" >&2
    exit 2
fi

if [ -z "$ISSUE_REF" ] && [ -n "$MODEF" ]; then
    ISSUE_REF=$(mode_get plane_issue "$MODEF")          # precedence 2
fi
if [ -z "$ISSUE_REF" ] && [ -n "$SLUG" ] && [ -f "$TASKS_DIR/$SLUG/plane.md" ]; then
    ISSUE_REF=$(awk '/^plane:/ { sub(/^plane:[[:space:]]*/, ""); print; exit }' \
                    "$TASKS_DIR/$SLUG/plane.md" 2>/dev/null || true)   # precedence 3
fi
if [ -z "$ISSUE_REF" ] && [ -n "$SLUG" ] && is_issue_ref "$SLUG"; then
    ISSUE_REF="$SLUG"                                    # precedence 4
fi

# ---- the API layer ---------------------------------------------------------
# All HTTP lives in one python3 block: JSON in bash is a bug farm, and python3
# is already a hard dependency (the API key can only be read from JSON).

run_api() {
    CC_PS_SUBCMD="$SUBCMD" \
    CC_PS_ISSUE_REF="$ISSUE_REF" \
    CC_PS_DISPOSITION="$DISPOSITION" \
    CC_PS_NOTE="$NOTE" \
    CC_PS_WORKSPACE="$WORKSPACE" \
    CC_PS_BASE="$PLANE_BASE" \
    CC_PS_DRY_RUN="$DRY_RUN" \
    CC_PS_SLOTS_DIR="$SLOTS_DIR" \
    CC_PS_STARTED_QUIET="$STARTED_QUIET_DAYS" \
    CC_PS_BACKLOG_QUIET="$BACKLOG_QUIET_DAYS" \
    no_proxy="" NO_PROXY="" python3 - <<'PYEOF'
import json, os, sys, urllib.request, urllib.error, datetime, time

SUB       = os.environ["CC_PS_SUBCMD"]
REF       = os.environ.get("CC_PS_ISSUE_REF", "")
DISP      = os.environ.get("CC_PS_DISPOSITION", "")
NOTE      = os.environ.get("CC_PS_NOTE", "")
WS        = os.environ["CC_PS_WORKSPACE"]
BASE      = os.environ["CC_PS_BASE"]
DRY       = os.environ.get("CC_PS_DRY_RUN") == "1"
SLOTS     = os.environ["CC_PS_SLOTS_DIR"]
STARTED_QUIET = int(os.environ.get("CC_PS_STARTED_QUIET", "7"))
BACKLOG_QUIET = int(os.environ.get("CC_PS_BACKLOG_QUIET", "21"))

def warn(m): print("plane-sync: WARN %s" % m, file=sys.stderr)
def say(m):  print("plane-sync: %s" % m)

# --- auth: the key is NOT an environment variable; it lives in settings JSON.
try:
    _s = json.load(open(os.path.expanduser("~/.claude/settings.local.json")))
    KEY = _s["env"]["PLANE_API_KEY"]
except Exception as e:
    warn("no Plane API key (%s: %s) — skipping Plane sync, continuing"
         % (type(e).__name__, e))
    sys.exit(0)
if not KEY:
    warn("Plane API key is empty — skipping Plane sync, continuing")
    sys.exit(0)

class SoftFail(Exception):
    """Any condition that must warn-and-continue rather than break a bookend."""

def api(method, path, body=None, _retry=True):
    url = BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("X-Api-Key", KEY)
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = {"raw": raw[:200].decode("utf-8", "replace")}
        # Rate limit: a 2-key dict. Back off once, then give up softly.
        if parsed.get("error_code") == 5900 and _retry:
            warn("rate limited (5900) — backing off 15s and retrying once")
            time.sleep(15)
            return api(method, path, body, _retry=False)
        raise SoftFail("HTTP %s on %s %s: %s" % (e.code, method, path, parsed))
    except Exception as e:
        # Connection refused / timeout / DNS. Almost always the UDM IPS
        # dropping the inter-VLAN session, not a Plane outage (INFRA-37).
        raise SoftFail("%s on %s %s (Plane unreachable — UDM IPS drops "
                       "inter-VLAN sessions; INFRA-37)" % (type(e).__name__, method, path))

def paged(path):
    """Iterate a list endpoint's results across cursor pages."""
    sep = "&" if "?" in path else "?"
    cursor, out = None, []
    while True:
        p = path + (sep + "cursor=" + cursor if cursor else "")
        d = api("GET", p)
        out.extend(d.get("results", []))
        if not d.get("next_page_results"):
            return out
        cursor = d.get("next_cursor")
        if not cursor:
            return out

def projects():
    return paged("/workspaces/%s/projects/" % WS)

def find_project(identifier):
    for p in projects():
        if p.get("identifier") == identifier:
            return p
    raise SoftFail("no project with identifier %r in workspace %s" % (identifier, WS))

def states(pid):
    return paged("/workspaces/%s/projects/%s/states/" % (WS, pid))

def state_map(pid):
    return {s["id"]: s for s in states(pid)}

def state_in_group(pid, group):
    """First state in a group. Plane projects can carry several per group
    (INFRA has three `started` states: In Progress, In Review, Blocked), so
    prefer an exact name when one is asked for."""
    return [s for s in states(pid) if s.get("group") == group]

def pick_state(pid, group, prefer=None):
    cands = state_in_group(pid, group)
    if not cands:
        raise SoftFail("project has no state in group %r" % group)
    if prefer:
        for s in cands:
            if s["name"].lower() == prefer.lower():
                return s
    return cands[0]

def split_ref(ref):
    key, _, num = ref.rpartition("-")
    if not key or not num.isdigit():
        raise SoftFail("issue reference %r is not PROJECT-123 shaped" % ref)
    return key, int(num)

def find_issue(ref):
    key, seq = split_ref(ref)
    proj = find_project(key)
    for i in paged("/workspaces/%s/projects/%s/issues/?per_page=100" % (WS, proj["id"])):
        if i.get("sequence_id") == seq:
            return proj, i
    raise SoftFail("no issue %s in project %s" % (ref, key))

def refetch(pid, iid):
    """Re-read an issue from the server. Never trust a write response for
    state -- a rate-limit body parses as a plausible-looking dict."""
    return api("GET", "/workspaces/%s/projects/%s/issues/%s/" % (WS, pid, iid))

def issue_line(ref, proj, issue, smap):
    st = smap.get(issue.get("state"), {})
    return "%s — %s | %s (%s) | priority %s | target %s" % (
        ref, issue.get("name", "?"), st.get("name", "?"), st.get("group", "?"),
        issue.get("priority", "?"), issue.get("target_date") or "none")

def days_since(ts):
    if not ts:
        return None
    try:
        d = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None
    now = datetime.datetime.now(datetime.timezone.utc)
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    return (now - d).days

# ---------------------------------------------------------------- subcommands

def need_ref():
    if not REF:
        say("no Plane issue for this session (no plane_issue=, no plane.md, "
            "slug is not issue-shaped) — nothing to sync, continuing")
        sys.exit(0)

def cmd_resolve():
    need_ref()
    proj, issue = find_issue(REF)
    smap = state_map(proj["id"])
    say("resolved %s -> %s/%s" % (REF, proj["identifier"], issue["id"]))
    say(issue_line(REF, proj, issue, smap))
    print("plane_issue=%s" % REF)
    print("plane_project_id=%s" % proj["id"])
    print("plane_issue_id=%s" % issue["id"])
    print("plane_state_group=%s" % smap.get(issue.get("state"), {}).get("group", "?"))

def cmd_start():
    need_ref()
    proj, issue = find_issue(REF)
    smap = state_map(proj["id"])
    cur = smap.get(issue.get("state"), {})
    say(issue_line(REF, proj, issue, smap))
    if cur.get("group") not in ("backlog", "unstarted"):
        say("already in a %s state (%s) — no write needed"
            % (cur.get("group"), cur.get("name")))
        return
    target = pick_state(proj["id"], "started", prefer="In Progress")
    if DRY:
        say("DRY RUN: would PATCH %s: %s -> %s" % (REF, cur.get("name"), target["name"]))
        return
    api("PATCH", "/workspaces/%s/projects/%s/issues/%s/" % (WS, proj["id"], issue["id"]),
        {"state": target["id"]})
    # Re-fetch. The write response is not evidence.
    fresh = refetch(proj["id"], issue["id"])
    now = smap.get(fresh.get("state"), {})
    if now.get("group") == "started":
        say("%s: %s -> %s (verified by re-fetch)" % (REF, cur.get("name"), now.get("name")))
    else:
        warn("%s: PATCH did not take — server still reports %s"
             % (REF, now.get("name", "?")))

def cmd_finish():
    need_ref()
    proj, issue = find_issue(REF)
    smap = state_map(proj["id"])
    cur = smap.get(issue.get("state"), {})
    say(issue_line(REF, proj, issue, smap))

    target = None
    if DISP == "done":
        target = pick_state(proj["id"], "completed", prefer="Done")
    elif DISP == "blocked":
        target = pick_state(proj["id"], "started", prefer="Blocked")
    # `progress` leaves the state alone by design.

    if DRY:
        say("DRY RUN: would set %s and comment: %s"
            % (target["name"] if target else "(state unchanged)", NOTE))
        return

    if target and target["id"] != issue.get("state"):
        api("PATCH", "/workspaces/%s/projects/%s/issues/%s/" % (WS, proj["id"], issue["id"]),
            {"state": target["id"]})

    # The audit comment is the half that makes a stale issue diagnosable later.
    # Post it even when the state did not move.
    try:
        api("POST", "/workspaces/%s/projects/%s/issues/%s/comments/"
            % (WS, proj["id"], issue["id"]),
            {"comment_html": "<p>%s</p>" % NOTE.replace("&", "&amp;")
                                               .replace("<", "&lt;")
                                               .replace(">", "&gt;")})
    except SoftFail as e:
        warn("state written but comment failed: %s" % e)

    fresh = refetch(proj["id"], issue["id"])
    now = smap.get(fresh.get("state"), {})
    ncomments = len(paged("/workspaces/%s/projects/%s/issues/%s/comments/"
                          % (WS, proj["id"], issue["id"])))
    say("%s: now %s (%s), %d comment(s) — verified by re-fetch"
        % (REF, now.get("name", "?"), now.get("group", "?"), ncomments))

def cmd_health():
    """Three read-only checks (convention S4). Mutates nothing, ever."""
    # Fleet side: what the tree says is live, from task_id on running slots.
    live = {}
    try:
        for fn in sorted(os.listdir(SLOTS)):
            if not fn.endswith(".md"):
                continue
            fm, path = {}, os.path.join(SLOTS, fn)
            try:
                with open(path) as fh:
                    for line in fh:
                        line = line.rstrip("\n")
                        if line == "---" and fm:
                            break
                        if ":" in line:
                            k, _, v = line.partition(":")
                            fm[k.strip()] = v.strip()
            except OSError:
                continue
            tid = fm.get("task_id", "")
            if fm.get("status") == "running" and tid:
                key, _, num = tid.rpartition("-")
                if key and num.isdigit():
                    live.setdefault(tid, []).append(fm.get("session_id", fn))
    except OSError as e:
        warn("cannot read tree slots (%s) — check 3 skipped" % e)

    findings = []
    for proj in projects():
        pid, ident = proj["id"], proj.get("identifier", "?")
        try:
            smap = state_map(pid)
            issues = paged("/workspaces/%s/projects/%s/issues/?per_page=100" % (WS, pid))
        except SoftFail as e:
            warn("%s: %s" % (ident, e))
            continue

        # Check 1 — no active cycle.
        try:
            cycles = paged("/workspaces/%s/projects/%s/cycles/" % (WS, pid))
        except SoftFail:
            cycles = []
        today = datetime.date.today().isoformat()
        active = [c for c in cycles
                  if (c.get("start_date") or "9999") <= today <= (c.get("end_date") or "0000")]

        started, stale_started, stale_backlog = [], [], []
        for i in issues:
            g = smap.get(i.get("state"), {}).get("group")
            if g == "started":
                started.append(i)
                d = days_since(i.get("updated_at"))
                if d is not None and d > STARTED_QUIET:
                    stale_started.append((i, d))
            elif g in ("backlog", "unstarted"):
                d = days_since(i.get("updated_at"))
                if d is not None and d > BACKLOG_QUIET:
                    stale_backlog.append((i, d))

        # Check 3 — the board disagrees with the fleet, both directions.
        started_refs = {"%s-%s" % (ident, i.get("sequence_id")) for i in started}
        proj_live = {r for r in live if r.rsplit("-", 1)[0] == ident}
        behind = proj_live - started_refs      # live session, issue not started
        zombie = started_refs - proj_live       # started issue, no live session

        flag = "OK " if (active and not behind) else "WARN"
        say("%s board health: %s %s | %d started | %d live session(s) | "
            "%d stale-started | %d stale-backlog"
            % (ident, flag,
               "active cycle" if active else "NO ACTIVE CYCLE",
               len(started), len(proj_live), len(stale_started), len(stale_backlog)))
        for r in sorted(behind):
            findings.append("%s: live session on %s but the issue is not in a started state"
                            % (ident, r))
        for r in sorted(zombie):
            findings.append("%s: %s is started but no live session claims it "
                            "(a session died without its bookend)" % (ident, r))
        for i, d in sorted(stale_started, key=lambda t: -t[1])[:5]:
            findings.append("%s: %s-%s started but quiet %d days — %s"
                            % (ident, ident, i.get("sequence_id"), d, i.get("name", "?")[:60]))

    if findings:
        print()
        say("findings (report-only — this subcommand never mutates anything):")
        for f in findings:
            print("  - %s" % f)
    else:
        print()
        say("no findings")

try:
    {"resolve": cmd_resolve, "start": cmd_start,
     "finish": cmd_finish, "health": cmd_health}[SUB]()
except SoftFail as e:
    warn("%s — continuing; the bookend is not blocked on Plane" % e)
    sys.exit(0)
PYEOF
}

run_api
exit 0
