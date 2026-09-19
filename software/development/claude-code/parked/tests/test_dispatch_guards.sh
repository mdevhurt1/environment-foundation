#!/usr/bin/env bash
# Description: Tests for the dispatch and never-fatal guards — __cc_die/__cc_log stream discipline, __cc_ea_log_helper_path precedence, the __cc_ea_log_safe never-fatal-never-noisy contract, the cc-land delegator, and the __cc_* snapshot guard that prevents half-spawns.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, canonical/shell/cc-functions.sh

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

CC_FUNCTIONS_UNDER_TEST="${CC_FUNCTIONS_UNDER_TEST:-$MODULE_DIR/canonical/shell/cc-functions.sh}"
# shellcheck source=../canonical/shell/cc-functions.sh
# shellcheck disable=SC1091
source "$CC_FUNCTIONS_UNDER_TEST"

t_begin "dispatch guards, EA-log resolution, stream discipline"

t_sandbox_env || { t_fail "sandbox env"; t_finish; exit 1; }
FIX=$(t_tmpdir) || { t_fail "fixture dir"; t_finish; exit 1; }

# =========================================================================
# 1. Stream discipline. Every helper returns its VALUE on stdout and its prose
#    on stderr, and callers do `spec=$(__cc_resolve_model r)`. A log line that
#    leaked to stdout would be captured and parsed as data -- a model id of
#    "[cc] model: opus". This is the invariant the whole harness relies on.
# =========================================================================
t_run __cc_log "hello from log"
assert_eq "__cc_log writes nothing to stdout" "" "$T_OUT"
assert_contains "__cc_log writes its message to stderr" "hello from log" "$T_ERR"
assert_contains "__cc_log tags its output" "[cc]" "$T_ERR"
assert_eq "__cc_log returns 0" 0 "$T_RC"

t_run __cc_die "the refusal reason"
assert_eq "__cc_die writes nothing to stdout" "" "$T_OUT"
assert_contains "__cc_die writes its message to stderr" "the refusal reason" "$T_ERR"
# __cc_die is used as `__cc_die "..." ; return 1` and as the last statement of a
# refusal branch, so its own non-zero status is load-bearing.
assert_eq "__cc_die returns 1" 1 "$T_RC"

# Colour is emitted only to a terminal. Under capture (a pipe, and every CI
# runner) the escapes must be absent, or the .cc-mode and event files that
# quote these messages would carry raw ANSI into version control.
assert_not_contains "no ANSI escape reaches a captured stderr" $'\033' "$T_ERR"
t_run __cc_color_or_plain $'\033[01;31m'
assert_eq "__cc_color_or_plain emits nothing when stderr is not a tty" "" "$T_OUT"

# =========================================================================
# 2. __cc_ea_log_helper_path -- four routes, in order. Route 3 (the skills
#    symlink) exists so the trail works BEFORE configure.sh has grown a link
#    line; route 4 is the same pre-merge escape as the model policy's.
# =========================================================================
mkdir -p "$HOME/.claude/skills" "$HOME/.claude/shell" "$FIX/repo/shell"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/explicit.sh"

t_run __cc_ea_log_helper_path
assert_ne "nothing installed: refuses" 0 "$T_RC"
assert_eq "nothing installed: prints nothing" "" "$T_OUT"

cp "$FIX/explicit.sh" "$FIX/repo/shell/cc-ea-log.sh"
cp "$CC_FUNCTIONS_UNDER_TEST" "$FIX/repo/shell/cc-functions.sh"
ln -sfn "$FIX/repo/shell/cc-functions.sh" "$HOME/.claude/cc-functions.sh"
assert_eq "route 4: the repo copy beside the live symlink" \
    "$FIX/repo/shell/cc-ea-log.sh" "$(__cc_ea_log_helper_path)"

cp "$FIX/explicit.sh" "$HOME/.claude/shell/cc-ea-log.sh"
assert_eq "route 3: the skills-symlink route beats route 4" \
    "$HOME/.claude/skills/../shell/cc-ea-log.sh" "$(__cc_ea_log_helper_path)"

cp "$FIX/explicit.sh" "$HOME/.claude/cc-ea-log.sh"
assert_eq "route 2: the configure.sh symlink beats route 3" \
    "$HOME/.claude/cc-ea-log.sh" "$(__cc_ea_log_helper_path)"

CC_EA_LOG_SH="$FIX/explicit.sh" t_run __cc_ea_log_helper_path
assert_eq "route 1: \$CC_EA_LOG_SH wins over everything" "$FIX/explicit.sh" "$T_OUT"

# An override pointing at a file that is not there must not be chosen; the
# next route takes over rather than the trail silently pointing at nothing.
CC_EA_LOG_SH="$FIX/absent.sh" t_run __cc_ea_log_helper_path
assert_eq "a dangling \$CC_EA_LOG_SH falls through to the next route" \
    "$HOME/.claude/cc-ea-log.sh" "$T_OUT"

# =========================================================================
# 3. __cc_ea_log_safe -- "NEVER fatal and NEVER noisy". A broken action trail
#    must not cost a spawn, and a helper that is not installed yet must not
#    print a warning on every single dispatch.
# =========================================================================
TRAIL="$FIX/trail.txt"
cat > "$FIX/logger.sh" <<'LOG'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CC_TEST_TRAIL"
echo "chatter on stdout"
echo "chatter on stderr" >&2
exit 0
LOG
export CC_TEST_TRAIL="$TRAIL"

CC_EA_LOG_SH="$FIX/logger.sh" t_run __cc_ea_log_safe merge "landed INFRA-55"
assert_eq "a working logger returns 0" 0 "$T_RC"
assert_eq "the trail received the arguments verbatim" "merge landed INFRA-55" "$(cat "$TRAIL")"
assert_eq "the logger's stdout is swallowed" "" "$T_OUT"
assert_eq "the logger's stderr is swallowed" "" "$T_ERR"

cat > "$FIX/broken.sh" <<'LOG'
#!/usr/bin/env bash
echo "boom" >&2
exit 7
LOG
CC_EA_LOG_SH="$FIX/broken.sh" t_run __cc_ea_log_safe merge x
assert_eq "a logger that FAILS still returns 0" 0 "$T_RC"
assert_eq "  ... and stays silent" "" "$T_ERR"

# The pre-merge case: no helper anywhere. Silence is the requirement, not just
# a non-fatal status -- this runs on every dispatch.
rm -f "$HOME/.claude/cc-ea-log.sh" "$HOME/.claude/shell/cc-ea-log.sh" \
      "$FIX/repo/shell/cc-ea-log.sh"
t_run __cc_ea_log_safe merge x
assert_eq "no logger installed: returns 0" 0 "$T_RC"
assert_eq "no logger installed: says nothing on stderr" "" "$T_ERR"
assert_eq "no logger installed: says nothing on stdout" "" "$T_OUT"

# =========================================================================
# 4. cc-land -- the delegator. The four gates themselves live in
#    cc-land-child.sh and are covered by test_land_child.sh; what is asserted
#    here is that the shell entry point finds it, hands over ARGV unchanged,
#    and propagates the exit status the EA reads.
# =========================================================================
cat > "$FIX/land.sh" <<'LAND'
#!/usr/bin/env bash
printf '%s\n' "$#"
for a in "$@"; do printf '[%s]\n' "$a"; done
exit "${CC_TEST_LAND_RC:-0}"
LAND

CC_LAND_CHILD_SH="$FIX/land.sh" t_run cc-land --dry-run "task id with spaces"
assert_eq "cc-land delegates and returns the script's status" 0 "$T_RC"
assert_eq "argv is handed over unchanged" \
    $'2\n[--dry-run]\n[task id with spaces]' "$T_OUT"

CC_TEST_LAND_RC=1 CC_LAND_CHILD_SH="$FIX/land.sh" t_run cc-land x
assert_eq "a refused gate (rc=1) is propagated, not swallowed" 1 "$T_RC"
CC_TEST_LAND_RC=2 CC_LAND_CHILD_SH="$FIX/land.sh" t_run cc-land
assert_eq "a usage error (rc=2) is propagated" 2 "$T_RC"

CC_LAND_CHILD_SH="$FIX/not-installed.sh" t_run cc-land INFRA-55
assert_eq "a missing cc-land-child.sh refuses" 1 "$T_RC"
assert_contains "  ... and names the path it looked at" "not-installed.sh" "$T_ERR"
assert_contains "  ... and points at the skills symlink" "symlink" "$T_ERR"
assert_eq "  ... and prints nothing on stdout" "" "$T_OUT"

# THE SNAPSHOT GUARD. A shell that has been running since before this file
# existed holds a stale function snapshot. Re-sourcing is attempted first; if
# the helpers are STILL absent the entry point must abort BEFORE any side
# effect, rather than limping on with `command not found` and half-spawning.
t_run env "CC_FUNCTIONS_SH=$FIX/does-not-exist.sh" bash -c "
    source '$CC_FUNCTIONS_UNDER_TEST'
    unset -f __cc_die __cc_log
    cc-land INFRA-55
"
assert_eq "no helpers and no re-source: aborts with 127" 127 "$T_RC"
assert_contains "  ... and says the helpers are unavailable" "helpers unavailable" "$T_ERR"
assert_contains "  ... and names what it tried" "does-not-exist.sh" "$T_ERR"
assert_contains "  ... and says it stopped before side effects" "before side effects" "$T_ERR"

# The same guard must RECOVER when re-sourcing does work -- otherwise every
# long-running shell would have to be restarted by hand.
t_run env "CC_FUNCTIONS_SH=$CC_FUNCTIONS_UNDER_TEST" "CC_LAND_CHILD_SH=$FIX/land.sh" bash -c "
    source '$CC_FUNCTIONS_UNDER_TEST'
    unset -f __cc_die
    cc-land ok
"
assert_eq "a stale snapshot re-sources and proceeds" 0 "$T_RC"
assert_contains "  ... reaching the delegated script" "[ok]" "$T_OUT"

# =========================================================================
# 5. The company tmux session name -- one point of truth, read by cc,
#    cc-branch and cc-land's reclaim gate. __cc_company_tmux_ensure is
#    deliberately NOT exercised: it would create or adopt the real "company"
#    session this suite may be running inside.
# =========================================================================
assert_eq "the company session name is 'company'" "company" "$(__cc_company_tmux_session)"

if command -v tmux >/dev/null 2>&1; then
    t_run bash -c "
        source '$CC_FUNCTIONS_UNDER_TEST'
        __cc_company_tmux_session() { printf '%s' 'cc-absent-session-fixture'; }
        __cc_company_tmux_exists
    "
    assert_ne "a session that does not exist reports absent" 0 "$T_RC"
    assert_eq "  ... quietly (tmux's own error is suppressed)" "" "$T_ERR"
else
    t_diag "tmux not installed - skipping the has-session probe"
fi

t_finish
