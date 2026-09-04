#!/usr/bin/env bash
# Description: Tests for scripts/doctor.sh's Session tree presence check (INFRA-68) — every open company tmux window must map to a live slot, and a running slot whose window is long gone is reported back the other way.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, coreutils, scripts/doctor.sh

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

DOCTOR_UNDER_TEST="${DOCTOR_UNDER_TEST:-$MODULE_DIR/scripts/doctor.sh}"

t_begin "doctor.sh: every open company window maps to a live tree slot"

# =========================================================================
# WHY THIS FILE EXISTS (INFRA-68)
#
# On 2026-09-04 session aabd7e4c460747558046f2 ran a full lifecycle from an
# open tmux window with NO slot file and NO spawned event. Every downstream
# consumer keys off the slot, so the company-status scan and the reclaim gate
# both looked straight through it: the window was visibly there, and the tree
# said nothing existed. Nothing on the box could answer "is that window a
# session I know about?" -- so nothing noticed for four hours.
#
# The slot write itself is model-executed (session-start Step 3). No amount of
# hardening inside cc-tree-slot-write.sh can catch the case where the script is
# never invoked, which is precisely what happened. This check is the detector
# for that class: it compares two independent sources of truth -- the tmux
# window list and the tree -- and reports where they disagree.
#
# Severity is deliberately split, per the INFRA-47 lesson that a check which
# cries wolf becomes a check nobody reads:
#   * window with NO slot            -> FAIL. This is the incident. A live
#                                       session invisible to the whole tree.
#   * window whose slot is terminal  -> WARN. Normal and frequent: a finished
#                                       child waiting for the EA to reclaim it.
#                                       Actionable, not alarming.
#   * running slot, window long gone -> WARN. Hygiene in the other direction;
#                                       bounded by a threshold so a session
#                                       that is merely between windows is not
#                                       flagged the second it blinks.
#
# tmux is stubbed on PATH rather than injected through a doctor-only variable:
# the production code path calls plain `tmux`, so what the test exercises is
# what actually runs.
# =========================================================================

WORK=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
MAIN="$WORK/repo"
FAKEHOME="$WORK/home"
SESSIONS="$FAKEHOME/vault/20-surface/company/tree/sessions"
mkdir -p "$SESSIONS" "$MAIN/shared" "$MAIN/software/development/claude-code/scripts" \
         "$MAIN/software/development/claude-code/canonical/shell"
cp "$REPO_ROOT/shared/logging.sh" "$MAIN/shared/logging.sh"
cp "$DOCTOR_UNDER_TEST" "$MAIN/software/development/claude-code/scripts/doctor.sh"
git -C "$MAIN" init -q -b main 2>/dev/null || true

# --- a tmux stub driven by a fixture file --------------------------------
STUBDIR="$WORK/stub"; mkdir -p "$STUBDIR"
WINDOWS="$WORK/windows.tsv"          # lines: <window_name>\t<pane_current_path>
cat > "$STUBDIR/tmux" <<EOF
#!/usr/bin/env bash
# Minimal tmux double: has-session succeeds when the fixture exists, and
# list-windows replays it in the -F order doctor asks for.
case "\$1" in
    has-session) [ -s "$WINDOWS" ] ;;
    list-windows)
        [ -s "$WINDOWS" ] || exit 1
        cat "$WINDOWS" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$STUBDIR/tmux"

# A worktree with a valid .cc-mode naming a given session id.
mk_worktree() {
    local wt="$1" sid="$2" slug="$3"
    mkdir -p "$wt"
    cat > "$wt/.cc-mode" <<EOF
mode=branched
slug=$slug
started_at=2026-09-04T13:00:00-04:00
parent_repo=/nonexistent/parent-repo
session_id=$sid
parent_id=
model=opus
model_source=env
EOF
}

mk_slot() {
    local sid="$1" status="$2" slug="$3"
    cat > "$SESSIONS/$sid.md" <<EOF
---
session_id: $sid
parent_id:
task_id: $slug
slug: $slug
mode: branched
status: $status
started_at: 2026-09-04T13:00:00-04:00
ended_at:
---
EOF
}

presence_section() {
    HOME="$FAKEHOME" PATH="$STUBDIR:$PATH" \
        bash "$MAIN/software/development/claude-code/scripts/doctor.sh" 2>/dev/null \
        | sed -e 's/\x1b\[[0-9;]*m//g' \
        | awk '/^== Session tree presence ==$/{f=1; next} /^== /{f=0} f'
}

# --- 1. the incident shape: an open window with no slot at all -----------
mk_worktree "$WORK/litellm-branch-litellm-pr-feedback" "aabd7e4c460747558046f2" "litellm-pr-feedback"
printf 'litellm-pr-feedback\t%s\n' "$WORK/litellm-branch-litellm-pr-feedback" > "$WINDOWS"
out=$(presence_section)
assert_contains "a window with no slot draws a FAIL" "[FAIL]" "$out"
assert_contains "the FAIL names the window" "litellm-pr-feedback" "$out"
assert_contains "the FAIL names the worktree" \
    "$WORK/litellm-branch-litellm-pr-feedback" "$out"
assert_contains "the FAIL names the session id that has no slot" \
    "aabd7e4c460747558046f2" "$out"

# --- 2. the healthy shape: window maps to a running slot -----------------
mk_slot "aabd7e4c460747558046f2" "running" "litellm-pr-feedback"
out=$(presence_section)
assert_contains "a window backed by a running slot is OK" "[OK]" "$out"
assert_not_contains "and draws no FAIL" "[FAIL]" "$out"

# --- 3. the 'cc' window is exempt ----------------------------------------
# The command-center window is the EA itself; it is not a dispatched child and
# its pane sits in the vault, not a worktree. Flagging it would put a
# permanent red on every healthy box.
mk_worktree "$WORK/command-center" "dddddddddddddddddddddd" "cc"
mk_slot "dddddddddddddddddddddd" "running" "cc"
touch -d "6 hours ago" "$SESSIONS/dddddddddddddddddddddd.md"
printf 'cc\t%s\n' "$WORK/command-center" > "$WINDOWS"
out=$(presence_section)
assert_not_contains "the cc window is never flagged" "[FAIL]" "$out"
# ...but it must still REGISTER as holding a window. Skipping the whole
# iteration reported the EA's own long-running slot as windowless on every
# healthy box -- a permanent false WARN in the check meant to catch real ones.
assert_not_contains "the cc session still counts as holding its window" \
    "dddddddddddddddddddddd" "$out"
rm -f "$SESSIONS/dddddddddddddddddddddd.md"

# --- 4. a finished child still holding its window is a WARN, not a FAIL ---
mk_slot "aabd7e4c460747558046f2" "completed" "litellm-pr-feedback"
printf 'litellm-pr-feedback\t%s\n' "$WORK/litellm-branch-litellm-pr-feedback" > "$WINDOWS"
out=$(presence_section)
assert_contains "a completed slot with a live window warns" "[WARN]" "$out"
assert_not_contains "but does not fail — this is the normal reclaim queue" "[FAIL]" "$out"

# --- 5. a window whose worktree has no .cc-mode at all -------------------
# cc-branch half-running leaves exactly this: a window and a worktree, no
# identity. Named in doctor.sh's own shell-snapshot section as a known shape.
mkdir -p "$WORK/orphan-worktree"
printf 'ghost\t%s\n' "$WORK/orphan-worktree" > "$WINDOWS"
out=$(presence_section)
assert_contains "a window with no .cc-mode draws a FAIL" "[FAIL]" "$out"
assert_contains "and names the window" "ghost" "$out"

# --- 6. reverse direction: a running slot whose window is long gone ------
# Threshold-bounded so a session between windows is not flagged instantly.
rm -f "$SESSIONS"/*.md
mk_slot "9999999999999999999999" "running" "long-gone"
touch -d "6 hours ago" "$SESSIONS/9999999999999999999999.md"
mk_worktree "$WORK/wt-live" "8888888888888888888888" "live-one"
mk_slot "8888888888888888888888" "running" "live-one"
printf 'live-one\t%s\n' "$WORK/wt-live" > "$WINDOWS"
out=$(presence_section)
assert_contains "a running slot with no window, past the threshold, warns" \
    "9999999999999999999999" "$out"
assert_contains "the stale-slot line is a WARN" "[WARN]" "$out"
assert_not_contains "the slot that still has its window is not flagged" \
    "8888888888888888888888" "$out"

# --- 7. a freshly-started running slot with no window yet is NOT flagged --
# A child writes its slot seconds before/after its window settles. Flagging
# that race would fire on every single spawn.
rm -f "$SESSIONS/9999999999999999999999.md"
mk_slot "7777777777777777777777" "running" "just-born"
out=$(presence_section)
assert_not_contains "a slot younger than the threshold is left alone" \
    "7777777777777777777777" "$out"

# --- 8. no tmux server at all: the check degrades, it does not fail ------
# doctor runs on boxes with no company session (fresh installs, CI).
: > "$WINDOWS"
out=$(presence_section)
assert_not_contains "no company tmux session is not a FAIL" "[FAIL]" "$out"

t_finish
