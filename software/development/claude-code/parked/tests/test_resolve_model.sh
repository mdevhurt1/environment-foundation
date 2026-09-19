#!/usr/bin/env bash
# Description: Table tests for __cc_resolve_model — role to model, the env override, and every refusal path including the "Default is a moving referent" case.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, jq, canonical/shell/cc-functions.sh

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

# The file under test is a variable so tests/mutate.sh can point the suite at a
# deliberately broken copy and confirm the assertions actually bite. It defaults
# to the checked-in file, so an ordinary run needs no environment at all.
CC_FUNCTIONS_UNDER_TEST="${CC_FUNCTIONS_UNDER_TEST:-$MODULE_DIR/canonical/shell/cc-functions.sh}"
# shellcheck source=../canonical/shell/cc-functions.sh
# shellcheck disable=SC1091
source "$CC_FUNCTIONS_UNDER_TEST"

t_begin "__cc_resolve_model"

if ! command -v jq >/dev/null 2>&1; then
    t_fail "jq is available" "jq is a hard dependency of __cc_resolve_model (configure.sh require_command jq)"
    t_finish; exit $?
fi

t_sandbox_env || { t_fail "sandbox env"; t_finish; exit 1; }
FIX=$(t_tmpdir) || { t_fail "fixture dir"; t_finish; exit 1; }

# ---- fixtures ------------------------------------------------------------
# Written here rather than checked in as files: the whole point of a table test
# is that the input sits beside the expectation.
cat > "$FIX/policy.json" <<'JSON'
{
  "version": 1,
  "roles": {
    "pinned":   { "model": "opus" },
    "floating": { "model": "track-latest" },
    "blank":    { "model": "" },
    "noModel":  { "note": "role exists but states no model" }
  }
}
JSON
printf 'not json at all {{{' > "$FIX/broken.json"

# =========================================================================
# 1. $CC_MODEL beats everything and reports source=env
# =========================================================================
export CC_MODEL_POLICY="$FIX/policy.json"

CC_MODEL=claude-opus-5 t_run __cc_resolve_model pinned
assert_eq "CC_MODEL overrides the policy" $'claude-opus-5\tenv' "$T_OUT"
assert_eq "CC_MODEL override succeeds" 0 "$T_RC"

# The escape hatch named in every refusal message must itself work.
CC_MODEL=track-latest t_run __cc_resolve_model no-such-role-anywhere
assert_eq "CC_MODEL=track-latest rescues an unknown role" $'track-latest\tenv' "$T_OUT"
assert_eq "  ... and returns 0" 0 "$T_RC"

# =========================================================================
# 2. Policy lookup, both shapes of value
# =========================================================================
t_run __cc_resolve_model pinned
assert_eq "pinned role resolves to its model" $'opus\tpolicy:pinned' "$T_OUT"
assert_eq "pinned role returns 0" 0 "$T_RC"

# THE MOVING-REFERENT CASE. "track-latest" is not a model id; it is the policy
# stating, on the record, that this role declines to pin. __cc_resolve_model
# must hand it back UNCHANGED and successfully -- it is __cc_model_prepare that
# translates it into "pass no --model flag". If this resolver ever "helpfully"
# expanded track-latest to a concrete id, the policy's deliberate opt-out would
# become a pin that nobody wrote down; if it ever rejected it, four roles in the
# checked-in policy would stop launching.
t_run __cc_resolve_model floating
assert_eq "track-latest is passed through verbatim" $'track-latest\tpolicy:floating' "$T_OUT"
assert_eq "track-latest is not an error" 0 "$T_RC"

# =========================================================================
# 3. Refusal paths. The contract is: refuse LOUDLY rather than fall through to
#    Claude Code's "Default", which is a moving referent that silently
#    reassigns a session to whatever model is most capable on the account.
#    Every one of these must (a) return non-zero and (b) print NOTHING on
#    stdout -- callers do `spec=$(__cc_resolve_model r) || return 1` and then
#    split $spec on a tab, so a refusal that leaked a partial line would be
#    parsed as a model.
# =========================================================================
refusal_case() {  # refusal_case <label> <role>
    local label="$1" role="$2"
    t_run __cc_resolve_model "$role"
    assert_ne "$label refuses (non-zero)" 0 "$T_RC"
    assert_eq "$label prints nothing on stdout" "" "$T_OUT"
    assert_contains "$label names the CC_MODEL escape hatch on stderr" "CC_MODEL=" "$T_ERR"
}

refusal_case "absent role" "role-that-does-not-exist"
refusal_case "role with an empty model" "blank"
refusal_case "role with no model key" "noModel"

# Policy path points at a file that is not there.
export CC_MODEL_POLICY="$FIX/nope.json"
refusal_case "CC_MODEL_POLICY pointing at a missing file" "pinned"

# Policy file exists but is not JSON: jq fails, .model comes back empty.
export CC_MODEL_POLICY="$FIX/broken.json"
refusal_case "unparseable policy file" "pinned"

# No policy discoverable at all: CC_MODEL_POLICY unset, and $HOME is the
# sandbox dir from t_sandbox_env, so neither ~/.claude/model-policy.json nor
# the repo copy beside ~/.claude/cc-functions.sh exists.
unset CC_MODEL_POLICY
refusal_case "no policy discoverable" "pinned"
t_run __cc_resolve_model pinned
assert_contains "no-policy refusal says where it looked" "model policy" "$T_ERR"

# =========================================================================
# 4. The checked-in policy actually serves every role the wrappers ask for.
#
# The role list is a CONSTANT DECLARED HERE and is deliberately NOT derived by
# grepping cc-functions.sh: a guard that takes its work-list from the guarded
# artifact reproduces that artifact's own omissions. Same reasoning as the
# disclosure gate in scripts/doctor.sh check 2c.
#
# Reachable launch roles, as of 2026-09-03:
#   explore          cc-explore, and cc-continue resuming an exploration session
#   build            cc-build,   and cc-continue resuming a build session
#   ea               cc (the command-center / EA session)
#   branched-worker  cc-branch,  and cc-continue resuming a branched session
# The four unmechanized roles in the policy (review-lane, cheap-mechanical,
# subagent-default, scheduled) are intentionally absent: nothing resolves them
# yet, so asserting on them would test the policy against itself.
# =========================================================================
export CC_MODEL_POLICY="$MODULE_DIR/canonical/model-policy.json"
for role in explore build ea branched-worker; do
    t_run __cc_resolve_model "$role"
    assert_eq "checked-in policy serves role '$role'" 0 "$T_RC"
    assert_ne "role '$role' resolves to a non-empty model" "" "${T_OUT%%$'\t'*}"
    assert_eq "role '$role' reports source=policy:$role" "policy:$role" "${T_OUT##*$'\t'}"
done

t_finish
