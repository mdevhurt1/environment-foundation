#!/usr/bin/env bash
# Description: Tests for scripts/doctor.sh's symlink checks — the expected target must resolve to the canonical (main-worktree) checkout, so a branch-worktree run and a main run report the same verdicts (INFRA-47).
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, git, coreutils, scripts/doctor.sh

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

# Overridable so mutate.sh can point this file at a deliberately broken copy —
# a test that has never failed proves nothing.
DOCTOR_UNDER_TEST="${DOCTOR_UNDER_TEST:-$MODULE_DIR/scripts/doctor.sh}"

t_begin "doctor.sh: symlink checks judge against the canonical checkout, not the running one"

# =========================================================================
# WHY THIS FILE EXISTS
#
# configure.sh deploys the ~/.claude symlinks ONCE, from the main worktree,
# and every session on the machine shares that one live config. doctor.sh
# used to derive the expected symlink target from its own checkout, so any
# run from a cc-branch/cc-explore worktree reported one spurious FAIL per
# deployed symlink — 7 of them — for links that were correct. The repo's
# only self-check was red for every branched session (INFRA-47).
#
# The fixture below is a miniature of the real deployment: a scaffold repo
# holding doctor.sh + a canonical/ payload, a git worktree of it standing in
# for a cc-branch checkout, and a fake $HOME whose ~/.claude links point at
# the scaffold's MAIN worktree. The claims under test:
#
#   1. a main-worktree run reports every deployed link OK;
#   2. a branch-worktree run reports EXACTLY the same verdicts;
#   3. the check keeps its teeth: a link genuinely mis-pointed at the branch
#      worktree FAILs from BOTH checkouts (so the fix is not "trust whatever
#      the links say");
#   4. outside a git checkout doctor falls back to judging against its own
#      location, loudly, rather than dying.
#
# git is a hard dependency of the behaviour under test (main-worktree
# resolution), so its absence skips this file rather than failing it.
# =========================================================================

if ! command -v git >/dev/null 2>&1; then
    t_diag "git not installed - doctor symlink tests skipped (the behaviour under test requires it)."
    t_pass "doctor symlink tests skipped (git not installed)"
    t_finish
    exit $?
fi

WORK=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
MAIN="$WORK/repo"
BRANCH="$WORK/repo-branch-t"
CANON_REL="software/development/claude-code/canonical"

# --- scaffold: a committed miniature repo with the module layout ----------
mkdir -p "$MAIN/$CANON_REL/shell" "$MAIN/$CANON_REL/skills" \
         "$MAIN/$CANON_REL/agents" "$MAIN/shared" \
         "$MAIN/software/development/claude-code/scripts"
cp "$REPO_ROOT/shared/logging.sh" "$MAIN/shared/logging.sh"
cp "$DOCTOR_UNDER_TEST" "$MAIN/software/development/claude-code/scripts/doctor.sh"
printf '# stub\n' > "$MAIN/$CANON_REL/CLAUDE.md"
printf '{}\n'     > "$MAIN/$CANON_REL/settings.json"
printf '# stub\n' > "$MAIN/$CANON_REL/statusline-command.sh"
printf '# stub\n' > "$MAIN/$CANON_REL/shell/cc-functions.sh"
printf '{}\n'     > "$MAIN/$CANON_REL/model-policy.json"
printf '# stub\n' > "$MAIN/$CANON_REL/skills/.keep"
printf '# stub\n' > "$MAIN/$CANON_REL/agents/.keep"

git -C "$MAIN" init -q -b main
git -C "$MAIN" -c user.email=t@test -c user.name=t add -A
git -C "$MAIN" -c user.email=t@test -c user.name=t commit -q -m scaffold
git -C "$MAIN" worktree add -q "$BRANCH" -b branch-t

# --- fake $HOME: links deployed the way configure.sh deploys them ---------
FAKEHOME="$WORK/home"
mkdir -p "$FAKEHOME/.claude"
deploy_links() {
    # $1 = checkout the links should point into (normally $MAIN)
    local target="$1/$CANON_REL"
    ln -sfn "$target/CLAUDE.md"             "$FAKEHOME/.claude/CLAUDE.md"
    ln -sfn "$target/settings.json"         "$FAKEHOME/.claude/settings.json"
    ln -sfn "$target/statusline-command.sh" "$FAKEHOME/.claude/statusline-command.sh"
    ln -sfn "$target/skills"                "$FAKEHOME/.claude/skills"
    ln -sfn "$target/shell/cc-functions.sh" "$FAKEHOME/.claude/cc-functions.sh"
    ln -sfn "$target/model-policy.json"     "$FAKEHOME/.claude/model-policy.json"
    ln -sfn "$target/agents"                "$FAKEHOME/.claude/agents"
}
deploy_links "$MAIN"

# doctor_symlinks <checkout> -- run the scaffold's doctor.sh from <checkout>
# with the fake HOME, and print ONLY the counted lines of the Symlinks
# section, ANSI-stripped. Everything after that section runs against the fake
# HOME too and is deliberately ignored: this file tests one section.
doctor_symlinks() {
    HOME="$FAKEHOME" bash "$1/software/development/claude-code/scripts/doctor.sh" 2>/dev/null \
        | sed -e 's/\x1b\[[0-9;]*m//g' \
        | awk '/^== Symlinks ==$/{f=1; next} /^== /{f=0} f' \
        | grep -E '^\[(OK|WARN|FAIL)\]'
}

# --- 1+2: main and branch runs agree, and both are all-OK -----------------
main_out=$(doctor_symlinks "$MAIN")
branch_out=$(doctor_symlinks "$BRANCH")

n_ok=$(printf '%s\n' "$main_out" | grep -c '^\[OK\]')
assert_eq "main run: all 7 deployed links OK" "7" "$n_ok"
assert_not_contains "main run: no FAIL in the symlink section" "[FAIL]" "$main_out"

assert_not_contains "branch run: no FAIL in the symlink section" "[FAIL]" "$branch_out"
assert_not_contains "branch run: expected target never names the branch worktree" \
    "$BRANCH" "$branch_out"
assert_eq "branch and main runs report identical symlink verdicts" \
    "$main_out" "$branch_out"

# --- 3: teeth — a genuinely mis-pointed link fails from BOTH checkouts ----
ln -sfn "$BRANCH/$CANON_REL/settings.json" "$FAKEHOME/.claude/settings.json"

main_bad=$(doctor_symlinks "$MAIN")
branch_bad=$(doctor_symlinks "$BRANCH")
main_fail_line=$(printf '%s\n' "$main_bad" | grep '^\[FAIL\]')
branch_fail_line=$(printf '%s\n' "$branch_bad" | grep '^\[FAIL\]')

assert_contains "main run: link repointed at a branch worktree FAILs" \
    ".claude/settings.json" "$main_fail_line"
assert_contains "branch run: the same mis-pointed link FAILs there too" \
    ".claude/settings.json" "$branch_fail_line"
assert_eq "the mis-pointed link draws the identical FAIL line from both checkouts" \
    "$main_fail_line" "$branch_fail_line"

deploy_links "$MAIN"

# --- 4: outside any git checkout, fall back loudly to the old judgement ---
PLAIN="$WORK/plain"
mkdir -p "$PLAIN"
cp -R "$MAIN/shared" "$MAIN/software" "$PLAIN/"
rm -rf "$PLAIN/.git" 2>/dev/null

plain_section=$(HOME="$FAKEHOME" bash "$PLAIN/software/development/claude-code/scripts/doctor.sh" 2>/dev/null \
    | sed -e 's/\x1b\[[0-9;]*m//g' \
    | awk '/^== Symlinks ==$/{f=1; next} /^== /{f=0} f')
assert_contains "non-git checkout: falls back with a WARN, not silently" \
    "[WARN]" "$plain_section"
assert_contains "non-git checkout: the links are still evaluated" \
    ".claude/CLAUDE.md" "$plain_section"

t_finish
