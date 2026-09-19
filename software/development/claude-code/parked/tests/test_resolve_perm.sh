#!/usr/bin/env bash
# Description: Table tests for __cc_resolve_perm — role to permission mode, the env override, and the settings-default fall-through the wrappers must not out-vote.
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

t_begin "__cc_resolve_perm"

t_sandbox_env || { t_fail "sandbox env"; t_finish; exit 1; }
FIX=$(t_tmpdir) || { t_fail "fixture dir"; t_finish; exit 1; }
REAL_PATH="$PATH"

cat > "$FIX/policy.json" <<'JSON'
{
  "version": 1,
  "roles": {
    "stated":   { "model": "opus", "permission_mode": "acceptEdits" },
    "silent":   { "model": "opus" },
    "emptyStr": { "model": "opus", "permission_mode": "" }
  }
}
JSON

# =========================================================================
# 1. THE FALL-THROUGH. This is the steady state on every machine today: the
#    checked-in model-policy.json states permission_mode for no role at all,
#    so every cc-* launch takes this branch.
#
#    The wire format matters as much as the value. __cc_resolve_perm prints
#    "<value>\t<source>", and __cc_perm_prepare splits it with
#        value=${spec%%$'\t'*}   source=${spec##*$'\t'}
#    On the fall-through the VALUE IS THE EMPTY STRING, so the line is a bare
#    leading tab followed by "settings-default". Drop that tab -- print just
#    "settings-default" -- and both parameter expansions return
#    "settings-default", which __cc_perm_stage then rejects as not a permission
#    mode claude accepts, aborting EVERY launch. The empty first field is
#    load-bearing, which is exactly why it is asserted byte-for-byte here.
# =========================================================================
export CC_MODEL_POLICY="$FIX/policy.json"

t_run __cc_resolve_perm silent
assert_eq "role with no permission_mode falls through" $'\tsettings-default' "$T_OUT"
assert_eq "fall-through returns 0" 0 "$T_RC"
assert_eq "  ... value field is empty" "" "${T_OUT%%$'\t'*}"
assert_eq "  ... source field is settings-default" "settings-default" "${T_OUT##*$'\t'}"

# An explicitly empty string in the policy is the same as saying nothing.
t_run __cc_resolve_perm emptyStr
assert_eq "empty permission_mode is treated as unstated" $'\tsettings-default' "$T_OUT"

t_run __cc_resolve_perm role-that-does-not-exist
assert_eq "absent role falls through rather than refusing" $'\tsettings-default' "$T_OUT"
assert_eq "absent role returns 0" 0 "$T_RC"

# =========================================================================
# 2. The deliberate asymmetry with __cc_resolve_model, spelled out in the
#    source: a missing policy is FATAL for the model (falling through lands on
#    Claude Code's moving "Default" and costs money) and NON-FATAL here
#    (falling through lands on an explicit value in a tracked settings file,
#    which is the intended outcome).
# =========================================================================
export CC_MODEL_POLICY="$FIX/does-not-exist.json"
t_run __cc_resolve_perm silent
assert_eq "missing policy file is non-fatal" 0 "$T_RC"
assert_eq "missing policy file falls through" $'\tsettings-default' "$T_OUT"

unset CC_MODEL_POLICY
t_run __cc_resolve_perm silent
assert_eq "no policy discoverable is non-fatal" 0 "$T_RC"
assert_eq "no policy discoverable falls through" $'\tsettings-default' "$T_OUT"

# Same input, opposite verdict from the model resolver. Asserting the contrast
# directly, so a future edit that "unifies" the two resolvers fails here with
# the reason attached rather than quietly making both refuse or both fall back.
if command -v jq >/dev/null 2>&1; then
    t_run __cc_resolve_model silent
    assert_ne "__cc_resolve_model refuses where __cc_resolve_perm falls through" 0 "$T_RC"
fi

# =========================================================================
# 3. jq absent. A machine without jq must still launch: permission mode drops
#    to the settings default, while the model resolver refuses outright.
# =========================================================================
MINPATH=$(t_minimal_path mktemp cat rm readlink sed dirname grep tr date) \
    || t_fail "could not build a jq-free PATH"
if [ -n "${MINPATH:-}" ]; then
    export CC_MODEL_POLICY="$FIX/policy.json"
    PATH="$MINPATH" t_run __cc_resolve_perm stated
    assert_eq "without jq, a stated permission_mode is unreadable -> fall-through" \
        $'\tsettings-default' "$T_OUT"
    assert_eq "without jq, perm resolution still returns 0" 0 "$T_RC"

    PATH="$MINPATH" t_run __cc_resolve_model stated
    assert_ne "without jq, model resolution refuses" 0 "$T_RC"
    assert_contains "without jq, the model refusal says jq is required" "jq" "$T_ERR"
    PATH="$REAL_PATH"
fi

# =========================================================================
# 4. Overrides, in precedence order: $CC_PERM_MODE beats the policy, and the
#    policy beats the fall-through.
# =========================================================================
export CC_MODEL_POLICY="$FIX/policy.json"

t_run __cc_resolve_perm stated
assert_eq "policy permission_mode is honoured" $'acceptEdits\tpolicy:stated' "$T_OUT"

CC_PERM_MODE=plan t_run __cc_resolve_perm stated
assert_eq "CC_PERM_MODE beats the policy" $'plan\tenv' "$T_OUT"

CC_PERM_MODE=plan t_run __cc_resolve_perm silent
assert_eq "CC_PERM_MODE beats the fall-through" $'plan\tenv' "$T_OUT"

# The resolver does NOT validate -- __cc_perm_stage does, against `claude
# --help`. Pinning the split of responsibility: an invalid value must survive
# resolution intact so the stager can name it in its error message.
CC_PERM_MODE='not-a-real-mode' t_run __cc_resolve_perm silent
assert_eq "the resolver does not validate the value" $'not-a-real-mode\tenv' "$T_OUT"
assert_eq "  ... and does not refuse" 0 "$T_RC"

# =========================================================================
# 5. What the checked-in configuration actually does today.
#
#    A wrapper must not out-vote settings.json permissions.defaultMode -- that
#    file is a versioned, reviewed choice, and the wrappers used to append
#    --dangerously-skip-permissions unconditionally, silently overriding it for
#    every session the company launches. The fix was to pass NO flag unless
#    someone stated an override. This asserts the state that fix produced.
#
#    If this fails because a role gained a permission_mode, that is not
#    automatically wrong -- but it means that role now overrides
#    permissions.defaultMode for every launch, with no diff at the settings
#    file. Confirm it was intended, then update this test.
# =========================================================================
export CC_MODEL_POLICY="$MODULE_DIR/canonical/model-policy.json"
for role in explore build ea branched-worker; do
    t_run __cc_resolve_perm "$role"
    assert_eq "checked-in policy leaves role '$role' on the settings default" \
        $'\tsettings-default' "$T_OUT"
done

# The fall-through has to land on something real, or "no flag passed" means
# whatever Claude Code's own built-in default happens to be that week.
if command -v jq >/dev/null 2>&1; then
    default_mode=$(jq -r '.permissions.defaultMode // ""' "$MODULE_DIR/canonical/settings.json" 2>/dev/null)
    assert_ne "canonical/settings.json states permissions.defaultMode" "" "$default_mode"
fi

t_finish
