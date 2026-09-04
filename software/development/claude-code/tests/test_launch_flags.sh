#!/usr/bin/env bash
# Description: Tests for the launch-string renderers (__cc_model_flag_str, __cc_perm_flag_str), the accepted-mode probe (__cc_perm_modes), policy discovery (__cc_model_policy_path), and session identity (__cc_mint_session_id, __cc_repo_root).
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, jq, git, canonical/shell/cc-functions.sh

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

t_begin "launch flags, policy discovery, session identity"

for dep in jq git; do
    command -v "$dep" >/dev/null 2>&1 || { t_fail "$dep is available"; t_finish; exit $?; }
done
t_sandbox_env || { t_fail "sandbox env"; t_finish; exit 1; }
FIX=$(t_tmpdir) || { t_fail "fixture dir"; t_finish; exit 1; }

cat > "$FIX/policy.json" <<'JSON'
{ "version": 1, "roles": {
    "pinned":   { "model": "opus", "permission_mode": "plan" },
    "floating": { "model": "track-latest" } } }
JSON

# =========================================================================
# 1. The flag renderers. cc and cc-branch build a tmux command STRING, not an
#    argv array, so whatever these print is RE-PARSED by a shell. The contract
#    is therefore not "looks right" but "survives re-parsing as the same
#    words". Each case is asserted by evaluating the fragment back into $@,
#    which is exactly what tmux will do to it.
#
#    A value like `opus; rm -rf ~` reaching the launch string unquoted is
#    command injection into a window the operator did not type into. %q is the
#    defence; these assertions are what stands over it.
# =========================================================================

# frag_words <fragment> -- re-parse a rendered fragment and print one word per
# line, so a fragment that splits into the wrong number of words is visible.
frag_words() { eval "set -- $1"; printf '%s\n' "$@"; }
frag_count() { eval "set -- $1"; printf '%s' "$#"; }

declare -a __cc_model_args=(--model opus)
assert_eq "model fragment renders the flag and value" " --model opus" "$(__cc_model_flag_str)"
assert_eq "  ... re-parsing yields exactly two words" "2" "$(frag_count "$(__cc_model_flag_str)")"

# track-latest: __cc_model_prepare empties the array, and the renderer must
# print NOTHING -- not " " and not "--model track-latest", which claude would
# reject as a model id.
__cc_model_args=()
assert_eq "an empty model array renders the empty string" "" "$(__cc_model_flag_str)"
assert_rc "  ... and the renderer still returns 0" 0 __cc_model_flag_str

# The payload writes to a path inside the sandbox, and the run ends by asserting
# that path was never created. Word-counting alone is NOT sufficient and was
# measured not to be: against a `printf %s` mutant, `eval "set -- --model a; touch p"`
# splits at the ';', so $# is still 2 -- the assertion passes while the eval
# actually RUNS the payload. The file-existence check is the assertion that
# bites, because it observes the consequence rather than the shape.
PWNED="$FIX/pwned"

inject_case() {  # inject_case <label> <array-name> <flag> <hostile value>
    local label="$1" arr="$2" flag="$3" val="$4" frag
    if [ "$arr" = model ]; then
        __cc_model_args=("$flag" "$val"); frag=$(__cc_model_flag_str)
    else
        __cc_perm_args=("$flag" "$val");  frag=$(__cc_perm_flag_str)
    fi
    assert_eq "$label: fragment re-parses to two words" "2" "$(frag_count "$frag")"
    assert_eq "$label: the value survives verbatim" "$val" "$(frag_words "$frag" | sed -n 2p)"
}

for spec in model:--model perm:--permission-mode; do
    arr=${spec%%:*}; flag=${spec#*:}
    inject_case "$arr value with a space"        "$arr" "$flag" "val 5"
    inject_case "$arr value with a semicolon"    "$arr" "$flag" "val; touch $PWNED"
    inject_case "$arr value with a command sub"  "$arr" "$flag" "val\$(touch $PWNED)"
    inject_case "$arr value with backticks"      "$arr" "$flag" "val\`touch $PWNED\`"
    inject_case "$arr value with a single quote" "$arr" "$flag" "val'x"
    inject_case "$arr value with a double quote" "$arr" "$flag" 'val"x'
done

# THE ASSERTION THAT MATTERS: re-parsing every hostile fragment above executed
# nothing. Under a renderer that stops quoting, this is the one that goes red.
assert_rc "no injected payload was ever executed" 1 test -e "$PWNED"

declare -a __cc_perm_args=(--permission-mode plan)
assert_eq "perm fragment renders the flag and value" " --permission-mode plan" "$(__cc_perm_flag_str)"
__cc_perm_args=()
assert_eq "the settings-default path renders the empty string" "" "$(__cc_perm_flag_str)"

# End to end through the preparer, which is how the entry points reach these.
export CC_MODEL_POLICY="$FIX/policy.json"
declare __cc_model_value __cc_model_source
__cc_model_prepare pinned 2>/dev/null
assert_eq "prepared pinned role renders its flag" " --model opus" "$(__cc_model_flag_str)"
__cc_model_prepare floating 2>/dev/null
assert_eq "prepared track-latest role renders nothing" "" "$(__cc_model_flag_str)"

# =========================================================================
# 2. __cc_perm_modes -- the validity set __cc_perm_stage gates on. A list that
#    is wrong in either direction is a half-spawn: too narrow refuses a value
#    that works, too wide admits one that kills claude inside a fresh window.
# =========================================================================
MODES=$(__cc_perm_modes)
assert_ne "the accepted-mode list is not empty" "" "$MODES"
for m in bypassPermissions plan acceptEdits; do
    assert_contains "accepted modes include '$m'" "$m" " $MODES "
done
# "Default" is a Claude Code UI label, not a --permission-mode value; admitting
# it would let a policy stage a flag the installed claude rejects.
assert_not_contains "accepted modes do NOT include 'Default'" " Default " " $MODES "

# The fallback is only reachable with no claude on PATH, which is the case a
# hardcoded list exists for. Without removing it from PATH the branch is dead
# code on a configured machine and would never be tested.
NOCLAUDE=$(t_minimal_path bash tr grep printf) || { t_fail "minimal PATH"; t_finish; exit 1; }
t_run env "PATH=$NOCLAUDE" bash -c "source '$CC_FUNCTIONS_UNDER_TEST'; __cc_perm_modes"
assert_eq "no claude on PATH: the fallback list is used" \
    "acceptEdits auto bypassPermissions manual dontAsk plan" "$T_OUT"
assert_eq "no claude on PATH: still returns 0" 0 "$T_RC"

# =========================================================================
# 3. __cc_model_policy_path -- three routes, in order. Route 3 exists so a
#    session can find the policy BEFORE configure.sh has been re-run to add
#    the symlink; without it launches start refusing mid-flight.
# =========================================================================
mkdir -p "$HOME/.claude" "$FIX/repo/shell"
cp "$FIX/policy.json" "$FIX/repo/model-policy.json"
cp "$CC_FUNCTIONS_UNDER_TEST" "$FIX/repo/shell/cc-functions.sh"

export CC_MODEL_POLICY="$FIX/policy.json"
assert_eq "route 1: \$CC_MODEL_POLICY wins" "$FIX/policy.json" "$(__cc_model_policy_path)"

# A typo'd override must REFUSE, not quietly fall through to ~/.claude. Falling
# through would run the session under a policy nobody pointed at, which is the
# silent-wrong-model class the whole refusal contract exists for.
printf '{"roles":{}}' > "$HOME/.claude/model-policy.json"
export CC_MODEL_POLICY="$FIX/nope.json"
t_run __cc_model_policy_path
assert_ne "route 1 with a missing file refuses" 0 "$T_RC"
assert_eq "  ... and does NOT fall through to ~/.claude" "" "$T_OUT"

unset CC_MODEL_POLICY
assert_eq "route 2: ~/.claude/model-policy.json" \
    "$HOME/.claude/model-policy.json" "$(__cc_model_policy_path)"

rm -f "$HOME/.claude/model-policy.json"
ln -sfn "$FIX/repo/shell/cc-functions.sh" "$HOME/.claude/cc-functions.sh"
assert_eq "route 3: the repo copy beside the live symlink" \
    "$FIX/repo/model-policy.json" "$(__cc_model_policy_path)"

rm -f "$FIX/repo/model-policy.json"
t_run __cc_model_policy_path
assert_ne "no policy discoverable: refuses" 0 "$T_RC"
assert_eq "no policy discoverable: prints nothing" "" "$T_OUT"

# =========================================================================
# 4. __cc_mint_session_id -- this value names the tree slot file, stamps every
#    event, and is asserted against by cc-plane-sync. A wrong shape does not
#    fail loudly; it fragments the topology into orphan slots.
# =========================================================================
SID=$(__cc_mint_session_id)
assert_eq "session id is 22 characters" 22 "${#SID}"
case "$SID" in
    *[!0-9a-f]*) t_fail "session id is lowercase hex only" "got: $SID" ;;
    *)           t_pass "session id is lowercase hex only" ;;
esac
assert_eq "session id carries no newline" "$SID" "$(printf '%s' "$SID" | tr -d '\n')"
assert_ne "two mints differ" "$SID" "$(__cc_mint_session_id)"

# The helpers are sourced into scripts running under `set -o pipefail`, and the
# mint is a pipeline ending in `head -c`, which exits early and SIGPIPEs its
# producer. If that surfaced as a non-zero status the caller would treat a
# perfectly good id as a failure.
t_run bash -c "set -o pipefail; source '$CC_FUNCTIONS_UNDER_TEST'; __cc_mint_session_id"
assert_eq "minting returns 0 under pipefail (head -c SIGPIPEs its producer)" 0 "$T_RC"
assert_eq "  ... and still yields 22 characters" 22 "${#T_OUT}"

# The uuidgen-less fallback. Rare on Ubuntu, which is exactly why it rots
# unless something exercises it.
NOUUID=$(t_minimal_path bash head od tr) || { t_fail "minimal PATH"; t_finish; exit 1; }
t_run env "PATH=$NOUUID" bash -c "source '$CC_FUNCTIONS_UNDER_TEST'; __cc_mint_session_id"
assert_eq "no uuidgen: the /dev/urandom fallback returns 0" 0 "$T_RC"
assert_eq "no uuidgen: still 22 characters" 22 "${#T_OUT}"
case "$T_OUT" in
    *[!0-9a-f]*) t_fail "no uuidgen: still lowercase hex only" "got: $T_OUT" ;;
    *)           t_pass "no uuidgen: still lowercase hex only" ;;
esac

# =========================================================================
# 5. __cc_repo_root -- every entry point derives the worktree from this.
# =========================================================================
git init -q "$FIX/r" 2>/dev/null
mkdir -p "$FIX/r/a/b"
RROOT=$(cd "$FIX/r" && pwd -P)
assert_eq "repo root from the root itself" "$RROOT" "$(cd "$FIX/r" && __cc_repo_root)"
assert_eq "repo root from a nested subdir"  "$RROOT" "$(cd "$FIX/r/a/b" && __cc_repo_root)"

mkdir -p "$FIX/notrepo"
t_run bash -c "cd '$FIX/notrepo' && source '$CC_FUNCTIONS_UNDER_TEST' && __cc_repo_root"
assert_ne "outside a repo: non-zero" 0 "$T_RC"
assert_eq "outside a repo: prints nothing" "" "$T_OUT"
assert_eq "outside a repo: says nothing on stderr" "" "$T_ERR"

t_finish
