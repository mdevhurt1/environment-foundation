#!/usr/bin/env bash
# Description: Tests for scripts/doctor.sh's Pipeline SIGPIPE safety check — a real early-exit pipe consumer must be flagged, but a logical-OR `|| grep -q FILE` guard (no producer to kill) must not (INFRA-46 regression, found live 2026-09-03).
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

# Overridable so mutate.sh can point this file at a deliberately broken copy.
DOCTOR_UNDER_TEST="${DOCTOR_UNDER_TEST:-$MODULE_DIR/scripts/doctor.sh}"

t_begin "doctor.sh: SIGPIPE check flags real pipes, not ||-guards on files"

# =========================================================================
# WHY THIS FILE EXISTS
#
# The first live merge after the check shipped (2026-09-03) produced a false
# FAIL: `if grep -qxF a FILE || grep -qxF b FILE` in cc-tree-slot-update.sh
# was flagged because the regex read the second bar of `||` as a pipe. A
# grep that reads a FILE and exits early kills no producer — flagging it
# trains the one red instrument into ignorability, the exact INFRA-47
# failure mode. These fixtures pin both directions.
# =========================================================================

WORK=$(t_tmpdir) || { t_fail "tmpdir"; t_finish; exit 1; }
MAIN="$WORK/repo"
FAKEHOME="$WORK/home"
mkdir -p "$FAKEHOME" "$MAIN/shared" "$MAIN/software/development/claude-code/scripts" \
         "$MAIN/software/development/claude-code/canonical/shell"
cp "$REPO_ROOT/shared/logging.sh" "$MAIN/shared/logging.sh"
cp "$DOCTOR_UNDER_TEST" "$MAIN/software/development/claude-code/scripts/doctor.sh"
git -C "$MAIN" init -q -b main 2>/dev/null || true

CANON="$MAIN/software/development/claude-code/canonical/shell"

sigpipe_section() {
    HOME="$FAKEHOME" bash "$MAIN/software/development/claude-code/scripts/doctor.sh" 2>/dev/null \
        | sed -e 's/\x1b\[[0-9;]*m//g' \
        | awk '/^== Pipeline SIGPIPE safety ==$/{f=1; next} /^== /{f=0} f'
}

# --- 1. a real early-exit pipe consumer under pipefail is flagged ---------
cat > "$CANON/real-pipe.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
find / -name x | grep -q needle
EOF
out=$(sigpipe_section)
assert_contains "a true pipe into grep -q draws a FAIL" "[FAIL]" "$out"
assert_contains "the FAIL names the offending file" "real-pipe.sh" "$out"

# --- 2. a ||-guard reading FILES is not a pipe: no flag -------------------
rm "$CANON/real-pipe.sh"
cat > "$CANON/or-guard.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if grep -qxF "a" /etc/hostname \
   || grep -qxF "b" /etc/hostname; then
    :
fi
EOF
out=$(sigpipe_section)
assert_contains "a logical-OR file guard stays OK" "[OK]" "$out"
assert_not_contains "and draws no FAIL" "or-guard.sh" "$out"

# --- 3. sigpipe-ok opt-out still silences a real pipe ---------------------
cat > "$CANON/opted-out.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'small\n' | grep -q small  # sigpipe-ok
EOF
out=$(sigpipe_section)
assert_not_contains "sigpipe-ok annotation silences the line" "opted-out.sh" "$out"

t_finish
