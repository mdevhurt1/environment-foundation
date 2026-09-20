#!/usr/bin/env bash
# Description: Tests for scripts/doctor.sh's push-lag check — unpushed commits on main must surface as a WARN with count and age, so merged-but-unpushed work cannot go silently stale (INFRA-50).
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

# Overridable so mutate.sh can point this file at a deliberately broken copy.
DOCTOR_UNDER_TEST="${DOCTOR_UNDER_TEST:-$MODULE_DIR/scripts/doctor.sh}"

t_begin "doctor.sh: the push-lag check makes merged-but-unpushed main visible"

# =========================================================================
# WHY THIS FILE EXISTS
#
# The 2026-09-03 audit found 15 merged commits — including the entire test
# harness — on one disk only, because nothing in the workflow ever compared
# local main to origin/main (INFRA-50, audit F1). The doctor check under
# test here is the standing instrument: OK when main is fully pushed, WARN
# with a count and the oldest commit's age when it is not, and a loud
# unavailable-WARN rather than silence when there is nothing to judge
# against. The fixture is a miniature repo (same scaffold pattern as
# test_doctor_symlinks.sh) with a local bare "origin".
# =========================================================================

if ! command -v git >/dev/null 2>&1; then
    t_pass "push-lag tests skipped (git not installed)"
    t_finish
    exit $?
fi

WORK=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
MAIN="$WORK/repo"
ORIGIN="$WORK/origin.git"
FAKEHOME="$WORK/home"
mkdir -p "$FAKEHOME" "$MAIN/shared" "$MAIN/software/development/claude-code/scripts" \
         "$MAIN/software/development/claude-code/canonical"
cp "$REPO_ROOT/shared/logging.sh" "$MAIN/shared/logging.sh"
cp "$DOCTOR_UNDER_TEST" "$MAIN/software/development/claude-code/scripts/doctor.sh"

GITC=(git -C "$MAIN" -c user.email=t@test -c user.name=t)
git -C "$MAIN" init -q -b main
"${GITC[@]}" add -A
"${GITC[@]}" commit -q -m scaffold

# push_lag_section -- run the scaffold's doctor and print only the Push lag
# section's counted lines, ANSI-stripped. Everything else runs against the
# fake HOME and is deliberately ignored: this file tests one section.
push_lag_section() {
    HOME="$FAKEHOME" bash "$MAIN/software/development/claude-code/scripts/doctor.sh" 2>/dev/null \
        | sed -e 's/\x1b\[[0-9;]*m//g' \
        | awk '/^== Push lag ==$/{f=1; next} /^== /{f=0} f'
}

# --- 1. no origin at all: unavailable is said out loud, not skipped -------
out=$(push_lag_section)
assert_contains "no origin/main ref draws a WARN, not silence" "[WARN]" "$out"
assert_contains "the WARN names what is missing" "no origin/main ref" "$out"

# --- 2. fully pushed main is OK -------------------------------------------
git init -q --bare "$ORIGIN"
git -C "$MAIN" remote add origin "$ORIGIN"
git -C "$MAIN" push -q origin main
out=$(push_lag_section)
assert_contains "fully pushed main reports OK" "[OK]" "$out"
assert_not_contains "fully pushed main draws no WARN" "[WARN]" "$out"

# --- 3. unpushed commits: WARN carries the count and the oldest age -------
# Two commits, the older one back-dated 13 days — the audit's own number.
old_date=$(date -d '13 days ago' -Is)
printf 'a\n' > "$MAIN/a.txt"
"${GITC[@]}" add a.txt
GIT_COMMITTER_DATE="$old_date" GIT_AUTHOR_DATE="$old_date" \
    "${GITC[@]}" commit -q -m "thirteen days unpushed"
printf 'b\n' > "$MAIN/b.txt"
"${GITC[@]}" add b.txt
"${GITC[@]}" commit -q -m "fresh unpushed"

out=$(push_lag_section)
assert_contains "unpushed commits draw a WARN" "[WARN]" "$out"
assert_contains "the WARN carries the exact count" "2 commit(s) on main not pushed" "$out"
assert_contains "the WARN carries the oldest commit's age" "oldest is 13 day(s) old" "$out"
assert_contains "the remedy names the ritual's push step" "disclosure review" "$out"

# --- 4. pushing clears it -------------------------------------------------
git -C "$MAIN" push -q origin main
out=$(push_lag_section)
assert_contains "pushing returns the check to OK" "[OK]" "$out"
assert_not_contains "and clears the WARN" "[WARN]" "$out"

t_finish
