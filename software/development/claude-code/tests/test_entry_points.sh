#!/usr/bin/env bash
# Description: Behavioral tests for the seven public cc-* entry points — refusal paths that must leave nothing behind, and full spawn flows against claude/tmux shims (INFRA-49; the half-spawn regression surface).
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, git, jq, coreutils, canonical/shell/cc-functions.sh

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
CC_FUNCTIONS_UNDER_TEST="${CC_FUNCTIONS_UNDER_TEST:-$MODULE_DIR/canonical/shell/cc-functions.sh}"
# shellcheck disable=SC1090
source "$CC_FUNCTIONS_UNDER_TEST"

t_begin "cc entry points: refusals leave nothing behind; spawns wire identity end to end"

# =========================================================================
# WHY THIS FILE EXISTS
#
# The seven public entry points (cc, cc-explore, cc-build, cc-continue,
# cc-branch, cc-teleport, cc-doctor) had zero tests while carrying the
# layer's worst historical failure mode: the SILENT HALF-SPAWN — worktree
# and tmux window created, but no .cc-mode, no session_id, no tree linkage
# (audit F3 item 1, INFRA-49). Two contracts are asserted here:
#
#   1. Every refusal fires BEFORE side effects. A refused launch must leave
#      no worktree, no branch, no .cc-mode.
#   2. A spawn wires identity end to end: the CC_SESSION_ID handed to
#      claude/tmux is the same id written to .cc-mode, and the sandbox and
#      model plumbing actually reach the launch command.
#
# claude and tmux are shims recording their argv; git is real. Everything
# lives under tmpdirs; the operator's HOME, repo and tmux server are never
# touched.
# =========================================================================

FIX=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
FAKEHOME="$FIX/home"
SHIMS="$FIX/shims"
TMUXSTATE="$FIX/tmux-state"
POLICY="$FIX/policy.json"
CLAUDE_LOG="$FIX/claude-args"
mkdir -p "$FAKEHOME" "$SHIMS" "$TMUXSTATE"

printf '{"policy_version":1,"roles":{"explore":{"model":"track-latest"},"build":{"model":"track-latest"},"branched-worker":{"model":"track-latest"},"ea":{"model":"track-latest"}}}\n' > "$POLICY"

cat > "$SHIMS/claude" <<'SHIM'
#!/bin/bash
{ printf 'CC_SESSION_ID=%s\n' "${CC_SESSION_ID:-}"; printf '%s\n' "$@"; } > "${CLAUDE_LOG:?}"
exit 0
SHIM
cat > "$SHIMS/tmux" <<'SHIM'
#!/bin/bash
state="${TMUX_STATE_DIR:?}"
cmd="${1:-}"; shift
case "$cmd" in
    has-session) [ -f "$state/session" ]; exit $? ;;
    new-session) touch "$state/session"; printf 'new-session %s\n' "$*" >> "$state/log" ;;
    list-windows) cat "$state/windows" 2>/dev/null ;;
    new-window)
        name=""
        args=("$@")
        for ((i = 0; i < ${#args[@]}; i++)); do
            [ "${args[$i]}" = "-n" ] && name="${args[$((i + 1))]}"
        done
        printf '%s\n' "$name" >> "$state/windows"
        printf 'new-window %s\n' "$*" >> "$state/log"
        ;;
    *) printf '%s %s\n' "$cmd" "$*" >> "$state/log" ;;
esac
exit 0
SHIM
chmod +x "$SHIMS/claude" "$SHIMS/tmux"

# set1 VAR=value <cmd...> — override one variable for a FUNCTION call. `env`
# cannot do this: it execs a binary and the cc-* wrappers are shell functions.
set1() { export "${1?}"; shift; "$@"; }

# with_env <dir> <cmd...> — cd and neutralise the ambient machine. Only ever
# called through t_run, whose command substitution is a subshell, so the
# exports and the cd cannot leak into this test process.
with_env() {
    local d="$1"; shift
    cd "$d" || return 99
    export HOME="$FAKEHOME" CC_MODEL_POLICY="$POLICY" PATH="$SHIMS:$PATH" \
           TMUX_STATE_DIR="$TMUXSTATE" CLAUDE_LOG="$CLAUDE_LOG"
    unset CC_MODEL CC_PERM_MODE CC_SESSION_ID CC_PARENT_ID TMUX
    "$@"
}

# A fixture repo with one commit, so worktree creation has a HEAD to build on.
REPO="$FIX/repo"
mkdir -p "$REPO/sub"
git -C "$REPO" init -q -b main
printf 'x\n' > "$REPO/f.txt"
git -C "$REPO" -c user.email=t@test -c user.name=t add -A
git -C "$REPO" -c user.email=t@test -c user.name=t commit -q -m fixture

PLAIN="$FIX/plain"
mkdir -p "$PLAIN"

# --- cc-explore: refusals -------------------------------------------------
t_run with_env "$REPO" cc-explore 'bad slug!'
assert_eq "cc-explore: hostile slug refused" "1" "$T_RC"
assert_contains "cc-explore: the slug rule is stated" "slug must match" "$T_ERR"

t_run with_env "$PLAIN" cc-explore okslug
assert_eq "cc-explore: outside a git repo refused" "1" "$T_RC"
assert_contains "cc-explore: names the problem" "not in a git repo" "$T_ERR"

t_run with_env "$REPO/sub" cc-explore okslug
assert_eq "cc-explore: below the repo root refused" "1" "$T_RC"
assert_contains "cc-explore: the root requirement is stated" "must be at repo root" "$T_ERR"

# Refusal before side effects: an unreadable model policy must abort the
# launch with NO worktree and NO branch left behind (the half-spawn contract).
t_run with_env "$REPO" set1 CC_MODEL_POLICY="$FIX/no-such-policy.json" cc-explore orphan
assert_eq "cc-explore: unresolvable model policy refused" "1" "$T_RC"
[ ! -d "$FIX/repo-explore-orphan" ] \
    && t_pass "cc-explore: refused launch creates no worktree" \
    || t_fail "cc-explore: refused launch creates no worktree"
git -C "$REPO" show-ref --verify --quiet refs/heads/explore/orphan \
    && t_fail "cc-explore: refused launch creates no branch" \
    || t_pass "cc-explore: refused launch creates no branch"

# --- cc-explore: the full spawn -------------------------------------------
t_run with_env "$REPO" cc-explore myslug
assert_eq "cc-explore: spawn exits 0" "0" "$T_RC"
WT="$FIX/repo-explore-myslug"
[ -d "$WT" ] && t_pass "cc-explore: worktree created" || t_fail "cc-explore: worktree created"
git -C "$REPO" show-ref --verify --quiet refs/heads/explore/myslug \
    && t_pass "cc-explore: branch explore/myslug created" \
    || t_fail "cc-explore: branch explore/myslug created"

mode_val()  { grep "^$2=" "$1/.cc-mode" 2>/dev/null | cut -d= -f2-; }
assert_eq "cc-explore: .cc-mode records exploration mode" "exploration" "$(mode_val "$WT" mode)"
assert_eq "cc-explore: .cc-mode records the slug" "myslug" "$(mode_val "$WT" slug)"
sid=$(mode_val "$WT" session_id)
assert_eq "cc-explore: session_id is 22 chars" "22" "${#sid}"
assert_eq "cc-explore: sandbox settings written into the worktree" \
    '{"sandbox":{"enabled":true,"failIfUnavailable":true}}' \
    "$(cat "$WT/.cc-sandbox-settings.json" 2>/dev/null)"

claude_seen=$(cat "$CLAUDE_LOG" 2>/dev/null)
# The wrapper passes the worktree path as it built it — relative to the repo
# root — so assert on the distinctive tail rather than an absolute prefix.
assert_contains "cc-explore: claude launched with the worktree's sandbox settings" \
    "repo-explore-myslug/.cc-sandbox-settings.json" "$claude_seen"
assert_contains "cc-explore: claude receives the SAME session id .cc-mode holds" \
    "CC_SESSION_ID=$sid" "$claude_seen"
assert_not_contains "cc-explore: track-latest passes no --model flag" \
    "--model" "$claude_seen"

t_run with_env "$REPO" cc-explore myslug
assert_eq "cc-explore: relaunch into an existing worktree exits 0" "0" "$T_RC"
assert_contains "cc-explore: relaunch says it is reusing, not recreating" "reusing" "$T_ERR"

# --- cc-build: plan gate and spawn ----------------------------------------
t_run with_env "$REPO" cc-build
assert_eq "cc-build: no plan or spec refused" "1" "$T_RC"
assert_contains "cc-build: the gate names the fix" "brainstorm first" "$T_ERR"

mkdir -p "$REPO/docs/superpowers/plans"
printf '# plan\n' > "$REPO/docs/superpowers/plans/p.md"
t_run with_env "$REPO" cc-build
assert_eq "cc-build: with a plan present, exits 0" "0" "$T_RC"
assert_eq "cc-build: .cc-mode records build mode" "build" "$(mode_val "$REPO" mode)"
bsid=$(mode_val "$REPO" session_id)
assert_contains "cc-build: claude receives the .cc-mode session id" \
    "CC_SESSION_ID=$bsid" "$(cat "$CLAUDE_LOG" 2>/dev/null)"

# --- cc-continue ----------------------------------------------------------
t_run with_env "$PLAIN" cc-continue
assert_eq "cc-continue: nothing to resume refused" "1" "$T_RC"
assert_contains "cc-continue: names the missing .cc-mode" "no .cc-mode found" "$T_ERR"

t_run with_env "$PLAIN" cc-continue "$FIX/no-such-worktree"
assert_eq "cc-continue: nonexistent worktree dir refused" "1" "$T_RC"

WEIRD="$FIX/weird"
mkdir -p "$WEIRD"
printf 'mode=confused\nslug=x\n' > "$WEIRD/.cc-mode"
t_run with_env "$WEIRD" cc-continue
assert_eq "cc-continue: unknown mode refused" "1" "$T_RC"
assert_contains "cc-continue: the unknown mode is named" "confused" "$T_ERR"

# The relaunch above minted a fresh id into $WT/.cc-mode; the resume must
# replay whatever the file holds NOW, so re-read it rather than reuse $sid.
sid=$(mode_val "$WT" session_id)
t_run with_env "$WT" cc-continue
assert_eq "cc-continue: exploration resume exits 0" "0" "$T_RC"
resumed=$(cat "$CLAUDE_LOG" 2>/dev/null)
assert_contains "cc-continue: resume passes --continue" "--continue" "$resumed"
assert_contains "cc-continue: resume re-locates the sandbox settings" \
    ".cc-sandbox-settings.json" "$resumed"
assert_contains "cc-continue: resume replays the ORIGINAL session id" \
    "CC_SESSION_ID=$sid" "$resumed"

# --- cc-branch: refusals --------------------------------------------------
t_run with_env "$REPO" cc-branch
assert_eq "cc-branch: no task id refused" "1" "$T_RC"
assert_contains "cc-branch: usage stated" "usage: cc-branch" "$T_ERR"

t_run with_env "$REPO" cc-branch 'bad task!'
assert_eq "cc-branch: hostile task id refused" "1" "$T_RC"

t_run with_env "$REPO" set1 PATH=/nonexistent cc-branch T-1
assert_eq "cc-branch: missing tmux refused" "1" "$T_RC"
assert_contains "cc-branch: tmux requirement stated" "tmux required" "$T_ERR"

t_run with_env "$FIX" cc-branch T-1 "$FIX/no-such-repo"
assert_eq "cc-branch: nonexistent repo path refused" "1" "$T_RC"

t_run with_env "$FIX" cc-branch T-1 "$PLAIN"
assert_eq "cc-branch: non-repo path refused" "1" "$T_RC"

# --- cc-branch: the full spawn --------------------------------------------
# The caller's own .cc-mode is the parent identity, so spawn from a dir
# carrying one (the fixture repo root has cc-build's from above; give it a
# recognisable id instead).
PARENT="$FIX/parent"
mkdir -p "$PARENT"
printf 'mode=command-center\nslug=cc\nsession_id=pppppppppppppppppppppp\n' > "$PARENT/.cc-mode"

t_run with_env "$PARENT" cc-branch TASK-1 "$REPO"
assert_eq "cc-branch: spawn exits 0" "0" "$T_RC"
BWT="$FIX/repo-branch-TASK-1"
[ -d "$BWT" ] && t_pass "cc-branch: per-task worktree created" \
              || t_fail "cc-branch: per-task worktree created"
git -C "$REPO" show-ref --verify --quiet refs/heads/branch/TASK-1 \
    && t_pass "cc-branch: branch branch/TASK-1 created" \
    || t_fail "cc-branch: branch branch/TASK-1 created"
assert_eq "cc-branch: child .cc-mode records branched mode" "branched" "$(mode_val "$BWT" mode)"
assert_eq "cc-branch: child .cc-mode records the parent id" \
    "pppppppppppppppppppppp" "$(mode_val "$BWT" parent_id)"
csid=$(mode_val "$BWT" session_id)
assert_ne "cc-branch: child id is freshly minted, not the parent's" \
    "pppppppppppppppppppppp" "$csid"

tmux_log=$(cat "$TMUXSTATE/log" 2>/dev/null)
assert_contains "cc-branch: tmux window carries the task name" "-n TASK-1" "$tmux_log"
assert_contains "cc-branch: tmux launch string carries the CHILD session id" \
    "CC_SESSION_ID=$csid claude" "$tmux_log"
assert_contains "cc-branch: tmux window opens in the child worktree" "-c $BWT" "$tmux_log"

t_run with_env "$PARENT" cc-branch TASK-1 "$REPO"
assert_eq "cc-branch: duplicate window name refused" "1" "$T_RC"
assert_contains "cc-branch: duplicate refusal names the window" "TASK-1" "$T_ERR"

# --- cc-teleport ----------------------------------------------------------
t_run with_env "$FIX" cc-teleport
assert_eq "cc-teleport: no target refused" "1" "$T_RC"

t_run with_env "$FIX" set1 TMUX_STATE_DIR="$FIX/tmux-none" cc-teleport TASK-1
assert_eq "cc-teleport: no company session refused" "1" "$T_RC"
assert_contains "cc-teleport: says how to start one" "launch with: cc" "$T_ERR"

t_run with_env "$FIX" cc-teleport NO-SUCH-WINDOW
assert_eq "cc-teleport: unknown window refused" "1" "$T_RC"
assert_contains "cc-teleport: names the missing window" "NO-SUCH-WINDOW" "$T_ERR"

# --- cc (command center): workspace gate ----------------------------------
t_run with_env "$FIX" cc
assert_eq "cc: missing command-center workspace refused" "1" "$T_RC"
assert_contains "cc: names the workspace path it wants" "_command-center" "$T_ERR"

# --- cc-doctor: delegation ------------------------------------------------
mkdir -p "$FAKEHOME/environment-foundation/software/development/claude-code/scripts"
printf '#!/bin/bash\necho "doctor-fixture-ran args=$*"\nexit 5\n' \
    > "$FAKEHOME/environment-foundation/software/development/claude-code/scripts/doctor.sh"
t_run with_env "$FIX" cc-doctor --some-flag
assert_eq "cc-doctor: exit status propagates from the script" "5" "$T_RC"
assert_contains "cc-doctor: delegates to the canonical checkout's doctor.sh with args" \
    "doctor-fixture-ran args=--some-flag" "$T_OUT"

t_finish
