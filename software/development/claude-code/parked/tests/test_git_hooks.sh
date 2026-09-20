#!/usr/bin/env bash
# Description: Behavioral tests for the cc-scrub git hooks (INFRA-59) — configure.sh installs pre-commit/pre-push as symlinks into canonical/hooks/, idempotently and without clobbering an operator's own hooks, and each hook blocks a seeded disclosure while passing a clean change.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, git, jq, grep with -P (PCRE), file, coreutils

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
CONFIGURE_UNDER_TEST="${CONFIGURE_UNDER_TEST:-$MODULE_DIR/scripts/configure.sh}"
PRECOMMIT_UNDER_TEST="${PRECOMMIT_UNDER_TEST:-$MODULE_DIR/canonical/hooks/pre-commit.sh}"
PREPUSH_UNDER_TEST="${PREPUSH_UNDER_TEST:-$MODULE_DIR/canonical/hooks/pre-push.sh}"

t_begin "cc-scrub git hooks: install, idempotency, and the gate biting on a seeded disclosure"

# =========================================================================
# WHY THIS FILE EXISTS (INFRA-59)
#
# cc-scrub shipped under RESEARCH-1 with a measured pre-commit budget and
# was then bound to nothing. A scrubber the operator has to REMEMBER to run
# is a scrubber that runs on the days it is not needed and gets skipped on
# the day it is -- the incident that produced the tool (a live LAN address
# in a commit bound for a PUBLIC remote) happened during a session that was
# being careful. Mechanical beats disciplined.
#
# The two failure modes this file exists to refuse, in order of severity:
#
#   1. THE GATE THAT IS NOT THERE. configure.sh reports success, the
#      operator believes the repo is guarded, and no hook was installed --
#      or one was installed pointing at a scrubber that does not exist and
#      it fails OPEN. A gate that fails open is worse than no gate, because
#      it converts "unguarded" into "verified guarded". Every install
#      assertion below is paired with a behavioural one: the file exists AND
#      a seeded violation is actually refused.
#
#   2. THE OPERATOR'S OWN HOOK, SILENTLY DESTROYED. configure.sh is run
#      repeatedly on a live machine. Stacking hooks on each re-run, or
#      overwriting a pre-existing pre-commit hook, is data loss in a
#      directory git does not track and therefore cannot restore.
#
# The fixtures are miniature git repos, never this checkout: a test that
# installed hooks into the repository it runs from would arm the operator's
# real working tree as a side effect of running the suite.
# =========================================================================

# --- plant literals -------------------------------------------------------
#
# ASSEMBLED, NEVER WRITTEN OUT -- same reasoning as test_cc_scrub.sh. This
# file is tracked in a PUBLIC repository and is part of the corpus that
# `cc-scrub --audit` sweeps, so a literal session token or /home path
# written here would make the suite a specimen of the class it proves the
# hooks catch. The fragments match no rule on their own.
SEG_HOME="home"; TOK="Zz9876543210AbCdE"
PLANT_SESSION="session_${TOK}"
PLANT_HOME="/${SEG_HOME}/hookfixture/vault/notes.md"

ZERO="0000000000000000000000000000000000000000"

command -v jq >/dev/null 2>&1 || {
    t_fail "jq is required by configure.sh and by this test"
    t_finish; exit $?
}
command -v git >/dev/null 2>&1 || {
    t_fail "git is required by this test"
    t_finish; exit $?
}

# =========================================================================
# FIXTURE BUILDERS
# =========================================================================

# new_repo -- a miniature environment-foundation checkout that is a real git
# repository, carrying the module layout configure.sh and the hooks resolve
# against, plus a `main` branch holding one clean commit to serve as the
# baseline cc-scrub classifies NEW findings against.
#
# The real cc-scrub.sh is COPIED IN rather than stubbed: the whole claim
# under test is that the hook reaches a working scrubber and honours its
# exit codes, and a stub that returns a canned status would prove only that
# the test author can write a stub.
new_repo() {
    local sb repo mod
    sb=$(t_tmpdir) || return 1
    repo="$sb/repo"
    mod="$repo/software/development/claude-code"
    mkdir -p "$mod/scripts" "$mod/canonical/scripts" "$mod/canonical/hooks" \
             "$mod/canonical/shell" "$repo/shared"
    cp "$REPO_ROOT/shared/logging.sh"                     "$repo/shared/logging.sh"
    cp "$CONFIGURE_UNDER_TEST"                            "$mod/scripts/configure.sh"
    cp "$MODULE_DIR/canonical/scripts/cc-scrub.sh"        "$mod/canonical/scripts/cc-scrub.sh"
    cp "$MODULE_DIR/canonical/scripts/cc-scrub-outbound.sh" "$mod/canonical/scripts/cc-scrub-outbound.sh"
    # -p, and no chmod: git treats a NON-EXECUTABLE hook as absent and says
    # nothing about it. Repairing the mode on the way into the fixture would
    # hide exactly that failure, so the fixture inherits whatever the
    # canonical file actually carries.
    cp -p "$PRECOMMIT_UNDER_TEST"                            "$mod/canonical/hooks/pre-commit.sh"
    cp -p "$PREPUSH_UNDER_TEST"                              "$mod/canonical/hooks/pre-push.sh"
    cp -p "$MODULE_DIR/canonical/hooks/cc-scrub-hook-lib.sh" "$mod/canonical/hooks/cc-scrub-hook-lib.sh"

    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "fixture@invalid"
    git -C "$repo" config user.name  "fixture"
    git -C "$repo" config commit.gpgsign false
    printf 'clean baseline\n' > "$repo/README.md"
    git -C "$repo" add -A
    git -C "$repo" -c core.hooksPath=/dev/null commit -qm "baseline"

    printf '%s\n' "$sb"
}

# Stub `claude` on PATH plus a sandbox HOME: configure.sh refuses to run
# without a claude binary, and must never touch the operator's real ~/.claude.
prep_env() {
    local sb="$1"
    mkdir -p "$sb/bin" "$sb/home"
    printf '#!/bin/sh\nexit 0\n' > "$sb/bin/claude"
    chmod +x "$sb/bin/claude"
}

run_configure() {
    local sb="$1"
    HOME="$sb/home" PATH="$sb/bin:$PATH" \
        bash "$sb/repo/software/development/claude-code/scripts/configure.sh" 2>&1
}

# hooks_dir <repo> -- where git will actually look. Asking git rather than
# assuming .git/hooks is the point: in a linked worktree .git is a FILE and
# the hooks live in the common dir, which is exactly the layout every
# cc-branch session runs in.
hooks_dir() {
    local d
    d=$(git -C "$1" rev-parse --git-path hooks)
    case "$d" in /*) printf '%s\n' "$d" ;; *) printf '%s\n' "$1/$d" ;; esac
}

CANON_REL="software/development/claude-code/canonical/hooks"

# =========================================================================
# 1. INSTALL -- configure.sh deploys both hooks as symlinks into canonical/
#
# Symlinks and not copies, matching how configure.sh deploys every other
# canonical asset: a copy is a fork the moment the canonical file changes,
# and the operator would be running last month's gate believing it was
# this month's.
# =========================================================================

t_diag "--- install ---"

SB=$(new_repo) || { t_fail "fixture"; t_finish; exit 1; }
prep_env "$SB"
REPO="$SB/repo"
HD=$(hooks_dir "$REPO")

out1=$(run_configure "$SB"); rc1=$?
assert_eq "configure.sh exits 0 on a git checkout" "0" "$rc1"

assert_eq "installs pre-commit as a symlink into canonical/hooks/" \
    "$REPO/$CANON_REL/pre-commit.sh" "$(readlink "$HD/pre-commit" 2>/dev/null)"
assert_eq "installs pre-push as a symlink into canonical/hooks/" \
    "$REPO/$CANON_REL/pre-push.sh" "$(readlink "$HD/pre-push" 2>/dev/null)"

[ -x "$HD/pre-commit" ] && t_pass "the installed pre-commit is executable" \
                        || t_fail "the installed pre-commit is executable"
[ -x "$HD/pre-push" ]   && t_pass "the installed pre-push is executable" \
                        || t_fail "the installed pre-push is executable"

assert_contains "the run says which hooks it installed" "pre-commit" "$out1"

# The user-facing scrubber names, per the INFRA-59 ticket: the file keeps
# its .sh extension for the shellcheck glob, the deployed name drops it.
assert_eq "deploys ~/.claude/cc-scrub pointing at the F1 arm" \
    "$REPO/software/development/claude-code/canonical/scripts/cc-scrub.sh" \
    "$(readlink "$SB/home/.claude/cc-scrub" 2>/dev/null)"
assert_eq "deploys ~/.claude/cc-scrub-outbound pointing at the outbound arm" \
    "$REPO/software/development/claude-code/canonical/scripts/cc-scrub-outbound.sh" \
    "$(readlink "$SB/home/.claude/cc-scrub-outbound" 2>/dev/null)"

# =========================================================================
# 2. IDEMPOTENCY -- a re-run must not stack, duplicate or churn
# =========================================================================

t_diag "--- idempotency ---"

out2=$(run_configure "$SB"); rc2=$?
assert_eq "a clean idempotent re-run exits 0" "0" "$rc2"
assert_eq "re-run leaves pre-commit pointing at the same target" \
    "$REPO/$CANON_REL/pre-commit.sh" "$(readlink "$HD/pre-commit" 2>/dev/null)"
assert_not_contains "re-run backs nothing up" "backed up hook" "$out2"

n_hooks=$(find "$HD" -maxdepth 1 -name 'pre-commit*' -not -name '*.sample' | wc -l)
assert_eq "exactly one pre-commit hook file exists after two runs" "1" "$n_hooks"

# =========================================================================
# 3. THE OPERATOR'S OWN HOOK IS NOT DESTROYED
#
# .git/hooks is untracked, so an overwrite here is unrecoverable. The
# content must survive somewhere the operator can find it.
# =========================================================================

t_diag "--- pre-existing hooks and hooksPath ---"

SB2=$(new_repo) || { t_fail "fixture"; t_finish; exit 1; }
prep_env "$SB2"
HD2=$(hooks_dir "$SB2/repo")
mkdir -p "$HD2"
printf '#!/bin/sh\n# my own hook\nexit 0\n' > "$HD2/pre-commit"
chmod +x "$HD2/pre-commit"

out3=$(run_configure "$SB2"); rc3=$?
assert_eq "run over a pre-existing real hook exits 0" "0" "$rc3"
assert_contains "the pre-existing hook is reported backed up" "backed up hook" "$out3"
assert_eq "the canonical hook is installed in its place" \
    "$SB2/repo/$CANON_REL/pre-commit.sh" "$(readlink "$HD2/pre-commit" 2>/dev/null)"

kept=$(find "$HD2" -maxdepth 1 -name 'pre-commit.backup-*' | tail -1)
if [ -n "$kept" ] && grep -q 'my own hook' "$kept"; then
    t_pass "the displaced hook's content survives beside it"
else
    t_fail "the displaced hook's content survives beside it" "found: ${kept:-<nothing>}"
fi

# core.hooksPath is the operator telling git the hooks live somewhere else.
# Installing into .git/hooks anyway would produce a hook that never runs and
# a configure.sh that reported it installed -- failure mode 1 exactly.
SB3=$(new_repo) || { t_fail "fixture"; t_finish; exit 1; }
prep_env "$SB3"
mkdir -p "$SB3/repo/.myhooks"
git -C "$SB3/repo" config core.hooksPath .myhooks
out4=$(run_configure "$SB3"); rc4=$?
assert_eq "run under a foreign core.hooksPath exits 0" "0" "$rc4"
assert_contains "...and says why it did not install" "core.hooksPath" "$out4"
if [ -e "$SB3/repo/.git/hooks/pre-commit" ]; then
    t_fail "...and installs nothing git would ignore"
else
    t_pass "...and installs nothing git would ignore"
fi

# =========================================================================
# 4. A NON-GIT CHECKOUT IS NOT A FAILURE
#
# configure.sh's job is the dotfiles; the hooks are an extra. An operator
# who unpacked a tarball must still get a configured machine.
# =========================================================================

SB4=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
mkdir -p "$SB4/repo/software/development/claude-code/scripts" \
         "$SB4/repo/software/development/claude-code/canonical/hooks" \
         "$SB4/repo/shared"
cp "$REPO_ROOT/shared/logging.sh" "$SB4/repo/shared/logging.sh"
cp "$CONFIGURE_UNDER_TEST" "$SB4/repo/software/development/claude-code/scripts/configure.sh"
prep_env "$SB4"
out5=$(run_configure "$SB4"); rc5=$?
assert_eq "a non-git checkout still configures cleanly (exit 0)" "0" "$rc5"
assert_contains "...saying the hooks were skipped" "not a git" "$out5"

# =========================================================================
# 5. THE PRE-COMMIT GATE BITES
#
# Driven through `git commit`, not by calling the hook directly: the claim
# is that GIT runs it, and a direct invocation would pass even if the file
# were installed somewhere git never looks.
# =========================================================================

t_diag "--- pre-commit behaviour ---"

commit_attempt() {   # <repo> <file> <content> -- stage and try to commit
    printf '%s\n' "$3" > "$1/$2"
    git -C "$1" add "$2"
    git -C "$1" commit -m "fixture change" 2>&1
}

printf 'a wholly ordinary line\n' > "$REPO/clean.md"
git -C "$REPO" add clean.md
out=$(git -C "$REPO" commit -m "clean change" 2>&1); rc=$?
assert_eq "a clean staged change commits (exit 0)" "0" "$rc"

out=$(commit_attempt "$REPO" "leak.md" "see $PLANT_SESSION for detail"); rc=$?
assert_ne "a staged session identifier refuses the commit" "0" "$rc"
assert_contains "...naming the rule that fired" "session-id" "$out"
assert_contains "...and the file it fired in" "leak.md" "$out"
assert_contains "...and how to proceed deliberately" "--no-verify" "$out"

# The commit must not have happened. A gate that prints a refusal and then
# lets the commit land is the same as no gate.
head_msg=$(git -C "$REPO" log -1 --format=%s)
assert_eq "...and the commit did not land" "clean change" "$head_msg"

# A second rule, so the assertion above is not pinned to one pattern.
git -C "$REPO" reset -q
out=$(commit_attempt "$REPO" "path.md" "the file lives at $PLANT_HOME"); rc=$?
assert_ne "a staged operator home path refuses the commit" "0" "$rc"
assert_contains "...naming that rule too" "home-path" "$out"

git -C "$REPO" reset -q
rm -f "$REPO/leak.md" "$REPO/path.md"

# --no-verify is git's own bypass and the hook cannot stop it. Asserted so
# the documented escape hatch is a measured fact, not a hope.
printf 'see %s for detail\n' "$PLANT_SESSION" > "$REPO/bypass.md"
git -C "$REPO" add bypass.md
git -C "$REPO" commit -q --no-verify -m "bypassed" 2>/dev/null; rc=$?
assert_eq "--no-verify skips the gate (git's own bypass, documented not blocked)" "0" "$rc"
git -C "$REPO" reset -q --hard HEAD~1

# =========================================================================
# 6. THE GATE FAILS CLOSED
#
# The one failure mode a gate may not have. If the scrubber is missing the
# hook must refuse, not wave the commit through.
# =========================================================================

t_diag "--- fail-closed ---"

SB5=$(new_repo) || { t_fail "fixture"; t_finish; exit 1; }
prep_env "$SB5"
run_configure "$SB5" >/dev/null 2>&1
rm -f "$SB5/repo/software/development/claude-code/canonical/scripts/cc-scrub.sh"
printf 'ordinary\n' > "$SB5/repo/ordinary.md"
git -C "$SB5/repo" add ordinary.md
out=$(HOME="$SB5/home" git -C "$SB5/repo" commit -m "no scrubber" 2>&1); rc=$?
assert_ne "a missing scrubber refuses the commit rather than passing it" "0" "$rc"
assert_contains "...saying the scrubber could not be found" "cc-scrub" "$out"

# INCOMPLETE (exit 2) is not clean. An instrument that cannot prove it works
# must not clear a commit, and this is the exit code that says so.
cat > "$SB5/repo/software/development/claude-code/canonical/scripts/cc-scrub.sh" <<'STUB'
#!/usr/bin/env bash
echo "VERDICT: INCOMPLETE -- stub"
exit 2
STUB
out=$(HOME="$SB5/home" git -C "$SB5/repo" commit -m "incomplete" 2>&1); rc=$?
assert_ne "an INCOMPLETE sweep (exit 2) refuses the commit too" "0" "$rc"
assert_contains "...and says the sweep did not complete" "INCOMPLETE" "$out"

# =========================================================================
# 7. THE PRE-PUSH GATE OVER THE OUTGOING RANGE
#
# Fed on stdin in git's own format, because that is the only interface the
# hook has. The range is remote_sha..local_sha: the commits the push would
# publish, which is a different corpus from the working tree.
# =========================================================================

t_diag "--- pre-push behaviour ---"

SB6=$(new_repo) || { t_fail "fixture"; t_finish; exit 1; }
prep_env "$SB6"
run_configure "$SB6" >/dev/null 2>&1
R6="$SB6/repo"
HD6=$(hooks_dir "$R6")
BASE=$(git -C "$R6" rev-parse HEAD)

feed_push() {   # <repo> <lines...> -- run the installed pre-push on stdin
    local r="$1"; shift
    printf '%s\n' "$@" | ( cd "$r" && HOME="$SB6/home" bash "$(hooks_dir "$r")/pre-push" origin "https://example.invalid/r.git" 2>&1 )
}

printf 'still ordinary\n' > "$R6/ok.md"
git -C "$R6" add ok.md
git -C "$R6" -c core.hooksPath=/dev/null commit -qm "an ordinary commit"
CLEAN_TIP=$(git -C "$R6" rev-parse HEAD)

out=$(feed_push "$R6" "refs/heads/main $CLEAN_TIP refs/heads/main $BASE"); rc=$?
assert_eq "a clean outgoing range passes the push (exit 0)" "0" "$rc"

printf 'see %s for detail\n' "$PLANT_SESSION" > "$R6/leaky.md"
git -C "$R6" add leaky.md
git -C "$R6" -c core.hooksPath=/dev/null commit -qm "a commit carrying a tell"
DIRTY_TIP=$(git -C "$R6" rev-parse HEAD)

out=$(feed_push "$R6" "refs/heads/main $DIRTY_TIP refs/heads/main $BASE"); rc=$?
assert_ne "a disclosure in the outgoing range refuses the push" "0" "$rc"
assert_contains "...naming the rule" "session-id" "$out"
assert_contains "...and naming the escape hatch" "--no-verify" "$out"

# A branch deletion pushes no content. Scanning is meaningless and blocking
# would be a false refusal.
out=$(feed_push "$R6" "(delete) $ZERO refs/heads/gone $BASE"); rc=$?
assert_eq "a ref deletion is not scanned and does not block" "0" "$rc"
# Exit 0 alone is weak evidence: a bogus range like <base>..<all-zeros>
# also diffs to nothing and sweeps "clean". The ref must not be swept AT
# ALL, and silence is what proves it -- every swept ref prints its corpus.
assert_eq "...and is not swept at all (no corpus line for it)" "" "$out"

# Nothing to push at all -- git can still call the hook with no stdin lines.
out=$(feed_push "$R6" ""); rc=$?
assert_eq "an empty stdin does not block" "0" "$rc"

# A NEW remote ref has no remote sha to bound the range with. The hook must
# fall back to a PUBLISHED baseline rather than inventing one -- and must
# still catch the tell that sits between that baseline and the tip.
git -C "$R6" reset -q --hard "$CLEAN_TIP"
git -C "$R6" checkout -q -b topic
printf 'see %s for detail\n' "$PLANT_SESSION" > "$R6/topic-leak.md"
git -C "$R6" add topic-leak.md
git -C "$R6" -c core.hooksPath=/dev/null commit -qm "topic work"
TOPIC_DIRTY=$(git -C "$R6" rev-parse HEAD)

out=$(feed_push "$R6" "refs/heads/topic $TOPIC_DIRTY refs/heads/topic $ZERO"); rc=$?
assert_ne "a new remote ref is bounded against a published baseline, and still bites" "0" "$rc"
assert_contains "...naming the rule on the new-ref path too" "session-id" "$out"

git -C "$R6" reset -q --hard "$CLEAN_TIP"
printf 'a clean topic change\n' > "$R6/topic-ok.md"
git -C "$R6" add topic-ok.md
git -C "$R6" -c core.hooksPath=/dev/null commit -qm "clean topic work"
TOPIC_CLEAN=$(git -C "$R6" rev-parse HEAD)
out=$(feed_push "$R6" "refs/heads/topic $TOPIC_CLEAN refs/heads/topic $ZERO"); rc=$?
assert_eq "a clean new remote ref passes" "0" "$rc"

# The genuinely unbounded case: the first push of the only branch there is.
# Nothing is published, so no baseline exists that is not the tip itself,
# and `main..main` would sweep an empty corpus. An empty corpus reported
# CLEAN is the false zero this toolchain refuses, so it refuses instead.
git -C "$R6" checkout -q main
out=$(feed_push "$R6" "refs/heads/main $CLEAN_TIP refs/heads/main $ZERO"); rc=$?
assert_ne "a first push with no published baseline refuses rather than sweeping nothing" "0" "$rc"
assert_contains "...saying the range could not be bounded" "cannot bound" "$out"
assert_contains "...and pointing at the deliberate sweep" "--audit" "$out"

# =========================================================================
# 8. THE INSTALLED HOOK IS THE CANONICAL ONE
#
# A copy would drift. Prove the deployed hook resolves to the file under
# canonical/, so editing canonical is editing the live gate.
# =========================================================================

# The exec bit must be in the git INDEX, not just in this working tree. A
# fresh clone of a 100644 hook gives git a file it silently declines to run:
# no error, no warning, and a repository the operator believes is guarded.
for h in pre-commit pre-push; do
    mode=$(git -C "$REPO_ROOT" ls-files -s -- \
        "software/development/claude-code/canonical/hooks/$h.sh" 2>/dev/null | awk '{print $1}')
    assert_eq "canonical/hooks/$h.sh is mode 100755 in the git index" "100755" "$mode"
done

real=$(readlink -f "$HD6/pre-push")
assert_eq "the deployed pre-push resolves to the canonical file" \
    "$(readlink -f "$R6/$CANON_REL/pre-push.sh")" "$real"

t_finish
