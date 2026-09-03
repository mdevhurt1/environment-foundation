#!/usr/bin/env bash
# cc-explore, cc-build, cc-continue — Claude Code launch wrappers.
# Source from ~/.bashrc:
#   [ -f ~/.claude/cc-functions.sh ] && source ~/.claude/cc-functions.sh
#
# Sandbox mechanism: cc-explore and cc-continue (exploration mode) pass
# --settings <worktree>/.cc-sandbox-settings.json to claude at launch.
# That file is written at worktree creation time containing
# {"sandbox":{"enabled":true,"failIfUnavailable":true}}.
# Claude Code's --settings flag merges the file on top of ~/.claude/settings.json,
# so the user's existing sandbox.network.* allowlist is preserved.
# The settings file lives inside the worktree so it is cleaned up automatically
# when the worktree is removed.
#
# Permission mode: the wrappers pass NO permission flag unless one was actually
# asked for ($CC_PERM_MODE, or roles.<role>.permission_mode in the model policy).
# Absent an override, settings.json permissions.defaultMode governs. See the
# "permission mode" helper block below for why a wrapper must not out-vote it.

# ---- why the helpers are named __cc_* (double underscore) ----
# Claude Code's Bash tool does not re-run your rc files. It restores shell state
# from ~/.claude/shell-snapshots/snapshot-<shell>-*.sh, generated with:
#
#     typeset +f | grep -vE '^_[^_]' | while read func; do typeset -f "$func"; done
#
# The filter drops zsh completion functions (conventionally `_command`) and
# explicitly keeps double-underscore helpers. Single-underscore helpers of ours
# were dropped by the same rule: the public cc-* function was captured, its
# `_cc_*` callees were not, and since these functions have no `set -e` they
# limped past `command not found` and half-spawned a session (worktree + tmux
# window, but no .cc-mode, no session_id, no tree slot, no spawned event).
# Keep the double underscore. scripts/doctor.sh check 8 enforces it.
#
# Each public cc-* function additionally carries the two-line snapshot guard
# below, so a snapshot that predates this file (an already-running session)
# aborts loudly instead of half-running.

# ---- internal helpers ----
__cc_color_or_plain() {
    if [ -t 2 ] && [ "${TERM:-dumb}" != "dumb" ]; then
        printf '%s' "$1"
    fi
}
__cc_die() {
    printf '%s[cc] %s%s\n' "$(__cc_color_or_plain $'\033[01;31m')" "$*" "$(__cc_color_or_plain $'\033[00m')" >&2
    return 1
}
__cc_log() {
    printf '%s[cc] %s%s\n' "$(__cc_color_or_plain $'\033[01;36m')" "$*" "$(__cc_color_or_plain $'\033[00m')" >&2
}

__cc_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

__cc_mint_session_id() {
    # 22-char hex ID derived from uuidgen. Falls back to /dev/urandom on
    # systems without uuidgen (rare on Ubuntu).
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr -d '-' | head -c 22
    else
        head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 22
    fi
}

# ---- model policy ----
# Locate the role->model policy file. Three routes, in order:
#   1. $CC_MODEL_POLICY             explicit override (tests, one-off runs)
#   2. ~/.claude/model-policy.json  the configure.sh symlink (steady state)
#   3. the repo copy sitting beside the live cc-functions.sh symlink
# Route 3 exists because this file is live via symlink for every running
# session: a session must be able to find the policy before configure.sh has
# been re-run to add the new link, or launches start refusing mid-flight.
__cc_model_policy_path() {
    if [ -n "${CC_MODEL_POLICY:-}" ]; then
        [ -f "$CC_MODEL_POLICY" ] || return 1
        printf '%s\n' "$CC_MODEL_POLICY"
        return 0
    fi
    if [ -f "$HOME/.claude/model-policy.json" ]; then
        printf '%s\n' "$HOME/.claude/model-policy.json"
        return 0
    fi
    local ccf cand
    ccf=$(readlink -f "$HOME/.claude/cc-functions.sh" 2>/dev/null) || return 1
    case "$ccf" in
        */shell/cc-functions.sh)
            cand="${ccf%/shell/cc-functions.sh}/model-policy.json"
            if [ -f "$cand" ]; then printf '%s\n' "$cand"; return 0; fi
            ;;
    esac
    return 1
}

# __cc_resolve_model <role> -- prints "<model>\t<source>" on stdout.
# Order: $CC_MODEL (env) > policy roles.<role>.model > refuse.
#
# Refusing rather than falling back to Default is deliberate. Claude Code's
# "Default" is a MOVING REFERENT: it resolves to the most capable model on the
# account, so a newly-released model captures every unpinned session with no
# diff, no event and no line of output. That is how the EA session silently
# moved Opus 5 -> Fable 5. A refusal costs one command and is loud; the silent
# version was discovered by a bill. CC_MODEL=<value> is the escape hatch and is
# named in the refusal message itself, so a broken policy strands nobody.
#
# The value GRAMMAR is validated by scripts/doctor.sh check 10b, not here --
# one implementation, and the linter is its right home. This resolver refuses
# only on a missing policy, an absent role, or an empty value.
__cc_resolve_model() {
    local role="$1" policy model
    if [ -n "${CC_MODEL:-}" ]; then
        printf '%s\t%s\n' "$CC_MODEL" "env"
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        __cc_die "jq is required to read the model policy"
        __cc_log "  fix: install jq, or launch once with: CC_MODEL=track-latest <command>"
        return 1
    fi
    if ! policy=$(__cc_model_policy_path); then
        __cc_die "no model policy found for role '$role'"
        __cc_log "  looked at: \$CC_MODEL_POLICY, ~/.claude/model-policy.json, and the"
        __cc_log "             repo copy beside ~/.claude/cc-functions.sh"
        __cc_log "  fix: run the claude-code module's configure.sh"
        __cc_log "  or launch once with: CC_MODEL=track-latest <command>"
        return 1
    fi
    model=$(jq -r --arg r "$role" '.roles[$r].model // empty' "$policy" 2>/dev/null)
    if [ -z "$model" ]; then
        __cc_die "model policy has no model for role '$role': $policy"
        __cc_log "  fix: add a roles.$role entry to the policy"
        __cc_log "  or launch once with: CC_MODEL=track-latest <command>"
        return 1
    fi
    printf '%s\t%s\n' "$model" "policy:$role"
}

# __cc_model_prepare <role> -- resolve the role and stage the launch.
# Sets, in the CALLER's scope: __cc_model_value, __cc_model_source, and the
# array __cc_model_args (empty for track-latest, else: --model <value>).
# Callers must declare all three `local` first. Returns 1 on refusal.
__cc_model_prepare() {
    local role="$1" spec
    spec=$(__cc_resolve_model "$role") || return 1
    __cc_model_value=${spec%%$'\t'*}
    __cc_model_source=${spec##*$'\t'}
    if [ "$__cc_model_value" = "track-latest" ]; then
        __cc_model_args=()
        __cc_log "model: track-latest (source=$__cc_model_source) - no --model passed; Default may move"
    else
        __cc_model_args=(--model "$__cc_model_value")
        __cc_log "model: $__cc_model_value (source=$__cc_model_source)"
    fi
}

# Render __cc_model_args as a shell-quoted fragment for the tmux command
# STRING used by cc / cc-branch (tmux takes a string, not an argv array).
# Prints the empty string for track-latest.
__cc_model_flag_str() {
    [ "${#__cc_model_args[@]}" -gt 0 ] || return 0
    printf ' %q' "${__cc_model_args[@]}"
}

# ---- permission mode ----
# Resolution order, mirroring the model policy above:
#   1. $CC_PERM_MODE                       explicit override for one launch
#   2. policy roles.<role>.permission_mode a recorded per-role choice
#   3. nothing                             settings.json permissions.defaultMode
#                                          governs; NO flag is passed
#
# Step 3 is the steady state and the whole point. The wrappers used to append
# --dangerously-skip-permissions unconditionally, which silently overrode
# settings.json permissions.defaultMode -- a versioned, reviewed, checked-in
# choice -- for every session the company launches. A wrapper must not out-vote
# the settings file; it may only carry an override someone actually stated.
#
# NOTE the deliberate asymmetry with __cc_resolve_model, which REFUSES when it
# cannot resolve. That refusal exists because Claude Code's "Default" model is a
# moving referent: falling through to it is an accident that costs money.
# Permission mode has no such hazard -- falling through lands on an explicit
# value in a tracked file, which is the intended outcome, not a silent default.
# So a missing policy, a missing role, or a missing jq are all NON-fatal here;
# only an explicitly stated but INVALID value is fatal.
__cc_resolve_perm() {
    local role="$1" policy mode=""
    if [ -n "${CC_PERM_MODE:-}" ]; then
        printf '%s\t%s\n' "$CC_PERM_MODE" "env"
        return 0
    fi
    if command -v jq >/dev/null 2>&1 && policy=$(__cc_model_policy_path); then
        mode=$(jq -r --arg r "$role" '.roles[$r].permission_mode // empty' "$policy" 2>/dev/null)
    fi
    if [ -n "$mode" ]; then
        printf '%s\t%s\n' "$mode" "policy:$role"
        return 0
    fi
    printf '\t%s\n' "settings-default"
}

# Permission modes the INSTALLED claude accepts, space-separated. Parsed from
# --help (~0.2s, and only on the override path) rather than hardcoded, because
# this list has already changed shape once -- 2.1.236 offers "manual" and
# "dontAsk" that older docs do not, and rejects "Default". A stale hardcoded
# list refuses a value that works, or worse admits one that does not and kills
# claude inside a fresh tmux window: exactly the half-spawn the __cc_* rename
# was introduced to prevent. The static list is only a fallback for a --help
# that cannot be read or parsed.
__cc_perm_modes() {
    local parsed
    parsed=$(claude --help 2>/dev/null | tr '\n' ' ' \
        | grep -o 'permission-mode <mode>[^)]*)' \
        | grep -o '"[a-zA-Z]*"' | tr -d '"' | tr '\n' ' ')
    if [ -n "$parsed" ]; then
        printf '%s\n' "$parsed"
    else
        printf '%s\n' "acceptEdits auto bypassPermissions manual dontAsk plan"
    fi
}

# __cc_perm_stage <value> <source> -- stage an already-resolved permission mode.
# Sets, in the CALLER's scope: __cc_perm_value, __cc_perm_source, and the array
# __cc_perm_args (EMPTY for the settings-default path, else:
# --permission-mode <value>). Callers must declare all three `local` first.
# Returns 1 on refusal, having produced no side effects.
__cc_perm_stage() {
    local valid
    __cc_perm_value="$1"
    __cc_perm_source="$2"
    if [ -z "$__cc_perm_value" ]; then
        __cc_perm_args=()
        __cc_log "perm-mode: settings-default (no flag; settings.json permissions.defaultMode governs)"
        return 0
    fi
    valid=$(__cc_perm_modes)
    case " $valid " in
        *" $__cc_perm_value "*) ;;
        *)
            __cc_die "not a permission mode this claude accepts: '$__cc_perm_value' (source=$__cc_perm_source)"
            __cc_log "  accepted: $valid"
            __cc_log "  fix: correct \$CC_PERM_MODE, or roles.<role>.permission_mode in the policy"
            __cc_log "  or drop the override entirely to fall back to settings.json"
            __cc_log "     permissions.defaultMode, which is the intended steady state"
            return 1
            ;;
    esac
    __cc_perm_args=(--permission-mode "$__cc_perm_value")
    __cc_log "perm-mode: $__cc_perm_value (source=$__cc_perm_source)"
}

# __cc_perm_prepare <role> -- resolve the role and stage the launch. Same
# contract as __cc_model_prepare, and called from the same place: BEFORE any
# worktree, branch or tmux window exists, so a refusal leaves nothing behind.
__cc_perm_prepare() {
    local spec
    spec=$(__cc_resolve_perm "$1")
    __cc_perm_stage "${spec%%$'\t'*}" "${spec##*$'\t'}"
}

# Render __cc_perm_args as a shell-quoted fragment for the tmux command STRING
# used by cc / cc-branch. Prints the empty string on the settings-default path.
__cc_perm_flag_str() {
    [ "${#__cc_perm_args[@]}" -gt 0 ] || return 0
    printf ' %q' "${__cc_perm_args[@]}"
}

# ---- workspace trust ----
# Claude Code refuses to touch a workspace it has not been told to trust, and
# asks interactively on first use. Measured on 2.1.236: the dialog appears for a
# never-trusted directory under EVERY permission mode -- plain, --permission-mode
# bypassPermissions AND --dangerously-skip-permissions. The bypass flag never
# suppressed it; what suppressed it was that most launch directories had already
# been trusted by hand. Every cc-branch/cc-explore worktree is brand new, so an
# unattended child would sit on that dialog forever.
#
# Trust lives in ~/.claude.json as projects["<abs path>"].hasTrustDialogAccepted.
# Setting it directly is the route Claude Code itself names in its own untrusted-
# workspace error ("...or set projects[<path>].hasTrustDialogAccepted: true in
# <config>"), so this is a documented seam, not a poke at private state.
#
# TRADEOFF, on the record: ~/.claude.json is owned and rewritten by every running
# claude process, with no lock file of its own -- concurrent writes are already
# last-writer-wins between claude's own sessions. These helpers add one more
# writer. They keep the exposure as small as it can be made from outside: they
# do nothing at all when trust is already effective (the steady state after the
# first launch in a worktree), they serialise our own writes with flock, they
# build the new file in the same directory and land it with an atomic rename,
# and they verify the rewritten JSON parses and carries the intended key before
# replacing anything. Every failure path WARNs and returns 0 -- a session that
# stops on a trust dialog is recoverable by a human, a clobbered ~/.claude.json
# is not, and neither is worth aborting an otherwise good spawn over.

# __cc_trust_effective <dir> -- 0 if claude would already consider dir trusted.
# Mirrors claude's own check: walk from dir upward, stopping at the enclosing
# git repo root (a worktree's root is the worktree itself, which is why trusting
# ~/ does not cover ~/repo-branch-foo), and accept the first hasTrustDialogAccepted.
__cc_trust_effective() {
    local dir="$1" root node parent
    root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
    [ -n "$root" ] && root=$(cd "$root" 2>/dev/null && pwd -P)
    node="$dir"
    while :; do
        if [ "$(jq -r --arg p "$node" '.projects[$p].hasTrustDialogAccepted // false' \
                "$HOME/.claude.json" 2>/dev/null)" = "true" ]; then
            return 0
        fi
        [ -n "$root" ] && [ "$node" = "$root" ] && return 1
        parent=$(dirname "$node")
        [ "$parent" = "$node" ] && return 1
        node="$parent"
    done
}

# __cc_trust_register <dir> -- pre-register folder trust for a directory this
# wrapper just created, so the spawn reaches its prompt unattended. Never fatal.
__cc_trust_register() {
    local dir cfg tmp rc
    dir=$(cd "$1" 2>/dev/null && pwd -P) || {
        __cc_log "WARNING: trust: cannot resolve directory '$1'; skipping pre-registration"
        return 0
    }
    cfg="$HOME/.claude.json"
    if ! command -v jq >/dev/null 2>&1; then
        __cc_log "WARNING: trust: jq not installed; cannot pre-register $dir"
        __cc_log "         this session will stop on the workspace trust dialog until answered"
        return 0
    fi
    if [ ! -f "$cfg" ]; then
        __cc_log "WARNING: trust: $cfg not found; skipping pre-registration"
        return 0
    fi
    __cc_trust_effective "$dir" && return 0

    tmp=$(mktemp "$cfg.cc-trust.XXXXXX" 2>/dev/null) || {
        __cc_log "WARNING: trust: could not create a temp file beside $cfg; skipping"
        return 0
    }
    (
        flock 9 2>/dev/null
        jq --arg p "$dir" \
           '.projects[$p] = ((.projects[$p] // {}) + {hasTrustDialogAccepted: true})' \
           "$cfg" > "$tmp" 2>/dev/null || exit 3
        # Re-read the candidate: this proves it is parseable JSON AND carries the
        # intent, so a truncated or half-written file can never replace the real one.
        [ "$(jq -r --arg p "$dir" '.projects[$p].hasTrustDialogAccepted // false' "$tmp" 2>/dev/null)" = "true" ] || exit 3
        chmod 600 "$tmp" 2>/dev/null
        mv -f "$tmp" "$cfg" || exit 3
    ) 9>"$HOME/.claude.json.cc-lock"
    rc=$?
    rm -f "$tmp" 2>/dev/null
    if [ "$rc" -ne 0 ]; then
        __cc_log "WARNING: trust: could not pre-register $dir in $cfg"
        __cc_log "         this session will stop on the workspace trust dialog until answered"
        return 0
    fi
    __cc_log "trust: pre-registered $dir (workspace trust dialog suppressed)"
}

# ---- company tmux helpers ----
__cc_company_tmux_session() {
    # Single point of truth for the company tmux session name.
    printf '%s' "company"
}

__cc_company_tmux_exists() {
    local name
    name=$(__cc_company_tmux_session)
    tmux has-session -t "$name" 2>/dev/null
}

__cc_company_tmux_ensure() {
    # Create the company tmux session if it does not exist. Idempotent.
    local name
    name=$(__cc_company_tmux_session)
    if __cc_company_tmux_exists; then
        return 0
    fi
    # New detached session, first window owned by the caller; we'll rename
    # the first window from "cc" (the launcher attaches in cc()).
    tmux new-session -d -s "$name" -n "cc"
    __cc_log "company tmux session created: $name"
}

# ---- the .cc-mode quoting contract ----
#
# .cc-mode was CONFIG THAT WAS ALSO CODE. canonical/statusline-command.sh
# sourced it, once per repaint, in every session in every worktree -- so every
# value in it was shell, and three separate defects followed from that one
# fact (INFRA-45, all three reproduced against the real writer):
#
#   1. `slug=my thing` parses as the assignment `slug=my` PREFIXED to the
#      command `thing`. A prefix assignment is scoped to that command's
#      environment, so the field reads back EMPTY -- a total loss, not a
#      truncation. That is why it never looked like a quoting bug to anyone
#      watching a statusline: there was nothing on it to look wrong.
#   2. `parent_repo=/tmp/we"ird` opens a quote that is never closed, and the
#      shell swallows the rest of the file. Every field BELOW the bad line is
#      lost while the fields above it survive. The damage is positional and
#      silent: the fields that break are not the field that is malformed.
#   3. `parent_id=$(touch /tmp/x)` RUNS. The old scrub removed newlines and
#      '=', and a command substitution contains neither, so it reached the
#      file intact and executed -- again on every repaint.
#
# Two independent things close that class, and both are done. The statusline
# no longer SOURCES the file: it parses it against a whitelist of the three
# keys it displays, so no .cc-mode from any origin -- this writer, an older
# one, a hand edit, a restored backup, a stray file in a parent directory --
# is executable by it any more. And this writer ENCODES its values, so a file
# it produces is inert for anything else that does source it.
#
# THE CONTRACT
#
#   A value is written BARE if and only if every one of its characters is in
#   the safe set [A-Za-z0-9_@%+:,./-]. The empty string qualifies, which is
#   what keeps `perm_mode=` a legal line. Otherwise the value is written
#   SINGLE-QUOTED, with each embedded ' rendered as the four characters '\''.
#
#   Newline and carriage return cannot be represented in a line-oriented
#   format and are REMOVED at the write boundary. That is the only lossy
#   transformation in the contract and it is the whole of it; every other byte
#   round-trips, including the quote characters, $, `, \ and =.
#
#   INVARIANT: sourcing a .cc-mode produced by __cc_write_mode_file can never
#   execute anything, and can never alter a field other than the one being
#   assigned. tests/test_mode_file_roundtrip.sh section 9 asserts this against
#   the real writer, with an execution canary on the filesystem rather than by
#   reading the output for an error message.
#
# WHY CONDITIONAL QUOTING RATHER THAN "QUOTE EVERYTHING"
#
#   Unconditional quoting is simpler to state, and it was rejected on blast
#   radius. Six other readers -- cc-tree-slot-write.sh, cc-tree-slot-update.sh,
#   cc-status-scan.sh, cc-reclaim-window.sh, cc-plane-sync.sh and the
#   session-start skill -- parse this file with `grep '^key=' | cut -d= -f2-`,
#   and every one of them would begin seeing literal quote characters wrapped
#   around ids it then matches against 22-hex. Every value the four wrappers
#   write today is already a safe token, so a conditional encoder leaves real
#   .cc-mode files BYTE-IDENTICAL and changes behaviour only for the values
#   that were broken anyway. What makes a conditional defensible here is that
#   the predicate is an ALLOW-list: a character nobody anticipated gets
#   quoted, not passed through.
#
# WHY NOT "REFUSE AT THE WRITE BOUNDARY"
#
#   The other defensible shape, and it loses something real. parent_repo is a
#   filesystem path handed in by all four wrappers as "$repo_root"; a checkout
#   under a path containing a space is legal, and refusing it would convert a
#   cosmetic statusline fault into a launch failure. Refusal also forecloses a
#   free-text `goal=` line -- which INFRA-40 declined to write precisely
#   because of defect 1, and which this contract now makes representable.

# __cc_mode_quote <value> -- encode one .cc-mode value. Prints, does not log.
__cc_mode_quote() {
    local v="${1-}"
    # The one lossy step. Done first so the safety predicate never has to
    # reason about a value that spans lines.
    v=${v//$'\n'/}
    v=${v//$'\r'/}
    # The safe set is ENUMERATED rather than written as A-Z/a-z/0-9 ranges on
    # purpose: bracket ranges are resolved by the locale's collation, and this
    # is a security predicate that must mean the same thing under every
    # LC_COLLATE the operator might have set.
    case "$v" in
        *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+:,./-]*)
            printf "'%s'" "${v//\'/\'\\\'\'}" ;;
        *)  printf '%s' "$v" ;;
    esac
}

# __cc_mode_unquote <value> -- decode one .cc-mode value.
#
# A value that is not single-quoted is returned verbatim, which is what keeps
# every .cc-mode written before this contract existed readable by the readers
# that now decode. The one ambiguity that buys: a LEGACY bare value that
# happens to both start and end with a single quote decodes to its interior.
# No writer has ever produced one -- this encoder quotes any value containing
# a quote -- and the alternative, a format marker on every line, would break
# the six `cut -d= -f2-` readers the conditional encoding exists to protect.
__cc_mode_unquote() {
    local v="${1-}"
    case "$v" in
        "'"*"'")
            v=${v#\'}
            v=${v%\'}
            printf '%s' "${v//\'\\\'\'/\'}"
            ;;
        *)  printf '%s' "$v" ;;
    esac
}

__cc_write_mode_file() {
    # $1 = directory, $2 = mode, $3 = slug, $4 = parent_repo,
    # $5 = session_id, $6 = parent_id (may be empty for top-level launches),
    # $7 = model (resolved value: track-latest | tier alias | exact id),
    # $8 = model_source (env | policy:<role>),
    # $9 = perm_mode (the --permission-mode value, or EMPTY for the
    #      settings-default path -- empty is a legal, expected value here),
    # $10 = perm_mode_source (env | policy:<role> | settings-default)
    #
    # Every value goes through __cc_mode_quote -- including started_at, which
    # this function computes rather than receives. Encoding a value the writer
    # trusts costs nothing and removes the standing question of which fields
    # are covered; the old code's answer to that question was "six of nine",
    # and the three it left out were exactly the three that broke.
    local _mode _slug _prepo _sid _pid _model _msrc _perm _psrc _started
    _mode=$(__cc_mode_quote "$2")
    _slug=$(__cc_mode_quote "$3")
    _prepo=$(__cc_mode_quote "$4")
    _sid=$(__cc_mode_quote "$5")
    _pid=$(__cc_mode_quote "${6:-}")
    _model=$(__cc_mode_quote "${7:-}")
    _msrc=$(__cc_mode_quote "${8:-}")
    _perm=$(__cc_mode_quote "${9:-}")
    _psrc=$(__cc_mode_quote "${10:-}")
    _started=$(__cc_mode_quote "$(date -Iseconds)")

    # Quoting is lossless, so it is silent. Dropping a newline is not, so it
    # is not: a session id that is quietly shorter than the one the caller
    # passed is the kind of thing that gets diagnosed three tickets later.
    case "$2$3$4$5${6:-}${7:-}${8:-}${9:-}${10:-}" in
        *$'\n'*|*$'\r'*)
            __cc_log "WARNING: .cc-mode: a line break in a value was dropped (the format is line-oriented)" ;;
    esac

    cat > "$1/.cc-mode" <<EOF
mode=$_mode
slug=$_slug
started_at=$_started
parent_repo=$_prepo
session_id=$_sid
parent_id=$_pid
model=$_model
model_source=$_msrc
perm_mode=$_perm
perm_mode_source=$_psrc
EOF
}

# Write sandbox settings into the worktree so --settings can inject them.
# $1 = worktree directory path
__cc_write_sandbox_settings() {
    local dir="$1"
    printf '%s\n' '{"sandbox":{"enabled":true,"failIfUnavailable":true}}' \
        > "$dir/.cc-sandbox-settings.json"
}

__cc_read_mode() {
    # Walk up from cwd looking for .cc-mode; print contents on stdout.
    local dir
    dir=$(pwd)
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/.cc-mode" ]; then
            cat "$dir/.cc-mode"
            return 0
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

# Find the nearest .cc-sandbox-settings.json by walking up from cwd.
# Prints the path on stdout; returns 1 if not found.
__cc_find_sandbox_settings() {
    local dir
    dir=$(pwd)
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/.cc-sandbox-settings.json" ]; then
            printf '%s\n' "$dir/.cc-sandbox-settings.json"
            return 0
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

# ---- cc-explore ----
cc-explore() {
    # Snapshot guard — see "why the helpers are named __cc_*" at the top of this
    # file. Re-source if the helpers are absent; abort before any side effects.
    typeset -f __cc_die >/dev/null 2>&1 || \
        . "${CC_FUNCTIONS_SH:-$HOME/.claude/cc-functions.sh}" 2>/dev/null
    typeset -f __cc_die >/dev/null 2>&1 || {
        printf '[cc] %s: cc helpers unavailable (tried %s); aborting before side effects\n' \
            'cc-explore' "${CC_FUNCTIONS_SH:-$HOME/.claude/cc-functions.sh}" >&2
        return 127
    }
    local slug="${1:-adhoc}"

    if ! [[ "$slug" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        __cc_die "slug must match [a-zA-Z0-9_-]+ (got: $slug)"
        return 1
    fi

    local repo_root
    repo_root=$(__cc_repo_root) || { __cc_die "not in a git repo"; return 1; }
    [ "$(pwd)" = "$repo_root" ] || { __cc_die "must be at repo root: $repo_root"; return 1; }

    local repo_name worktree branch
    repo_name=$(basename "$repo_root")
    worktree="../${repo_name}-explore-${slug}"
    branch="explore/${slug}"

    # Resolve the model BEFORE creating the worktree. __cc_model_prepare can
    # refuse (missing/unreadable policy), and a refusal after `git worktree add`
    # would leave a stray worktree and branch behind -- the same half-spawn
    # shape the snapshot guard above exists to prevent. Abort before side
    # effects, always.
    local __cc_model_value __cc_model_source
    local -a __cc_model_args
    __cc_model_prepare explore || return 1

    # Same rule for the permission mode: resolve (and refuse an invalid value)
    # before anything exists on disk.
    local __cc_perm_value __cc_perm_source
    local -a __cc_perm_args
    __cc_perm_prepare explore || return 1

    if [ -d "$worktree" ]; then
        __cc_log "worktree already exists at $worktree — reusing"
    else
        # If the branch already exists (e.g. worktree was pruned), add without -b.
        if git show-ref --verify --quiet "refs/heads/${branch}"; then
            git worktree add "$worktree" "$branch" || return 1
        else
            git worktree add "$worktree" -b "$branch" || return 1
        fi
    fi

    local session_id
    session_id=$(__cc_mint_session_id)

    __cc_write_mode_file "$worktree" exploration "$slug" "$repo_root" "$session_id" "${CC_PARENT_ID:-}" \
        "$__cc_model_value" "$__cc_model_source" "$__cc_perm_value" "$__cc_perm_source"
    __cc_write_sandbox_settings "$worktree"

    # The worktree is brand new, so claude has never been told to trust it. Do
    # that now: without a permission flag suppressing nothing, the launch would
    # otherwise stop on the workspace trust dialog. Never fatal.
    __cc_trust_register "$worktree"

    __cc_log "EXPLORE mode: sandboxed (--settings), branch=$branch, worktree=$worktree"
    cd "$worktree" || return 1
    # CC_SESSION_ID is a per-command PREFIX, never an export. The tree-slot
    # helpers treat it as an ASSERTION and refuse (exit 3) when it disagrees
    # with the resolved .cc-mode, so a value that outlived this launch would
    # turn the NEXT session's /start into a hard failure. Same reason the
    # ANTHROPIC_MODEL/tmux-setenv route was rejected: env state that survives
    # the process leaks into every later spawn.
    CC_SESSION_ID="$session_id" claude "${__cc_model_args[@]}" "${__cc_perm_args[@]}" --settings "$worktree/.cc-sandbox-settings.json"
}

# ---- cc-build ----
cc-build() {
    # Snapshot guard — see "why the helpers are named __cc_*" at the top of this
    # file. Re-source if the helpers are absent; abort before any side effects.
    typeset -f __cc_die >/dev/null 2>&1 || \
        . "${CC_FUNCTIONS_SH:-$HOME/.claude/cc-functions.sh}" 2>/dev/null
    typeset -f __cc_die >/dev/null 2>&1 || {
        printf '[cc] %s: cc helpers unavailable (tried %s); aborting before side effects\n' \
            'cc-build' "${CC_FUNCTIONS_SH:-$HOME/.claude/cc-functions.sh}" >&2
        return 127
    }
    local repo_root
    repo_root=$(__cc_repo_root) || { __cc_die "not in a git repo"; return 1; }
    [ "$(pwd)" = "$repo_root" ] || { __cc_die "must be at repo root: $repo_root"; return 1; }

    local repo_name
    repo_name=$(basename "$repo_root")

    # Refuse without a referenced plan or spec — forces brainstorm-first discipline.
    local has_plan=0
    if [ -d "$HOME/.claude/plans" ] && [ "$(find "$HOME/.claude/plans" -maxdepth 1 -type f 2>/dev/null | wc -l)" -gt 0 ]; then
        has_plan=1
    fi
    if [ -d "./docs/superpowers/specs" ] && [ "$(find "./docs/superpowers/specs" -maxdepth 1 -type f 2>/dev/null | wc -l)" -gt 0 ]; then
        has_plan=1
    fi
    if [ -d "./docs/superpowers/plans" ] && [ "$(find "./docs/superpowers/plans" -maxdepth 1 -type f 2>/dev/null | wc -l)" -gt 0 ]; then
        has_plan=1
    fi

    if [ "$has_plan" -eq 0 ]; then
        __cc_die "build mode requires a plan or spec; brainstorm first (cc-explore)"
        return 1
    fi

    local session_id
    session_id=$(__cc_mint_session_id)

    local __cc_model_value __cc_model_source
    local -a __cc_model_args
    __cc_model_prepare build || return 1

    local __cc_perm_value __cc_perm_source
    local -a __cc_perm_args
    __cc_perm_prepare build || return 1

    __cc_write_mode_file "$repo_root" build "${repo_name}" "$repo_root" "$session_id" "${CC_PARENT_ID:-}" \
        "$__cc_model_value" "$__cc_model_source" "$__cc_perm_value" "$__cc_perm_source"
    # No trust pre-registration here: cc-build runs in the MAIN worktree the
    # operator is already sitting in, which is trusted by the time they can type
    # this. Only the wrappers that CREATE a directory need to vouch for it.
    __cc_log "BUILD mode: main worktree, plan/spec present"
    # CC_SESSION_ID is a per-command PREFIX, never an export. The tree-slot
    # helpers treat it as an ASSERTION and refuse (exit 3) when it disagrees
    # with the resolved .cc-mode, so a value that outlived this launch would
    # turn the NEXT session's /start into a hard failure. Same reason the
    # ANTHROPIC_MODEL/tmux-setenv route was rejected: env state that survives
    # the process leaks into every later spawn.
    CC_SESSION_ID="$session_id" claude "${__cc_model_args[@]}" "${__cc_perm_args[@]}"
}

# ---- cc-continue ----
cc-continue() {
    # Snapshot guard — see "why the helpers are named __cc_*" at the top of this
    # file. Re-source if the helpers are absent; abort before any side effects.
    typeset -f __cc_die >/dev/null 2>&1 || \
        . "${CC_FUNCTIONS_SH:-$HOME/.claude/cc-functions.sh}" 2>/dev/null
    typeset -f __cc_die >/dev/null 2>&1 || {
        printf '[cc] %s: cc helpers unavailable (tried %s); aborting before side effects\n' \
            'cc-continue' "${CC_FUNCTIONS_SH:-$HOME/.claude/cc-functions.sh}" >&2
        return 127
    }
    # Only accept a worktree directory as an argument; plan-file branch dropped.
    if [ -n "${1:-}" ]; then
        if [ -d "$1" ]; then
            cd "$1" || return 1
        else
            __cc_die "no worktree dir named: $1"
            return 1
        fi
    fi

    local mode_data
    mode_data=$(__cc_read_mode) || { __cc_die "no .cc-mode found upward from cwd"; return 1; }

    # Parse .cc-mode into local vars — do NOT export; exporting leaks into the
    # caller's interactive shell and poisons the next claude invocation.
    local mode="" slug="" started_at="" parent_repo="" session_id="" model="" model_source=""
    local perm_mode="" perm_mode_source=""
    # Split on the FIRST '=' only, then decode per the .cc-mode quoting
    # contract. The decode is what lets a resume recover a parent_repo that
    # contains a space -- and, for anything hostile, what keeps the value TEXT
    # rather than something cc-continue goes on to expand.
    while IFS='=' read -r key val; do
        case "$key" in
            mode)         mode=$(__cc_mode_unquote "$val") ;;
            slug)         slug=$(__cc_mode_unquote "$val") ;;
            started_at)   started_at=$(__cc_mode_unquote "$val") ;;
            parent_repo)  parent_repo=$(__cc_mode_unquote "$val") ;;
            session_id)   session_id=$(__cc_mode_unquote "$val") ;;
            model)        model=$(__cc_mode_unquote "$val") ;;
            model_source) model_source=$(__cc_mode_unquote "$val") ;;
            perm_mode)        perm_mode=$(__cc_mode_unquote "$val") ;;
            perm_mode_source) perm_mode_source=$(__cc_mode_unquote "$val") ;;
        esac
    done <<< "$mode_data"

    # Resume on the model this session was LAUNCHED with, not on whatever the
    # policy says today: the session's context was built by that model, and a
    # policy edit between launch and resume must not silently switch it. A
    # .cc-mode written before the model stamp existed carries no model= line;
    # fall back to this mode's policy role rather than to bare Default.
    local __cc_model_value __cc_model_source
    local -a __cc_model_args
    if [ -n "$model" ]; then
        __cc_model_value="$model"
        __cc_model_source="${model_source:-cc-mode}"
        if [ "$model" = "track-latest" ]; then
            __cc_model_args=()
        else
            __cc_model_args=(--model "$model")
        fi
        __cc_log "model: $__cc_model_value (source=$__cc_model_source, from .cc-mode)"
    else
        local __cc_role
        case "${mode:-}" in
            exploration) __cc_role=explore ;;
            build)       __cc_role=build ;;
            branched)    __cc_role=branched-worker ;;
            *)           __cc_role=explore ;;
        esac
        __cc_log "no model stamp in .cc-mode (pre-policy session); resolving role $__cc_role"
        __cc_model_prepare "$__cc_role" || return 1
    fi

    # Permission mode on resume. Order differs from the model's ON PURPOSE:
    # $CC_PERM_MODE wins even here. The model is pinned to the .cc-mode stamp
    # because the session's CONTEXT was built by that model and swapping it
    # mid-history is a real change; a permission mode carries no such
    # continuity -- it only governs what the next turn is allowed to do -- so
    # the stated override is allowed to apply to a resume as well.
    # Absent the env var the stamp replays, so a session deliberately launched
    # under an override does not quietly drop back to the settings default.
    # A .cc-mode written before this stamp existed has NO perm_mode_source line
    # at all, which is what distinguishes it from a stamped settings-default
    # (perm_mode empty, perm_mode_source=settings-default); that one resolves by
    # role instead. The stamp is validated on replay too -- a hand-edited
    # .cc-mode must not be able to kill the resumed session at launch.
    local __cc_perm_value __cc_perm_source
    local -a __cc_perm_args
    if [ -n "${CC_PERM_MODE:-}" ]; then
        __cc_perm_stage "$CC_PERM_MODE" "env" || return 1
    elif [ -n "$perm_mode_source" ]; then
        __cc_perm_stage "$perm_mode" "$perm_mode_source, from .cc-mode" || return 1
    else
        local __cc_perm_role
        case "${mode:-}" in
            exploration) __cc_perm_role=explore ;;
            build)       __cc_perm_role=build ;;
            branched)    __cc_perm_role=branched-worker ;;
            *)           __cc_perm_role=explore ;;
        esac
        __cc_log "no perm-mode stamp in .cc-mode (pre-policy session); resolving role $__cc_perm_role"
        __cc_perm_prepare "$__cc_perm_role" || return 1
    fi

    case "${mode:-}" in
        exploration)
            __cc_log "CONTINUE (was EXPLORE: slug=${slug:-?}, started=${started_at:-?})"
            # Re-locate the sandbox settings file inside the worktree.
            local sandbox_settings
            if sandbox_settings=$(__cc_find_sandbox_settings); then
                __cc_log "sandbox settings: $sandbox_settings"
                CC_SESSION_ID="$session_id" claude "${__cc_model_args[@]}" "${__cc_perm_args[@]}" --continue --settings "$sandbox_settings"
            else
                # Settings file missing (e.g. deleted manually); recreate in cwd.
                __cc_write_sandbox_settings "$(pwd)"
                __cc_log "sandbox settings recreated at $(pwd)/.cc-sandbox-settings.json"
                CC_SESSION_ID="$session_id" claude "${__cc_model_args[@]}" "${__cc_perm_args[@]}" --continue --settings "$(pwd)/.cc-sandbox-settings.json"
            fi
            ;;
        build)
            # Always confirm before resuming build mode — resuming a stale
            # .cc-mode under a permissive mode is a real footgun. Show the mode
            # that was actually resolved rather than asserting a fixed one.
            printf '\033[01;33m[cc] CONTINUE in BUILD mode (perm-mode: %s):\033[00m\n' \
                "${__cc_perm_value:-settings-default}" >&2
            printf '     started_at: %s\n     parent_repo: %s\n' "${started_at:-?}" "${parent_repo:-?}" >&2
            printf '     Continue? [y/N] ' >&2
            read -r confirm
            case "$confirm" in
                y|Y|yes|YES) ;;
                *) __cc_die "cc-continue cancelled"; return 1 ;;
            esac
            __cc_log "CONTINUE (was BUILD)"
            CC_SESSION_ID="$session_id" claude "${__cc_model_args[@]}" "${__cc_perm_args[@]}" --continue
            ;;
        *)
            __cc_die "unknown mode in .cc-mode: ${mode:-<empty>}"
            return 1
            ;;
    esac
}

# ---- cc (no args — command center launcher) ----
# The EA used to be launched with a hardcoded --dangerously-skip-permissions
# (spec §4.3 "known gap"). It now resolves role "ea" like everything else, so
# settings.json permissions.defaultMode governs unless someone states otherwise.
cc() {
    # Snapshot guard — see "why the helpers are named __cc_*" at the top of this
    # file. Re-source if the helpers are absent; abort before any side effects.
    typeset -f __cc_die >/dev/null 2>&1 || \
        . "${CC_FUNCTIONS_SH:-$HOME/.claude/cc-functions.sh}" 2>/dev/null
    typeset -f __cc_die >/dev/null 2>&1 || {
        printf '[cc] %s: cc helpers unavailable (tried %s); aborting before side effects\n' \
            'cc' "${CC_FUNCTIONS_SH:-$HOME/.claude/cc-functions.sh}" >&2
        return 127
    }
    local cc_workspace="$HOME/vault/20-surface/company/_command-center"

    if [ ! -d "$cc_workspace" ]; then
        __cc_die "command center workspace not found at $cc_workspace; run Phase 1 setup"
        return 1
    fi

    if ! command -v tmux >/dev/null 2>&1; then
        __cc_die "tmux is required for Phase 2; install with: sudo apt install tmux"
        return 1
    fi

    local tmux_name
    tmux_name=$(__cc_company_tmux_session)

    # If the company tmux session already exists, just attach. The CC window
    # may already be running; don't disturb it.
    if __cc_company_tmux_exists; then
        __cc_log "attaching to existing company tmux session"
        tmux attach-session -t "$tmux_name"
        return $?
    fi

    # Otherwise, create the session detached, write a CC .cc-mode and tree slot,
    # then attach. The first window (named "cc") runs claude in the CC workspace.
    local session_id
    session_id=$(__cc_mint_session_id)

    # The EA session picks its model up HERE, from policy role "ea" -- this is
    # the launch that silently landed on Fable 5 when nothing pinned a model.
    local __cc_model_value __cc_model_source
    local -a __cc_model_args
    __cc_model_prepare ea || return 1

    local __cc_perm_value __cc_perm_source
    local -a __cc_perm_args
    __cc_perm_prepare ea || return 1

    __cc_write_mode_file "$cc_workspace" command-center cc "$cc_workspace" "$session_id" "" \
        "$__cc_model_value" "$__cc_model_source" "$__cc_perm_value" "$__cc_perm_source"

    __cc_log "COMMAND CENTER: session_id=$session_id model=$__cc_model_value ($__cc_model_source)"

    # Create tmux session with first window in the CC workspace running claude.
    #
    # tmux takes a command STRING, so the model and permission flags are
    # rendered with %q rather than passed as an argv array. CC_SESSION_ID goes
    # in as a per-command prefix inside that string -- NOT via
    # `tmux new-session -e`, which would put it in the tmux session environment
    # and leak it into every window created later, including every cc-branch
    # child.
    local model_flag perm_flag
    model_flag=$(__cc_model_flag_str)
    perm_flag=$(__cc_perm_flag_str)
    tmux new-session -d -s "$tmux_name" -n "cc" -c "$cc_workspace" \
        "CC_SESSION_ID=$(printf '%q' "$session_id") claude${model_flag}${perm_flag}"
    tmux attach-session -t "$tmux_name"
}

# ---- cc-branch <task-id> [<repo-path>] ----
# Children used to be launched with a hardcoded --dangerously-skip-permissions
# (spec §4.3 "known gap"), which silently out-voted settings.json
# permissions.defaultMode for every task this company delegates. They now
# resolve role "branched-worker" like everything else.
cc-branch() {
    # Snapshot guard — see "why the helpers are named __cc_*" at the top of this
    # file. Re-source if the helpers are absent; abort before any side effects.
    typeset -f __cc_die >/dev/null 2>&1 || \
        . "${CC_FUNCTIONS_SH:-$HOME/.claude/cc-functions.sh}" 2>/dev/null
    typeset -f __cc_die >/dev/null 2>&1 || {
        printf '[cc] %s: cc helpers unavailable (tried %s); aborting before side effects\n' \
            'cc-branch' "${CC_FUNCTIONS_SH:-$HOME/.claude/cc-functions.sh}" >&2
        return 127
    }
    local task_id="${1:-}"
    local repo_arg="${2:-}"

    if [ -z "$task_id" ]; then
        __cc_die "usage: cc-branch <task-id> [<repo-path>]"
        return 1
    fi

    if ! [[ "$task_id" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
        __cc_die "task_id may only contain [a-zA-Z0-9_./-] (got: $task_id)"
        return 1
    fi

    if ! command -v tmux >/dev/null 2>&1; then
        __cc_die "tmux required for cc-branch"
        return 1
    fi

    # Resolve repo. Prefer explicit arg; fall back to caller's repo root.
    # cc-branch always operates against a real git repo so it can create a
    # per-task worktree (the child's isolated identity lives in its .cc-mode).
    local repo_root
    if [ -n "$repo_arg" ]; then
        if [ ! -d "$repo_arg" ]; then
            __cc_die "repo-path does not exist: $repo_arg"
            return 1
        fi
        repo_root=$(git -C "$repo_arg" rev-parse --show-toplevel 2>/dev/null) || {
            __cc_die "repo-path is not a git repo: $repo_arg"
            return 1
        }
    else
        repo_root=$(__cc_repo_root) || {
            __cc_die "not in a git repo; pass <repo-path> explicitly"
            return 1
        }
    fi

    # Resolve the model BEFORE anything is created. A refusal here must leave
    # no worktree, no branch and no tmux window behind -- cc-branch has no
    # `set -e`, and a half-spawn is exactly the failure mode the __cc_* rename
    # and the snapshot guards were introduced to kill. Role "branched-worker";
    # override one spawn with:  CC_MODEL=opus cc-branch <task-id> [<repo-path>]
    # which lands in the child's .cc-mode as model_source=env, so an override
    # is as visible in the tree as a policy choice is.
    local __cc_model_value __cc_model_source
    local -a __cc_model_args
    __cc_model_prepare branched-worker || return 1

    # Permission mode, resolved under the same before-any-side-effect rule.
    # Override one spawn with:  CC_PERM_MODE=bypassPermissions cc-branch <task-id>
    # which lands in the child's .cc-mode as perm_mode_source=env, so an
    # override is as visible in the tree as a policy choice is.
    local __cc_perm_value __cc_perm_source
    local -a __cc_perm_args
    __cc_perm_prepare branched-worker || return 1

    # Parent identity comes from the caller's nearest .cc-mode (the calling
    # session's). For the EA this returns its own session_id. CC_PARENT_ID is an
    # explicit override for callers that have no .cc-mode above cwd.
    #
    # Getting this wrong is quiet and costly. An EMPTY parent_id detaches the
    # child from the tree: no spawned event, and its completion never reaches a
    # parent. A STALE repo-root .cc-mode is worse — it yields a non-empty but
    # WRONG parent, attaching the child to a session that will never see it.
    # Both used to pass silently, so resolve and then say out loud what we got.
    local mode_data parent_session_id=""
    if mode_data=$(__cc_read_mode 2>/dev/null); then
        parent_session_id=$(printf '%s\n' "$mode_data" | grep '^session_id=' | cut -d= -f2-)
    fi
    [ -z "$parent_session_id" ] && parent_session_id="${CC_PARENT_ID:-}"

    local tree_dir="$HOME/vault/20-surface/company/tree/sessions"
    if [ -z "$parent_session_id" ]; then
        __cc_log "WARNING: no parent session_id (no .cc-mode above $(pwd), CC_PARENT_ID unset)."
        __cc_log "         this child will be UNPARENTED — no spawned or completion event"
        __cc_log "         will reach a parent session. If you meant to spawn from a session,"
        __cc_log "         run cc-branch from THAT session's directory (do not 'cd' into the"
        __cc_log "         repo first — pass it as the argument), or export CC_PARENT_ID."
    elif [ -d "$tree_dir" ] && [ ! -f "$tree_dir/${parent_session_id}.md" ]; then
        __cc_log "WARNING: parent session_id=$parent_session_id has no tree slot in $tree_dir."
        __cc_log "         the .cc-mode above $(pwd) is probably STALE, which would attach this"
        __cc_log "         child to a dead session. Verify before relying on tree linkage."
    fi

    # Worktree per child. Mirrors cc-explore's pattern so .cc-mode never
    # clobbers the parent's in a shared repo. task_id is sanitized for
    # filesystem use (slashes → dashes); the git branch keeps the slashes.
    local repo_name task_id_safe worktree branch
    repo_name=$(basename "$repo_root")
    task_id_safe="${task_id//\//-}"
    worktree="${repo_root%/*}/${repo_name}-branch-${task_id_safe}"
    branch="branch/${task_id}"

    if [ -d "$worktree" ]; then
        __cc_log "worktree already exists at $worktree — reusing"
    else
        if git -C "$repo_root" show-ref --verify --quiet "refs/heads/${branch}"; then
            git -C "$repo_root" worktree add "$worktree" "$branch" || return 1
        else
            git -C "$repo_root" worktree add "$worktree" -b "$branch" || return 1
        fi
    fi

    # Child identity: fresh session_id + parent_id from caller. Written to the
    # worktree so the child's session-start reads it via cc-tree-slot-write.sh.
    local child_session_id
    child_session_id=$(__cc_mint_session_id)

    __cc_write_mode_file "$worktree" branched "$task_id" "$repo_root" "$child_session_id" "$parent_session_id" \
        "$__cc_model_value" "$__cc_model_source" "$__cc_perm_value" "$__cc_perm_source"

    # A cc-branch child is autonomous by construction: nobody is watching its
    # pane when it starts. Vouch for the worktree we just created so it cannot
    # stall on the workspace trust dialog. Never fatal.
    __cc_trust_register "$worktree"

    __cc_company_tmux_ensure

    local tmux_name window_name
    tmux_name=$(__cc_company_tmux_session)
    window_name="$task_id"

    # If a window with this name already exists, warn and refuse.
    if tmux list-windows -t "$tmux_name" -F '#{window_name}' 2>/dev/null | grep -Fxq "$window_name"; then
        __cc_die "a window named '$window_name' already exists in tmux session '$tmux_name'; pick a different task_id or teleport into the existing window"
        return 1
    fi

    __cc_log "cc-branch: task=$task_id parent=$parent_session_id child=$child_session_id"
    __cc_log "          worktree=$worktree"
    __cc_log "          model=$__cc_model_value ($__cc_model_source)"
    __cc_log "          perm-mode=${__cc_perm_value:-settings-default} ($__cc_perm_source)"

    # Identity travels via the worktree's .cc-mode.
    #
    # CC_SESSION_ID carries the CHILD's id (not the parent's) and is a
    # per-command prefix inside the tmux command string -- never `new-window
    # -e`, which would write it into the tmux session environment where the
    # next window would inherit a stale id and be refused exit 3.
    local model_flag perm_flag
    model_flag=$(__cc_model_flag_str)
    perm_flag=$(__cc_perm_flag_str)
    tmux new-window -d -t "$tmux_name" -n "$window_name" -c "$worktree" \
        "CC_SESSION_ID=$(printf '%q' "$child_session_id") claude${model_flag}${perm_flag}"

    __cc_log "branched: tmux window '$window_name' in session '$tmux_name'"
}

# ---- cc-teleport <task-id> ----
cc-teleport() {
    # Snapshot guard — see "why the helpers are named __cc_*" at the top of this
    # file. Re-source if the helpers are absent; abort before any side effects.
    typeset -f __cc_die >/dev/null 2>&1 || \
        . "${CC_FUNCTIONS_SH:-$HOME/.claude/cc-functions.sh}" 2>/dev/null
    typeset -f __cc_die >/dev/null 2>&1 || {
        printf '[cc] %s: cc helpers unavailable (tried %s); aborting before side effects\n' \
            'cc-teleport' "${CC_FUNCTIONS_SH:-$HOME/.claude/cc-functions.sh}" >&2
        return 127
    }
    local target="${1:-}"

    if [ -z "$target" ]; then
        __cc_die "usage: cc-teleport <task-id>"
        return 1
    fi

    if ! command -v tmux >/dev/null 2>&1; then
        __cc_die "tmux required for cc-teleport"
        return 1
    fi

    local tmux_name
    tmux_name=$(__cc_company_tmux_session)

    if ! __cc_company_tmux_exists; then
        __cc_die "no company tmux session running; launch with: cc"
        return 1
    fi

    # Confirm window exists.
    if ! tmux list-windows -t "$tmux_name" -F '#{window_name}' 2>/dev/null | grep -Fxq "$target"; then
        __cc_die "no window named '$target' in tmux session '$tmux_name'; list with: tmux list-windows -t $tmux_name"
        return 1
    fi

    # If we're inside the same tmux session, select. Otherwise, attach with -t.
    if [ -n "${TMUX:-}" ] && [ "$(tmux display -p '#S')" = "$tmux_name" ]; then
        tmux select-window -t "${tmux_name}:${target}"
    else
        tmux attach-session -t "${tmux_name}:${target}"
    fi
}

# ---- cc-doctor (delegates to script) ----
cc-doctor() {
    # Snapshot guard — see "why the helpers are named __cc_*" at the top of this
    # file. Re-source if the helpers are absent; abort before any side effects.
    typeset -f __cc_die >/dev/null 2>&1 || \
        . "${CC_FUNCTIONS_SH:-$HOME/.claude/cc-functions.sh}" 2>/dev/null
    typeset -f __cc_die >/dev/null 2>&1 || {
        printf '[cc] %s: cc helpers unavailable (tried %s); aborting before side effects\n' \
            'cc-doctor' "${CC_FUNCTIONS_SH:-$HOME/.claude/cc-functions.sh}" >&2
        return 127
    }
    bash ~/environment-foundation/software/development/claude-code/scripts/doctor.sh "$@"
}

# ---- export to subshells ----
# Public wrappers depend on internal __cc_* helpers; export both so subshells
# (e.g. `bash -c 'cc-explore foo'`) don't fail with "__cc_repo_root: not found".
export -f __cc_color_or_plain __cc_die __cc_log __cc_repo_root __cc_mint_session_id \
          __cc_mode_quote __cc_mode_unquote __cc_write_mode_file __cc_write_sandbox_settings \
          __cc_read_mode __cc_find_sandbox_settings \
          __cc_model_policy_path __cc_resolve_model __cc_model_prepare __cc_model_flag_str \
          __cc_resolve_perm __cc_perm_modes __cc_perm_stage __cc_perm_prepare __cc_perm_flag_str \
          __cc_trust_effective __cc_trust_register \
          __cc_company_tmux_session __cc_company_tmux_exists __cc_company_tmux_ensure \
          cc cc-branch cc-teleport cc-explore cc-build cc-continue cc-doctor 2>/dev/null || true
