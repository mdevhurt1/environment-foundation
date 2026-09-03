#!/usr/bin/env bash
# Description: Behavioral tests for scripts/configure.sh — deploys the full symlink set (including cc-plane-sync.sh, INFRA-46) into a sandbox $HOME and exits 0 on a clean idempotent re-run (INFRA-51).
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, jq, coreutils, scripts/configure.sh

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

t_begin "configure.sh: full deploy into a sandbox HOME, exit 0 on a clean re-run"

# =========================================================================
# WHY THIS FILE EXISTS
#
# configure.sh had a known exit-code defect open for ~25 days: its final
# line, `[ -d "$BACKUP_DIR" ] && log_info ...` under `set -e`, returned 1 on
# every clean idempotent re-run — the exact case a chained installer or CI
# gate would hit (INFRA-51, audit F4.1). And cc-plane-sync.sh shipped with
# no link line at all, leaving the bookend skills on a fallback path
# (INFRA-46 item 1). Both fixes are one-liners; both are exactly the class a
# single assertion holds forever.
#
# The sandbox: an overridden $HOME plus a stub `claude` on PATH (configure
# refuses to run without one). Everything configure touches lives under the
# sandbox, so the operator's real ~/.claude is never read or written.
#
# The script under test is COPIED into a miniature repo scaffold (same
# pattern as test_doctor_*.sh) rather than executed in place: configure.sh
# resolves REPO_ROOT from its own location, so running a bare copy from a
# temp dir dies on the logging.sh source — which would make every mutant
# "fail" for that reason instead of the mutated behaviour.
# =========================================================================

command -v jq >/dev/null 2>&1 || {
    t_fail "jq is required by configure.sh and by this test"
    t_finish; exit $?
}

SANDBOX=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
FAKEHOME="$SANDBOX/home"
mkdir -p "$FAKEHOME"

# Stub claude: require_command only needs it findable on PATH.
mkdir -p "$SANDBOX/bin"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/claude"
chmod +x "$SANDBOX/bin/claude"

# Miniature repo scaffold around a COPY of the script under test.
SCAF="$SANDBOX/repo"
mkdir -p "$SCAF/shared" "$SCAF/software/development/claude-code/scripts" \
         "$SCAF/software/development/claude-code/canonical/shell"
cp "$REPO_ROOT/shared/logging.sh" "$SCAF/shared/logging.sh"
cp "$CONFIGURE_UNDER_TEST" "$SCAF/software/development/claude-code/scripts/configure.sh"

run_configure() {
    HOME="$FAKEHOME" PATH="$SANDBOX/bin:$PATH" \
        bash "$SCAF/software/development/claude-code/scripts/configure.sh" 2>&1
}

CANONICAL="$SCAF/software/development/claude-code/canonical"

# --- first run: a fresh machine -------------------------------------------
out1=$(run_configure); rc1=$?
assert_eq "first run exits 0" "0" "$rc1"

# The full link set, each pointing into this checkout's canonical/.
declare -A LINKS=(
    [CLAUDE.md]="$CANONICAL/CLAUDE.md"
    [settings.json]="$CANONICAL/settings.json"
    [statusline-command.sh]="$CANONICAL/statusline-command.sh"
    [skills]="$CANONICAL/skills"
    [cc-functions.sh]="$CANONICAL/shell/cc-functions.sh"
    [model-policy.json]="$CANONICAL/model-policy.json"
    [cc-tree-slot-write.sh]="$CANONICAL/shell/cc-tree-slot-write.sh"
    [cc-tree-slot-update.sh]="$CANONICAL/shell/cc-tree-slot-update.sh"
    [cc-ring-scan.sh]="$CANONICAL/shell/cc-ring-scan.sh"
    [agents]="$CANONICAL/agents"
    [cc-skills-inject.sh]="$CANONICAL/shell/cc-skills-inject.sh"
    [cc-memory-inject.sh]="$CANONICAL/shell/cc-memory-inject.sh"
    [cc-memory-index-regen.sh]="$CANONICAL/shell/cc-memory-index-regen.sh"
    [cc-plane-sync.sh]="$CANONICAL/shell/cc-plane-sync.sh"
)
for name in "${!LINKS[@]}"; do
    actual=$(readlink "$FAKEHOME/.claude/$name" 2>/dev/null)
    assert_eq "deploys ~/.claude/$name as a symlink into canonical/" \
        "${LINKS[$name]}" "$actual"
done

grep -Fq 'cc-functions.sh' "$FAKEHOME/.bashrc" 2>/dev/null \
    && t_pass "adds the cc-functions source line to ~/.bashrc" \
    || t_fail "adds the cc-functions source line to ~/.bashrc"

# --- second run: clean idempotent re-run (the INFRA-51 case) --------------
# No backup is made because every target is already the correct symlink, so
# BACKUP_DIR never comes into existence and the final log line's `[ -d ]`
# test is false. Before the fix that false was the script's exit status.
out2=$(run_configure); rc2=$?
assert_eq "clean idempotent re-run exits 0 (INFRA-51)" "0" "$rc2"
assert_not_contains "re-run makes no backup" "backed up" "$out2"

n_lines=$(grep -Fc 'cc-functions.sh' "$FAKEHOME/.bashrc" 2>/dev/null)
assert_eq "re-run does not duplicate the ~/.bashrc source line" "1" "$n_lines"

# --- third shape: a real file where a symlink belongs is backed up --------
rm "$FAKEHOME/.claude/CLAUDE.md"
printf 'local edit\n' > "$FAKEHOME/.claude/CLAUDE.md"
out3=$(run_configure); rc3=$?
assert_eq "run over a real file exits 0" "0" "$rc3"
assert_contains "the real file is reported backed up" "backed up" "$out3"
actual=$(readlink "$FAKEHOME/.claude/CLAUDE.md" 2>/dev/null)
assert_eq "the real file is replaced by the canonical symlink" \
    "$CANONICAL/CLAUDE.md" "$actual"
backup_copy=$(find "$FAKEHOME/.claude" -path '*/.backup-*/CLAUDE.md' | tail -1)
if [ -n "$backup_copy" ] && [ "$(cat "$backup_copy")" = "local edit" ]; then
    t_pass "the displaced file's content survives in the backup dir"
else
    t_fail "the displaced file's content survives in the backup dir" \
        "found: ${backup_copy:-<nothing>}"
fi

t_finish
