#!/usr/bin/env bash
# Description: Tests for __cc_trust_effective and __cc_trust_register — the ~/.claude.json workspace-trust pre-registration that lets an unattended child reach its prompt, and the never-fatal, never-clobbering contract it is written under.
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

t_begin "__cc_trust_effective / __cc_trust_register"

for dep in jq git; do
    command -v "$dep" >/dev/null 2>&1 || { t_fail "$dep is available"; t_finish; exit $?; }
done

# MANDATORY, and a safety device: __cc_trust_register WRITES $HOME/.claude.json.
# Without an overridden HOME this file would rewrite the operator's live Claude
# Code config on every run.
t_sandbox_env || { t_fail "sandbox env"; t_finish; exit 1; }
CFG="$HOME/.claude.json"

# phys <path> -- the physical path, matching the `pwd -P` the subject uses.
phys() { (cd "$1" 2>/dev/null && pwd -P); }

# cfg_write <json> -- lay down a fresh ~/.claude.json.
cfg_write() { printf '%s\n' "$1" > "$CFG"; }

# trusted_in_cfg <dir> -- what the config now says about dir.
trusted_in_cfg() {
    jq -r --arg p "$1" '.projects[$p].hasTrustDialogAccepted // false' "$CFG" 2>/dev/null
}

# =========================================================================
# 1. __cc_trust_effective -- mirrors claude's own lookup.
# =========================================================================
H=$(phys "$HOME")
mkdir -p "$HOME/plain/sub"
PLAIN=$(phys "$HOME/plain"); PLAIN_SUB=$(phys "$HOME/plain/sub")

cfg_write '{"projects":{}}'
assert_rc "untrusted directory is not effective" 1 __cc_trust_effective "$PLAIN"

cfg_write "$(jq -n --arg p "$PLAIN" '{projects:{($p):{hasTrustDialogAccepted:true}}}')"
assert_rc "an exactly-trusted directory is effective" 0 __cc_trust_effective "$PLAIN"

# The upward walk, with no git root to stop it.
assert_rc "a subdir inherits trust from an ancestor" 0 __cc_trust_effective "$PLAIN_SUB"

cfg_write "$(jq -n --arg p "$PLAIN" '{projects:{($p):{hasTrustDialogAccepted:false}}}')"
assert_rc "hasTrustDialogAccepted:false is not trust" 1 __cc_trust_effective "$PLAIN"

rm -f "$CFG"
assert_rc "a missing ~/.claude.json is not trust" 1 __cc_trust_effective "$PLAIN"

# THE WORKTREE CASE, and the reason cc-branch/cc-explore must pre-register at
# all. The walk stops at the enclosing git root, so trusting $HOME does NOT
# reach into a worktree under it. If this ever inherited, every brand-new
# worktree would look already-trusted, pre-registration would be skipped, and
# the unattended child would sit on the trust dialog forever -- silently,
# because nothing else reports it.
git init -q "$HOME/wt" 2>/dev/null
mkdir -p "$HOME/wt/deep"
WT=$(phys "$HOME/wt"); WT_DEEP=$(phys "$HOME/wt/deep")
cfg_write "$(jq -n --arg p "$H" '{projects:{($p):{hasTrustDialogAccepted:true}}}')"
assert_rc "trusting \$HOME does NOT cover a git worktree beneath it" 1 __cc_trust_effective "$WT"
assert_rc "  ... nor a subdir inside that worktree" 1 __cc_trust_effective "$WT_DEEP"

cfg_write "$(jq -n --arg p "$WT" '{projects:{($p):{hasTrustDialogAccepted:true}}}')"
assert_rc "a trusted repo root IS effective at its root" 0 __cc_trust_effective "$WT"
assert_rc "  ... and for a subdir inside it" 0 __cc_trust_effective "$WT_DEEP"

# =========================================================================
# 2. __cc_trust_register -- the write path.
# =========================================================================
cfg_write '{"projects":{},"someOtherKey":"must survive","numberOfStartups":41}'
before_other=$(jq -c '{someOtherKey,numberOfStartups}' "$CFG")

t_run __cc_trust_register "$WT"
assert_eq "register returns 0" 0 "$T_RC"
assert_eq "the directory is now trusted" "true" "$(trusted_in_cfg "$WT")"
assert_contains "it says what it did" "pre-registered" "$T_ERR"

# ~/.claude.json is owned and rewritten by every running claude process. A
# register that dropped unrelated keys would silently destroy live session
# state -- the failure the source calls out as not recoverable.
assert_rc "the rewritten config is still valid JSON" 0 jq -e . "$CFG"
assert_eq "unrelated top-level keys survive the rewrite" \
    "$before_other" "$(jq -c '{someOtherKey,numberOfStartups}' "$CFG")"

# A sibling project entry must not be collateral damage.
cfg_write "$(jq -n --arg a "$PLAIN" '{projects:{($a):{hasTrustDialogAccepted:true,history:["keep me"]}}}')"
__cc_trust_register "$WT" 2>/dev/null
assert_eq "a sibling project entry is preserved" "true" "$(trusted_in_cfg "$PLAIN")"
assert_eq "  ... including its unrelated sub-keys" "keep me" \
    "$(jq -r --arg p "$PLAIN" '.projects[$p].history[0]' "$CFG")"
assert_eq "  ... while the new entry is added" "true" "$(trusted_in_cfg "$WT")"

# Merging, not replacing: an existing entry keeps the keys claude put there.
cfg_write "$(jq -n --arg p "$WT" '{projects:{($p):{hasTrustDialogAccepted:false,lastCost:1.25}}}')"
__cc_trust_register "$WT" 2>/dev/null
assert_eq "an existing entry is flipped to trusted" "true" "$(trusted_in_cfg "$WT")"
assert_eq "  ... without losing its other fields" "1.25" \
    "$(jq -r --arg p "$WT" '.projects[$p].lastCost' "$CFG")"

# "Does nothing at all when trust is already effective" is a load-bearing claim:
# it is what keeps this extra writer off the file in the steady state, which is
# every launch after the first in a given worktree.
cfg_write "$(jq -n --arg p "$WT" '{projects:{($p):{hasTrustDialogAccepted:true}}}')"
snapshot=$(cat "$CFG")
t_run __cc_trust_register "$WT"
assert_eq "an already-trusted dir is a no-op: returns 0" 0 "$T_RC"
assert_eq "an already-trusted dir is a no-op: file byte-identical" "$snapshot" "$(cat "$CFG")"
assert_eq "an already-trusted dir is a no-op: says nothing" "" "$T_ERR"

# The key must be the PHYSICAL path: claude looks it up by the path it resolves
# the workspace to, so a symlinked or relative spelling would register a key
# nothing ever matches -- trust that reads as applied but is not.
cfg_write '{"projects":{}}'
ln -sfn "$WT" "$HOME/wt-link"
__cc_trust_register "$HOME/wt-link" 2>/dev/null
assert_eq "a symlinked path registers under the physical path" "true" "$(trusted_in_cfg "$WT")"
assert_eq "  ... and not under the symlink spelling" "false" "$(trusted_in_cfg "$HOME/wt-link")"

cfg_write '{"projects":{}}'
( cd "$HOME" && __cc_trust_register "wt" ) 2>/dev/null
assert_eq "a relative path registers under the absolute path" "true" "$(trusted_in_cfg "$WT")"

# =========================================================================
# 3. Never fatal. Every failure path WARNs and returns 0: a session that stops
#    on a trust dialog is recoverable by a human, an aborted spawn or a
#    clobbered ~/.claude.json is not.
# =========================================================================
cfg_write '{"projects":{}}'
t_run __cc_trust_register "$HOME/does-not-exist"
assert_eq "an unresolvable directory returns 0" 0 "$T_RC"
assert_contains "  ... and warns" "WARNING" "$T_ERR"
assert_eq "  ... and writes nothing" '{"projects":{}}' "$(cat "$CFG")"

rm -f "$CFG"
t_run __cc_trust_register "$WT"
assert_eq "a missing ~/.claude.json returns 0" 0 "$T_RC"
assert_contains "  ... and warns about the missing config" "not found" "$T_ERR"
assert_rc "  ... and does not create one" 1 test -e "$CFG"

# THE CLOBBER GUARD. jq cannot parse this, so the candidate is never verified
# and the original must stay exactly where it is. A register that truncated
# here would destroy the file every running session depends on.
cfg_write 'this is not json {{{'
corrupt_before=$(cat "$CFG")
t_run __cc_trust_register "$WT"
assert_eq "an unparseable config returns 0" 0 "$T_RC"
assert_contains "  ... and warns it could not pre-register" "could not pre-register" "$T_ERR"
assert_eq "  ... and leaves the original file byte-identical" "$corrupt_before" "$(cat "$CFG")"

# No debris. The temp file is created BESIDE the config (same filesystem, for
# the atomic rename), so a leaked one sits in the operator's ~ forever.
shopt -s nullglob
leftovers=("$HOME"/.claude.json.cc-trust.*)
shopt -u nullglob
assert_eq "no .cc-trust temp files are left behind" 0 "${#leftovers[@]}"

# jq missing is a warn-and-continue, not a refusal: the spawn must still happen.
cfg_write '{"projects":{}}'
MINPATH=$(t_minimal_path bash cat git mktemp rm mv chmod dirname readlink flock) || \
    { t_fail "minimal PATH"; t_finish; exit 1; }
t_run env "PATH=$MINPATH" bash -c "
    source '$CC_FUNCTIONS_UNDER_TEST'
    __cc_trust_register '$WT'
"
assert_eq "no jq: returns 0 rather than aborting the spawn" 0 "$T_RC"
assert_contains "no jq: warns it cannot pre-register" "jq not installed" "$T_ERR"
assert_contains "no jq: names the consequence for the operator" "trust dialog" "$T_ERR"

t_finish
