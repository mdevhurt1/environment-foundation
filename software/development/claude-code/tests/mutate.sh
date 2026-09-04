#!/usr/bin/env bash
# Description: Mutation check — breaks the shell subjects (cc-functions.sh, statusline-command.sh, doctor.sh, configure.sh, cc-plane-sync.sh, the outbound guard, the event emitter and the cc-scrub git hooks) in known ways and asserts the test suite catches each one, so that a green run means something.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, jq, python3, coreutils, the tests in this directory
# Idempotent. Never modifies a checked-in file — every mutation is applied to a
# throwaway copy under $TMPDIR.

set -uo pipefail   # NOT -e: every mutation must be attempted and reported.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MODULE_DIR/../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

# Two subjects now, not one. INFRA-45 moved half the .cc-mode fix into the
# READER -- the statusline stopped sourcing the file and started parsing it --
# and a mutation table that can only reach cc-functions.sh would leave that
# half unmutated, which is the same as leaving it untested. Each mutation
# names its subject; the test file it must break is invoked with the matching
# *_UNDER_TEST variable so the suite loads the mutant rather than the original.
declare -A SUBJECTS=(
    [functions]="$MODULE_DIR/canonical/shell/cc-functions.sh"
    [statusline]="$MODULE_DIR/canonical/statusline-command.sh"
    [doctor]="$MODULE_DIR/scripts/doctor.sh"
    [configure]="$MODULE_DIR/scripts/configure.sh"
    [planesync]="$MODULE_DIR/canonical/shell/cc-plane-sync.sh"
    [guard]="$MODULE_DIR/canonical/shell/cc-outbound-guard.sh"
    [emit]="$MODULE_DIR/canonical/shell/cc-event-emit.sh"
    [prehook]="$MODULE_DIR/canonical/hooks/pre-commit.sh"
    [pushhook]="$MODULE_DIR/canonical/hooks/pre-push.sh"
)
declare -A SUBJECT_ENV=(
    [functions]=CC_FUNCTIONS_UNDER_TEST
    [statusline]=STATUSLINE_UNDER_TEST
    [doctor]=DOCTOR_UNDER_TEST
    [configure]=CONFIGURE_UNDER_TEST
    [planesync]=PLANE_SYNC_UNDER_TEST
    [guard]=GUARD_UNDER_TEST
    [emit]=EMIT_UNDER_TEST
    [prehook]=PRECOMMIT_UNDER_TEST
    [pushhook]=PREPUSH_UNDER_TEST
)

# A test that has never been seen to fail proves nothing. Each mutation below
# breaks ONE behaviour the suite claims to protect, and names the test file that
# must go red. Three outcomes:
#
#   CAUGHT    the named test file failed. Good.
#   SURVIVED  the test file still passed. That is a GAP IN THE TESTS, reported
#             as a failure of this script, not as a pass.
#   STALE     the code no longer contains the text this mutation edits, so the
#             mutation tested nothing. Also a failure: a mutation table that
#             quietly stops applying is the same as no mutation table.
#
# Patterns are held in quoted heredocs rather than in a one-line table so the
# before/after reads as the actual code, with no escaping layer to get wrong.

declare -a M_LABEL M_TEST M_FROM M_TO M_SUBJ
# add_mut <label> <test-file> <from> <to> [subject]   subject defaults to
# "functions"; the other value is "statusline".
add_mut() {
    M_LABEL+=("$1"); M_TEST+=("$2"); M_FROM+=("$3"); M_TO+=("$4")
    M_SUBJ+=("${5:-functions}")
}

# ---- __cc_resolve_model --------------------------------------------------

# The exact historical failure: a role that cannot be resolved falls through to
# Claude Code's "Default", which is a moving referent. No error, no diff, a
# different model. This is the mutation the whole refusal contract exists for.
add_mut "absent role silently resolves to Default" test_resolve_model.sh \
"$(cat <<'FROM'
.roles[$r].model // empty
FROM
)" "$(cat <<'TO'
.roles[$r].model // "Default"
TO
)"

add_mut "env override reports the wrong source" test_resolve_model.sh \
"$(cat <<'FROM'
        printf '%s\t%s\n' "$CC_MODEL" "env"
FROM
)" "$(cat <<'TO'
        printf '%s\t%s\n' "$CC_MODEL" "policy"
TO
)"

# ---- __cc_resolve_perm ---------------------------------------------------

# Drop the leading tab from the fall-through line. __cc_perm_prepare splits on
# that tab; without it the VALUE becomes "settings-default", which
# __cc_perm_stage rejects as not a permission mode claude accepts — aborting
# every launch on the machine. A one-character edit, catastrophic blast radius.
add_mut "fall-through loses its empty value field" test_resolve_perm.sh \
"$(cat <<'FROM'
    printf '\t%s\n' "settings-default"
FROM
)" "$(cat <<'TO'
    printf '%s\n' "settings-default"
TO
)"

# Turn the deliberate asymmetry with __cc_resolve_model into symmetry: refuse
# instead of falling through. Locks in the reasoning recorded in the source.
add_mut "missing policy becomes fatal for the permission mode" test_resolve_perm.sh \
"$(cat <<'FROM'
    if [ -n "$mode" ]; then
        printf '%s\t%s\n' "$mode" "policy:$role"
        return 0
    fi
FROM
)" "$(cat <<'TO'
    if [ -n "$mode" ]; then
        printf '%s\t%s\n' "$mode" "policy:$role"
        return 0
    fi
    return 1
TO
)"

# ---- __cc_write_mode_file ------------------------------------------------

# RETARGETED by INFRA-45. This was "'=' scrub dropped from session_id", editing
# `_sid=$(printf %s "$5" | tr -d '\n=')`, a line the quoting contract deleted.
# The INTENT is unchanged and is why it was retargeted rather than dropped: a
# malformed id must not be able to inject extra .cc-mode keys. Under the
# contract that defence is no longer the '=' scrub -- a '=' inside a value is
# harmless once the value is one quoted token -- it is the line-break strip,
# because a newline is the only character that can still manufacture a second
# line, and therefore a second key. So the mutation now removes that strip.
add_mut "line-break strip dropped from the encoder" test_mode_file_roundtrip.sh \
"$(cat <<'FROM'
    v=${v//$'\n'/}
FROM
)" "$(cat <<'TO'
    v=${v//$'\r'/}
TO
)"

# RETARGETED by INFRA-45. This was "whitespace scrub dropped from model",
# editing `_model=$(printf %s "${7:-}" | tr -d "\n= \t")`, also deleted by the
# contract. Intent unchanged: a value containing a space must not reach a
# sourcing reader unquoted. The defence moved from deleting the space to
# quoting the value, so the mutation now admits the space into the safe-bare
# set -- the one edit that would put a raw space back into the file. The space
# is written as a quoted " " because an unquoted one inside a case pattern
# ends the pattern word, and a mutant that does not parse tests nothing.
add_mut "a space is admitted to the safe-bare set" test_mode_file_roundtrip.sh \
"$(cat <<'FROM'
        *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+:,./-]*)
FROM
)" "$(cat <<'TO'
        *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+:,./-" "]*)
TO
)"

# The escape that makes single-quoting work at all. Without it a value
# containing a quote closes the quoting early and the rest of the value is
# bare shell — the unbalanced-quote defect, reintroduced by one deletion.
add_mut "the single-quote escape is dropped from the encoder" test_mode_file_roundtrip.sh \
"$(cat <<'FROM'
            printf "'%s'" "${v//\'/\'\\\'\'}" ;;
FROM
)" "$(cat <<'TO'
            printf "'%s'" "$v" ;;
TO
)"

# The safe set is the whole security predicate. Admitting '$' writes a command
# substitution into the file bare — defect 3, restored by one character.
add_mut "'\$' is admitted to the safe-bare set" test_mode_file_roundtrip.sh \
"$(cat <<'FROM'
        *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+:,./-]*)
FROM
)" "$(cat <<'TO'
        *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+:,./$-]*)
TO
)"

# The decoder half. If it stops unquoting, every quoted value reaches
# cc-continue and the tests with its quote characters still attached.
add_mut "the decoder stops unquoting" test_mode_file_roundtrip.sh \
"$(cat <<'FROM'
        "'"*"'")
            v=${v#\'}
            v=${v%\'}
FROM
)" "$(cat <<'TO'
        "'"*"'"XXNEVERXX)
            v=${v#\'}
            v=${v%\'}
TO
)"

# ---- statusline-command.sh -----------------------------------------------

# The whole reader-side fix, reverted: source .cc-mode instead of parsing it.
# This is the mutation the statusline tests exist for — it restores all three
# INFRA-45 defects for any .cc-mode the writer did not produce.
add_mut "the statusline sources .cc-mode again" test_statusline.sh \
"$(cat <<'FROM'
        while IFS= read -r line || [ -n "$line" ]; do
            case $line in
                mode=*)  __cc_unq "${line#mode=}";  mode=$UNQ  ;;
                slug=*)  __cc_unq "${line#slug=}";  slug=$UNQ  ;;
                model=*) __cc_unq "${line#model=}"; model=$UNQ ;;
            esac
        done < "$dir/.cc-mode"
FROM
)" "$(cat <<'TO'
        # shellcheck disable=SC1090,SC1091
        . "$dir/.cc-mode"
TO
)" statusline

# The statusline carries its own copy of the decoder because it is /bin/sh and
# cannot source cc-functions.sh on every repaint. Two copies of one algorithm
# is a standing invitation for them to drift, so the copy gets its own
# mutation rather than riding on the bash one's coverage.
add_mut "the statusline decoder drops the escape collapse" test_statusline.sh \
"$(cat <<'FROM'
        UNQ=$UNQ$_pre\'
FROM
)" "$(cat <<'TO'
        UNQ=$UNQ$_pre
TO
)" statusline

# The statusline's key whitelist. Widening it to a prefix match lets
# model_source overwrite the model, which is the drift indicator the whole
# instrument exists to show.
add_mut "the statusline whitelist becomes a prefix match" test_statusline.sh \
"$(cat <<'FROM'
                model=*) __cc_unq "${line#model=}"; model=$UNQ ;;
FROM
)" "$(cat <<'TO'
                model*) __cc_unq "${line#model=}"; model=$UNQ ;;
TO
)" statusline

# Rename a key. Readers B and C look the key up by name, so this silently blanks
# the field for cc-continue and for the tree-slot writer.
add_mut "a key is renamed in the written file" test_mode_file_roundtrip.sh \
"$(cat <<'FROM'
perm_mode_source=$_psrc
FROM
)" "$(cat <<'TO'
permmode_source=$_psrc
TO
)"

# ---- __cc_read_mode ------------------------------------------------------

# Stop the upward walk after one level: a session anywhere below the worktree
# root stops finding its own .cc-mode.
add_mut "upward walk stops after one level" test_mode_file_roundtrip.sh \
"$(cat <<'FROM'
            cat "$dir/.cc-mode"
            return 0
        fi
        dir=$(dirname "$dir")
FROM
)" "$(cat <<'TO'
            cat "$dir/.cc-mode"
            return 0
        fi
        dir=/
TO
)"

# ---- doctor.sh (INFRA-50 push-lag check; INFRA-46 symlink roster) --------

# Reverse the range and the check counts commits origin has that main lacks
# — always 0 on a fully-fetched repo, so unpushed work reads as fully pushed.
# The exact silent inversion this instrument exists to prevent.
add_mut "push-lag counts the reversed range" test_doctor_push.sh \
"$(cat <<'FROM'
rev-list --count origin/main..main
FROM
)" "$(cat <<'TO'
rev-list --count main..origin/main
TO
)" doctor

add_mut "cc-plane-sync.sh drops out of the symlink roster" test_doctor_symlinks.sh \
"$(cat <<'FROM'
check_symlink "$CLAUDE_DIR/cc-plane-sync.sh"      "$EXPECTED_CANONICAL/shell/cc-plane-sync.sh"
FROM
)" "$(cat <<'TO'
: # check_symlink dropped
TO
)" doctor

# ---- configure.sh (INFRA-51 exit code; INFRA-46 link line) ---------------

# The 25-day defect, reintroduced: under set -e the final `&&` with no backup
# dir made every clean idempotent re-run exit 1 (audit F4.1).
add_mut "clean re-run exits 1 again" test_configure.sh \
"$(cat <<'FROM'
[ -d "$BACKUP_DIR" ] && log_info "Pre-install state preserved at: $BACKUP_DIR" || true
FROM
)" "$(cat <<'TO'
[ -d "$BACKUP_DIR" ] && log_info "Pre-install state preserved at: $BACKUP_DIR"
TO
)" configure

add_mut "the cc-plane-sync link line is dropped" test_configure.sh \
"$(cat <<'FROM'
link "$CANONICAL/shell/cc-plane-sync.sh" "$CLAUDE_DIR/cc-plane-sync.sh"
FROM
)" "$(cat <<'TO'
: # link dropped
TO
)" configure

# ---- the cc-scrub git hooks (INFRA-59) -----------------------------------
#
# The gate's failure modes are all silent: a hook that was never installed,
# one git will never run, one that waves a commit through because it could
# not find the scrubber. None of them produce an error message on the day
# they matter, so each gets a mutation that reintroduces it.

add_mut "the git hooks are never installed" test_git_hooks.sh \
"$(cat <<'FROM'
}
install_git_hooks
FROM
)" "$(cat <<'TO'
}
: # hook install dropped
TO
)" configure

# Installing into .git/hooks under a foreign core.hooksPath produces a hook
# git ignores, reported as installed -- a gate that is not there.
add_mut "a foreign core.hooksPath is installed over anyway" test_git_hooks.sh \
"$(cat <<'FROM'
    if [ -n "$configured" ]; then
FROM
)" "$(cat <<'TO'
    if [ -n "$configured" ] && false; then
TO
)" configure

# .git/hooks is untracked: an overwrite here is unrecoverable.
add_mut "the operator's own hook is overwritten without a backup" test_git_hooks.sh \
"$(cat <<'FROM'
        if [ -e "$dst" ] && [ ! -L "$dst" ]; then
FROM
)" "$(cat <<'TO'
        if [ -e "$dst" ] && [ ! -L "$dst" ] && false; then
TO
)" configure

# The one failure mode a gate may not have.
add_mut "a missing scrubber lets the commit through" test_git_hooks.sh \
"$(cat <<'FROM'
SCRUB=$(cc_hook_resolve_scrub "$0") || {
    cc_hook_no_scrubber "$HOOK_NAME"
    exit 1
}
FROM
)" "$(cat <<'TO'
SCRUB=$(cc_hook_resolve_scrub "$0") || exit 0
TO
)" prehook

# INCOMPLETE (exit 2) means the sweep could not prove itself. Treating it as
# clean is the false zero the whole toolchain is built to refuse.
add_mut "an INCOMPLETE sweep counts as clean" test_git_hooks.sh \
"$(cat <<'FROM'
if [ "$RC" -eq 0 ]; then
FROM
)" "$(cat <<'TO'
if [ "$RC" -ne 1 ]; then
TO
)" prehook

# A push that creates a new ref has no far side to diff against. Sweeping
# an empty range and calling it clean is worse than refusing.
add_mut "an unboundable push range passes instead of refusing" test_git_hooks.sh \
"$(cat <<'FROM'
            FAILED=1
            continue
FROM
)" "$(cat <<'TO'
            continue
TO
)" pushhook

# A deletion publishes nothing; scanning it produces a false refusal on an
# ordinary cleanup.
add_mut "a ref deletion is scanned like a normal push" test_git_hooks.sh \
"$(cat <<'FROM'
    if cc_hook_is_zero "${local_sha:-}"; then
        continue
    fi
FROM
)" "$(cat <<'TO'
    if false; then
        continue
    fi
TO
)" pushhook

# ---- cc-plane-sync.sh ----------------------------------------------------

# The whole reason the helper exists in this shape: every network failure
# must warn and exit 0, or a UDM IPS event makes every session unstartable
# (INFRA-37). One character reintroduces the hard failure.
add_mut "a network failure blocks the bookend" test_plane_sync.sh \
"$(cat <<'FROM'
except SoftFail as e:
    warn("%s — continuing; the bookend is not blocked on Plane" % e)
    sys.exit(0)
FROM
)" "$(cat <<'TO'
except SoftFail as e:
    warn("%s — continuing; the bookend is not blocked on Plane" % e)
    sys.exit(1)
TO
)" planesync

# Invert the session-id assertion and a helper resolved from the wrong cwd
# writes another lane's issue — the wrong-lane class the refusal guards.
add_mut "the session-id mismatch refusal is inverted" test_plane_sync.sh \
"$(cat <<'FROM'
[ "$ASSERT_SESSION" != "$SESSION_ID" ]
FROM
)" "$(cat <<'TO'
[ "$ASSERT_SESSION" = "$SESSION_ID" ]
TO
)" planesync

# Narrow the no-write guard and `start` PATCHes issues that are already
# started — an unidempotent bookend write on every session open.
add_mut "start loses its already-started guard" test_plane_sync.sh \
"$(cat <<'FROM'
    if cur.get("group") not in ("backlog", "unstarted"):
FROM
)" "$(cat <<'TO'
    if cur.get("group") not in ("backlog",):
TO
)" planesync

# Break identity precedence 2: a .cc-mode plane_issue= pin stops beating the
# task folder's plane.md back-reference.
add_mut "the .cc-mode plane_issue pin is ignored" test_plane_sync.sh \
"$(cat <<'FROM'
    ISSUE_REF=$(mode_get plane_issue "$MODEF")          # precedence 2
FROM
)" "$(cat <<'TO'
    ISSUE_REF=$(mode_get plane_issue_x "$MODEF")        # precedence 2
TO
)" planesync

# ---- __cc_write_sandbox_settings (INFRA-54) ------------------------------

# The sibling-leak. A blanket "company/tasks" grant is the one edit that turns
# a per-session carveout into write access to every other task's spec, plan
# and report -- and it LOOKS more permissive-in-a-good-way, not less safe,
# which is exactly why it needs a test standing over it.
add_mut "the task carveout becomes a blanket tasks/ grant" test_sandbox_settings.sh \
"$(cat <<'FROM'
            task_entry=",\"~/vault/20-surface/company/tasks/$task_id\""
FROM
)" "$(cat <<'TO'
            task_entry=",\"~/vault/20-surface/company/tasks\""
TO
)"

# The id validation is a security boundary: the value is interpolated into a
# JSON string AND a mkdir path, and cc-continue reads it back out of a file a
# human can edit. Widening the pattern admits path traversal.
add_mut "the task-id validation admits anything" test_sandbox_settings.sh \
"$(cat <<'FROM'
        if [[ "$task_id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
FROM
)" "$(cat <<'TO'
        if [[ "$task_id" =~ ^.*$ ]]; then
TO
)"

# --settings REPLACES the sandbox object wholesale, so a dropped base entry is
# not inherited back from settings.json -- it is gone for the session, with no
# symptom until a bookend cannot write its own transcript.
add_mut "a base vault carveout is dropped from the fragment" test_sandbox_settings.sh \
"$(cat <<'FROM'
"~/vault/20-surface/claude-memory","~/vault/20-surface/claude-transcripts"
FROM
)" "$(cat <<'TO'
"~/vault/20-surface/claude-memory"
TO
)"

# An allowWrite entry for a directory that does not exist is INERT -- creating
# it would be a write to tasks/, which stays denied. Drop the launcher-side
# mkdir and the carveout still READS correct while granting nothing usable.
add_mut "the task folder is no longer created by the launcher" test_sandbox_settings.sh \
"$(cat <<'FROM'
            mkdir -p "$HOME/vault/20-surface/company/tasks/$task_id" 2>/dev/null \
FROM
)" "$(cat <<'TO'
            true "$HOME/vault/20-surface/company/tasks/$task_id" 2>/dev/null \
TO
)"

# ---- __cc_find_sandbox_settings ------------------------------------------

# Stop the upward walk after one level. cc-continue regenerates the fragment
# AT THE PATH THIS WALK RETURNS, so a session launched from a subdirectory
# strands a second fragment there and keeps resuming under the stale one.
add_mut "the sandbox-fragment walk stops after one level" test_sandbox_settings.sh \
"$(cat <<'FROM'
            printf '%s\n' "$dir/.cc-sandbox-settings.json"
            return 0
        fi
        dir=$(dirname "$dir")
FROM
)" "$(cat <<'TO'
            printf '%s\n' "$dir/.cc-sandbox-settings.json"
            return 0
        fi
        dir=/
TO
)"

# ---- __cc_trust_effective / __cc_trust_register --------------------------

# The git-root boundary is the whole reason pre-registration is needed. Remove
# it and trust inherits from $HOME, so every brand-new worktree reads as
# already-trusted, the register short-circuits, and the unattended child sits
# on the trust dialog forever -- with nothing on screen to say why.
add_mut "trust inherits past the enclosing git root" test_trust.sh \
"$(cat <<'FROM'
        [ -n "$root" ] && [ "$node" = "$root" ] && return 1
FROM
)" "$(cat <<'TO'
        [ -z "$root" ] && [ "$node" = "$root" ] && return 1
TO
)"

# Replace instead of merge. ~/.claude.json is rewritten by every running claude
# process; dropping the keys claude put in a project entry destroys live
# session state, which the source calls out as the unrecoverable failure.
add_mut "registering replaces a project entry instead of merging it" test_trust.sh \
"$(cat <<'FROM'
.projects[$p] = ((.projects[$p] // {}) + {hasTrustDialogAccepted: true})
FROM
)" "$(cat <<'TO'
.projects[$p] = {hasTrustDialogAccepted: true}
TO
)"

# "Does nothing at all when trust is already effective" is what keeps this
# extra writer off a contended file in the steady state -- every launch after
# the first in a worktree. Drop the short-circuit and every spawn rewrites it.
add_mut "an already-trusted directory is rewritten anyway" test_trust.sh \
"$(cat <<'FROM'
    __cc_trust_effective "$dir" && return 0
FROM
)" "$(cat <<'TO'
    __cc_trust_effective "$dir" && true
TO
)"

# claude looks the workspace up by its PHYSICAL path. Registering the spelling
# the caller happened to use writes a key nothing ever matches: trust that
# reads as applied, and a dialog that still blocks the child.
add_mut "the trust key is not resolved to a physical path" test_trust.sh \
"$(cat <<'FROM'
    dir=$(cd "$1" 2>/dev/null && pwd -P) || {
FROM
)" "$(cat <<'TO'
    dir=$(printf '%s' "$1") || {
TO
)"

# ---- launch-string renderers / policy discovery / identity ---------------

# %q is the ONLY thing standing between a policy value and command injection
# into a tmux window the operator never typed in: cc and cc-branch build a
# command STRING, so whatever these print gets re-parsed by a shell.
add_mut "the model flag fragment stops shell-quoting" test_launch_flags.sh \
"$(cat <<'FROM'
    printf ' %q' "${__cc_model_args[@]}"
FROM
)" "$(cat <<'TO'
    printf ' %s' "${__cc_model_args[@]}"
TO
)"

add_mut "the perm flag fragment stops shell-quoting" test_launch_flags.sh \
"$(cat <<'FROM'
    printf ' %q' "${__cc_perm_args[@]}"
FROM
)" "$(cat <<'TO'
    printf ' %s' "${__cc_perm_args[@]}"
TO
)"

# The static fallback is reached only when --help cannot be read. Dropping a
# mode from it makes __cc_perm_stage refuse a value the installed claude
# accepts -- on exactly the machines where the probe already failed.
add_mut "the fallback mode list loses bypassPermissions" test_launch_flags.sh \
"$(cat <<'FROM'
        printf '%s\n' "acceptEdits auto bypassPermissions manual dontAsk plan"
FROM
)" "$(cat <<'TO'
        printf '%s\n' "acceptEdits auto manual dontAsk plan"
TO
)"

# A typo'd $CC_MODEL_POLICY must refuse, not fall through to ~/.claude: the
# session would run under a policy nobody pointed at, and say nothing.
add_mut "a missing CC_MODEL_POLICY falls through instead of refusing" test_launch_flags.sh \
"$(cat <<'FROM'
        [ -f "$CC_MODEL_POLICY" ] || return 1
FROM
)" "$(cat <<'TO'
        [ -f "$CC_MODEL_POLICY" ] || CC_MODEL_POLICY="$HOME/.claude/model-policy.json"
TO
)"

# The session id names the tree slot, stamps every event and is asserted
# against by cc-plane-sync. A short id does not fail loudly -- it fragments
# the topology into orphan slots that no parent ever matches.
add_mut "the session id is minted at the wrong width" test_launch_flags.sh \
"$(cat <<'FROM'
        uuidgen | tr -d '-' | head -c 22
FROM
)" "$(cat <<'TO'
        uuidgen | tr -d '-' | head -c 16
TO
)"

# ---- dispatch and never-fatal guards -------------------------------------

# Every helper returns its VALUE on stdout and its prose on stderr, because
# callers do `spec=$(__cc_resolve_model r)`. Send a log line to stdout and it
# is captured and parsed as data -- a model id of "[cc] model: opus".
add_mut "__cc_log writes its prose to stdout" test_dispatch_guards.sh \
"$(cat <<'FROM'
    printf '%s[cc] %s%s\n' "$(__cc_color_or_plain $'\033[01;36m')" "$*" "$(__cc_color_or_plain $'\033[00m')" >&2
FROM
)" "$(cat <<'TO'
    printf '%s[cc] %s%s\n' "$(__cc_color_or_plain $'\033[01;36m')" "$*" "$(__cc_color_or_plain $'\033[00m')"
TO
)"

# __cc_die's non-zero status is load-bearing: refusal branches end on it, and
# a zero return turns every loud refusal into a silent continue.
add_mut "__cc_die returns success" test_dispatch_guards.sh \
"$(cat <<'FROM'
    printf '%s[cc] %s%s\n' "$(__cc_color_or_plain $'\033[01;31m')" "$*" "$(__cc_color_or_plain $'\033[00m')" >&2
    return 1
FROM
)" "$(cat <<'TO'
    printf '%s[cc] %s%s\n' "$(__cc_color_or_plain $'\033[01;31m')" "$*" "$(__cc_color_or_plain $'\033[00m')" >&2
    return 0
TO
)"

# The action trail is best-effort by design. Let a broken logger's status
# escape and an unrelated bookkeeping failure aborts a good spawn.
add_mut "a failing action-trail logger becomes fatal" test_dispatch_guards.sh \
"$(cat <<'FROM'
    bash "$h" "$@" >/dev/null 2>&1 || true
FROM
)" "$(cat <<'TO'
    bash "$h" "$@" >/dev/null 2>&1
TO
)"

# A dangling $CC_EA_LOG_SH must fall through to the next route rather than be
# selected: the trail would point at nothing and log nowhere, silently.
add_mut "a dangling EA-log override is selected anyway" test_dispatch_guards.sh \
"$(cat <<'FROM'
        [ -n "$p" ] && [ -f "$p" ] && { printf '%s' "$p"; return 0; }
FROM
)" "$(cat <<'TO'
        [ -n "$p" ] && { printf '%s' "$p"; return 0; }
TO
)"

# cc-land's own precondition. Without it the delegator runs `bash <missing>`,
# which exits 127 with bash's error instead of the named refusal -- the EA
# reads an unexplained status where a "run configure.sh" instruction belongs.
add_mut "cc-land stops checking that its script exists" test_dispatch_guards.sh \
"$(cat <<'FROM'
    if [ ! -f "$s" ]; then
FROM
)" "$(cat <<'TO'
    if false; then
TO
)"

# ---- entry points (cc-functions.sh) --------------------------------------

# The half-spawn, resurrected: a model refusal in cc-explore no longer
# aborts, so the worktree and branch get created for a launch that dies.
add_mut "cc-explore spawns past a model refusal" test_entry_points.sh \
"$(cat <<'FROM'
    __cc_model_prepare explore || return 1
FROM
)" "$(cat <<'TO'
    __cc_model_prepare explore || true
TO
)"

# cc-branch hands the PARENT's id to the child's launch string; the child
# then asserts against its own .cc-mode and every /start refuses exit 3.
add_mut "cc-branch launches the child under the parent's id" test_entry_points.sh \
"$(cat <<'FROM'
        "CC_SESSION_ID=$(printf '%q' "$child_session_id") claude${model_flag}${perm_flag}"
FROM
)" "$(cat <<'TO'
        "CC_SESSION_ID=$(printf '%q' "$parent_session_id") claude${model_flag}${perm_flag}"
TO
)"

# ---- cc-outbound-guard.sh (INFRA-67) -------------------------------------
#
# The guard had no mutations at all until INFRA-67, which is why the INFRA-66
# audit could find four gap classes in a file whose 74 assertions were green:
# every one of those assertions tested a spelling the guard already handled.
# Each mutation below reverts one INFRA-67 fix to the exact shape the audit
# measured as vulnerable.

# Revert the host-allowlist inversion (§3.2) by making every target look
# internal. This is the whole of gap shape A: unprompted POSTs to Slack,
# pastebin, GitLab, Discord, Telegram and a file drop all pass again.
add_mut "host allowlist treats every target as internal" test_outbound_guard.sh \
"$(cat <<'FROM'
        grep -qE "^${INTERNAL}$" <<<"$h" || return 0
FROM
)" "$(cat <<'TO'
        grep -qE "." <<<"$h" || return 0
TO
)" guard

# Revert the attached-flag spelling on -X (§3.3): require the space back, and
# `curl -XPOST` walks through exactly as the audit measured.
add_mut "-X pattern requires a space again" test_outbound_guard.sh \
"$(cat <<'FROM'
    has ' -X ?(POST|PUT|PATCH|DELETE)\b' "$1" \
FROM
)" "$(cat <<'TO'
    has ' -X (POST|PUT|PATCH|DELETE)\b' "$1" \
TO
)" guard

# Revert the body-flag spelling (§3.3): trailing space required, so -d@b.json,
# -Fa=b and -Tb.json stop matching.
add_mut "body flags require a trailing space again" test_outbound_guard.sh \
"$(cat <<'FROM'
    || has ' (-d|-F|-T)[ =]?[^ -]' "$1" \
FROM
)" "$(cat <<'TO'
    || has ' (-d|-F|-T) ' "$1" \
TO
)" guard

# Revert the gh api attached shorthand (§3.4). `gh api` appears in no deny rule
# at all, so this guard is the only layer, and `-ftitle=x` is one keystroke.
add_mut "gh api -f shorthand needs a trailing space again" test_outbound_guard.sh \
"$(cat <<'FROM'
        || has ' -[fF] ?[^ -]' "$nq" \
FROM
)" "$(cat <<'TO'
        || has ' -[fF] ' "$nq" \
TO
)" guard

# Stop splitting the command into segments, so write flags are matched across a
# whole pipeline again. That is the false positive this change was probed into
# fixing: `curl -s https://example.com/x | grep -F needle` reads as a write.
add_mut "write flags matched across the whole pipeline" test_outbound_guard.sh \
"$(cat <<'FROM'
    done <<<"$(tr '|;&' '\n' <<<"$nq")"
FROM
)" "$(cat <<'TO'
    done <<<"$nq"
TO
)" guard

# Revert the authority-terminator fix (INFRA-80): drop `?` and `#` from the
# host-token character class, and the extractor runs `?`/`#` back into the token
# where `s/^[^@]*@//` swaps the real host for a planted allowlisted one. This is
# the whole of the bypass — `http://evil?@plane.homelab` reads as internal again.
add_mut "host token stops terminating at ? and #" test_outbound_guard.sh \
"$(cat <<'FROM'
    grep -oE 'https?://[^ /?#]+' <<<"$1" \
FROM
)" "$(cat <<'TO'
    grep -oE 'https?://[^ /]+' <<<"$1" \
TO
)" guard

# ---- cc-event-emit.sh (INFRA-67) -----------------------------------------
#
# --body-file shipped untested in AI_ST-72/74. Silently ignoring the flag is
# the failure that matters: an escalation would be emitted with an EMPTY body
# rather than failing, so the parent gets a notification and none of the
# content — the exact case INFRA-66 §6 needed the flag for.
add_mut "--body-file is silently ignored" test_event_emit.sh \
"$(cat <<'FROM'
        BODY=$(cat "$BODY_FILE")
FROM
)" "$(cat <<'TO'
        BODY="$BODY"
TO
)" emit

# ==========================================================================

WORK=$(mktemp -d) || exit 2
trap 'rm -rf "$WORK"' EXIT

caught=0 survived=0 stale=0 errored=0

printf 'Mutation check over %d subject(s):\n' "${#SUBJECTS[@]}"
for s in "${!SUBJECTS[@]}"; do printf '  %s\n' "${SUBJECTS[$s]}"; done
printf '(the checked-in files are never modified; mutants live under %s)\n\n' "$WORK"

for i in "${!M_LABEL[@]}"; do
    label="${M_LABEL[$i]}" testfile="${M_TEST[$i]}"
    subj="${M_SUBJ[$i]}"
    subject="${SUBJECTS[$subj]}"
    subject_env="${SUBJECT_ENV[$subj]}"
    mutant="$WORK/mutant-$i.sh"
    cp "$subject" "$mutant"

    # Literal substitution, applied once. Exit 3 means the pattern is gone, which
    # is reported rather than silently producing an unmutated "mutant"; exit 4
    # means it appears more than once, which would make the mutation ambiguous.
    M_FROM_TEXT="${M_FROM[$i]}" M_TO_TEXT="${M_TO[$i]}" python3 - "$mutant" <<'PY'
import os, sys
path = sys.argv[1]
frm, to = os.environ["M_FROM_TEXT"], os.environ["M_TO_TEXT"]
s = open(path).read()
n = s.count(frm)
if n == 0:
    sys.exit(3)
if n > 1:
    sys.exit(4)
open(path, "w").write(s.replace(frm, to, 1))
PY
    prc=$?
    if [ "$prc" -eq 3 ]; then
        log_error "STALE    $label"
        printf '         the text this mutation edits is no longer in %s\n' "$(basename "$subject")"
        stale=$((stale + 1)); continue
    elif [ "$prc" -eq 4 ]; then
        log_error "STALE    $label"
        printf '         the pattern matches more than once; make it unique\n'
        stale=$((stale + 1)); continue
    elif [ "$prc" -ne 0 ]; then
        log_error "STALE    $label (mutation could not be applied, rc=$prc)"
        stale=$((stale + 1)); continue
    fi

    # The mutant must still parse, or "the tests failed" would only prove that
    # a syntax error breaks bash.
    if ! bash -n "$mutant" 2>/dev/null; then
        log_error "STALE    $label (mutant does not parse)"
        stale=$((stale + 1)); continue
    fi

    # ORDER MATTERS, and it silently did not for the first 24 mutations in this
    # table. GNU env stops parsing options at the FIRST NAME=VALUE assignment,
    # so `env FOO=bar -u BAZ cmd` runs the command "-u" and exits 127 -- the
    # test file never ran. rc was non-zero, so every mutation was reported
    # CAUGHT while proving nothing, which is the exact failure this script
    # exists to prevent, committed inside the script itself. The -u flags now
    # precede the assignment (INFRA-55).
    out=$(env -u CC_MODEL -u CC_MODEL_POLICY -u CC_PERM_MODE \
          "$subject_env=$mutant" \
          bash "$SCRIPT_DIR/$testfile" 2>&1)
    rc=$?
    nfail=$(printf '%s\n' "$out" | grep -c '^not ok')

    # A non-zero rc is NOT sufficient evidence of a catch. A test file that
    # dies before it can assert -- a missing dependency, an unbound variable,
    # a harness invocation error -- also exits non-zero, and counting that as
    # CAUGHT is how this table spent its whole life green without running.
    # A catch requires a TAP plan (the file reached its end) AND at least one
    # failed assertion (it reached the end by asserting, not by dying).
    if ! printf '%s\n' "$out" | grep -qE '^1\.\.[0-9]+'; then
        log_error "ERRORED  $label"
        printf '         %s produced no TAP plan (rc=%s) -- it died rather than asserted.\n' \
            "$testfile" "$rc"
        printf '         This is a BROKEN CHECK, not a caught mutation.\n'
        printf '%s\n' "$out" | head -3 | sed 's/^/           /'
        errored=$((errored + 1)); continue
    fi

    if [ "$rc" -ne 0 ] && [ "$nfail" -gt 0 ]; then
        log_ok "CAUGHT   $label"
        printf '         %s failed %s assertion(s), first:\n' "$testfile" "$nfail"
        printf '%s\n' "$out" | grep -m1 '^not ok' | sed 's/^/           /'
        printf '%s\n' "$out" | grep -A2 -m1 '^not ok' | grep '^#' | sed 's/^/           /'
        caught=$((caught + 1))
    elif [ "$rc" -ne 0 ]; then
        log_error "ERRORED  $label"
        printf '         %s exited %s with a TAP plan but zero failed assertions.\n' \
            "$testfile" "$rc"
        errored=$((errored + 1))
    else
        log_error "SURVIVED $label"
        printf '         %s passed against a mutant that should have broken it.\n' "$testfile"
        printf '         This is a GAP IN THE TESTS, not a passing result.\n'
        survived=$((survived + 1))
    fi
done

echo
printf 'mutations: %d   caught: %d  survived: %d  stale: %d  errored: %d\n' \
    "${#M_LABEL[@]}" "$caught" "$survived" "$stale" "$errored"
if [ "$survived" -eq 0 ] && [ "$stale" -eq 0 ] && [ "$errored" -eq 0 ]; then
    log_ok "every mutation was caught — the suite bites."
    exit 0
fi
log_error "the suite does not fully bite."
exit 1
