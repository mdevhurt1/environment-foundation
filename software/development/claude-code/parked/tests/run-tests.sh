#!/usr/bin/env bash
# Description: Test runner for the claude-code shell tooling — executes every tests/test_*.sh in its own process and emits one flat TAP 13 stream plus a summary.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, jq, coreutils; shellcheck optional
# Idempotent.

set -uo pipefail   # NOT -e: a failing test file must not abort the run.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MODULE_DIR/../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

usage() {
    cat <<USAGE
Usage: bash tests/run-tests.sh [-v] [<name>...]

  <name>   run only the named test file(s); accepts "resolve_model",
           "test_resolve_model" or "test_resolve_model.sh".
  -v       echo each test file's raw output as it runs, before the
           renumbered TAP stream.

Exit status is 0 only if every assertion in every file passed.
USAGE
}

VERBOSE=0
SELECT=()
while [ $# -gt 0 ]; do
    case "$1" in
        -v|--verbose) VERBOSE=1 ;;
        -h|--help)    usage; exit 0 ;;
        -*)           log_error "unknown option: $1"; usage; exit 2 ;;
        *)            SELECT+=("$1") ;;
    esac
    shift
done

# Each file runs in its OWN process. The tests deliberately overwrite $HOME and
# $PATH to reach refusal branches that are otherwise unreachable on a configured
# machine; letting that leak into a sibling file would make results depend on
# collation order. `env -u` additionally strips the three variables the
# resolvers read, so an operator who happens to have CC_MODEL exported in their
# shell gets the same result as CI.
run_one() {
    env -u CC_MODEL -u CC_MODEL_POLICY -u CC_PERM_MODE bash "$1" 2>&1
}

shopt -s nullglob
ALL=("$SCRIPT_DIR"/test_*.sh)
shopt -u nullglob

FILES=()
if [ "${#SELECT[@]}" -eq 0 ]; then
    FILES=("${ALL[@]}")
else
    for want in "${SELECT[@]}"; do
        want="${want%.sh}"; want="${want#test_}"
        match="$SCRIPT_DIR/test_${want}.sh"
        if [ -f "$match" ]; then
            FILES+=("$match")
        else
            log_error "no such test file: test_${want}.sh"
            exit 2
        fi
    done
fi

if [ "${#FILES[@]}" -eq 0 ]; then
    log_error "no test files found in $SCRIPT_DIR"
    exit 2
fi

RAW=$(mktemp) || exit 2
trap 'rm -f "$RAW"' EXIT

FILE_FAILS=0
for f in "${FILES[@]}"; do
    name="$(basename "$f")"
    out=$(run_one "$f"); rc=$?
    [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$out" >&2
    {
        printf '# --- %s ---\n' "$name"
        # Drop each file's own "TAP version" and "1..N" plan lines; this runner
        # emits one of each for the whole run.
        printf '%s\n' "$out" | grep -vE '^(TAP version|1\.\.)'
        # A file that dies before printing a plan (a syntax error, a missing
        # dependency, an unbound variable under set -u) would otherwise
        # contribute ZERO assertions and be indistinguishable from a file that
        # passed. Synthesise a failure so the run cannot go green on silence.
        if ! printf '%s\n' "$out" | grep -qE '^1\.\.[0-9]+'; then
            printf 'not ok - %s did not complete (no TAP plan emitted, rc=%s)\n' "$name" "$rc"
        fi
    } >> "$RAW"
    [ "$rc" -eq 0 ] || FILE_FAILS=$((FILE_FAILS + 1))
done

printf 'TAP version 13\n'
awk '
    /^ok([ ]|$)/      { n++; sub(/^ok[ ]+[0-9]+[ ]+-/, "ok -"); sub(/^ok[ ]+-/, "ok -");
                        printf "ok %d -%s\n", n, substr($0, index($0, "-") + 1); next }
    /^not ok([ ]|$)/  { n++; f++; sub(/^not ok[ ]+[0-9]+[ ]+-/, "not ok -");
                        printf "not ok %d -%s\n", n, substr($0, index($0, "-") + 1); next }
    { print }
    END { printf "1..%d\n", n; printf "# assertions: %d, failed: %d\n", n, f + 0 }
' "$RAW"

TOTAL=$(grep -cE '^(ok|not ok)' "$RAW")
FAILED=$(grep -cE '^not ok' "$RAW")

echo
if [ "$FAILED" -eq 0 ] && [ "$FILE_FAILS" -eq 0 ]; then
    log_ok "$TOTAL assertions passed across ${#FILES[@]} test file(s)."
    exit 0
fi
log_error "$FAILED of $TOTAL assertions failed (${FILE_FAILS} test file(s) exited non-zero)."
grep -E '^not ok' "$RAW" | sed 's/^/        /' >&2
exit 1
