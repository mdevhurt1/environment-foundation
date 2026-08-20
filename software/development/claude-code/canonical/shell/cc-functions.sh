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

__cc_write_mode_file() {
    # $1 = directory, $2 = mode, $3 = slug, $4 = parent_repo,
    # $5 = session_id, $6 = parent_id (may be empty for top-level launches),
    # $7 = model (resolved value: track-latest | tier alias | exact id),
    # $8 = model_source (env | policy:<role>)
    # Scrub newlines and '=' from session_id/parent_id at the write boundary
    # so a malformed CC_PARENT_ID cannot inject extra .cc-mode keys. model and
    # model_source are scrubbed of whitespace as well: the statusline SOURCES
    # this file, so a value containing a space would break its shell parse.
    local _sid _pid _model _msrc
    _sid=$(printf '%s' "$5" | tr -d '\n=')
    _pid=$(printf '%s' "${6:-}" | tr -d '\n=')
    _model=$(printf '%s' "${7:-}" | tr -d "\n= \t")
    _msrc=$(printf '%s' "${8:-}" | tr -d "\n= \t")
    cat > "$1/.cc-mode" <<EOF
mode=$2
slug=$3
started_at=$(date -Iseconds)
parent_repo=$4
session_id=$_sid
parent_id=$_pid
model=$_model
model_source=$_msrc
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
        "$__cc_model_value" "$__cc_model_source"
    __cc_write_sandbox_settings "$worktree"

    __cc_log "EXPLORE mode: sandboxed (--settings), branch=$branch, worktree=$worktree"
    cd "$worktree" || return 1
    # CC_SESSION_ID is a per-command PREFIX, never an export. The tree-slot
    # helpers treat it as an ASSERTION and refuse (exit 3) when it disagrees
    # with the resolved .cc-mode, so a value that outlived this launch would
    # turn the NEXT session's /start into a hard failure. Same reason the
    # ANTHROPIC_MODEL/tmux-setenv route was rejected: env state that survives
    # the process leaks into every later spawn.
    CC_SESSION_ID="$session_id" claude "${__cc_model_args[@]}" --settings "$worktree/.cc-sandbox-settings.json"
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

    __cc_write_mode_file "$repo_root" build "${repo_name}" "$repo_root" "$session_id" "${CC_PARENT_ID:-}" \
        "$__cc_model_value" "$__cc_model_source"
    __cc_log "BUILD mode: full perms, no prompts"
    # CC_SESSION_ID is a per-command PREFIX, never an export. The tree-slot
    # helpers treat it as an ASSERTION and refuse (exit 3) when it disagrees
    # with the resolved .cc-mode, so a value that outlived this launch would
    # turn the NEXT session's /start into a hard failure. Same reason the
    # ANTHROPIC_MODEL/tmux-setenv route was rejected: env state that survives
    # the process leaks into every later spawn.
    CC_SESSION_ID="$session_id" claude "${__cc_model_args[@]}" --dangerously-skip-permissions
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
    while IFS='=' read -r key val; do
        case "$key" in
            mode)         mode="$val" ;;
            slug)         slug="$val" ;;
            started_at)   started_at="$val" ;;
            parent_repo)  parent_repo="$val" ;;
            session_id)   session_id="$val" ;;
            model)        model="$val" ;;
            model_source) model_source="$val" ;;
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

    case "${mode:-}" in
        exploration)
            __cc_log "CONTINUE (was EXPLORE: slug=${slug:-?}, started=${started_at:-?})"
            # Re-locate the sandbox settings file inside the worktree.
            local sandbox_settings
            if sandbox_settings=$(__cc_find_sandbox_settings); then
                __cc_log "sandbox settings: $sandbox_settings"
                CC_SESSION_ID="$session_id" claude "${__cc_model_args[@]}" --continue --settings "$sandbox_settings"
            else
                # Settings file missing (e.g. deleted manually); recreate in cwd.
                __cc_write_sandbox_settings "$(pwd)"
                __cc_log "sandbox settings recreated at $(pwd)/.cc-sandbox-settings.json"
                CC_SESSION_ID="$session_id" claude "${__cc_model_args[@]}" --continue --settings "$(pwd)/.cc-sandbox-settings.json"
            fi
            ;;
        build)
            # Always confirm before resuming build mode — stale .cc-mode with
            # --dangerously-skip-permissions is a real footgun.
            printf '\033[01;33m[cc] CONTINUE in BUILD mode (full perms, no prompts):\033[00m\n' >&2
            printf '     started_at: %s\n     parent_repo: %s\n' "${started_at:-?}" "${parent_repo:-?}" >&2
            printf '     Continue? [y/N] ' >&2
            read -r confirm
            case "$confirm" in
                y|Y|yes|YES) ;;
                *) __cc_die "cc-continue cancelled"; return 1 ;;
            esac
            __cc_log "CONTINUE (was BUILD)"
            CC_SESSION_ID="$session_id" claude "${__cc_model_args[@]}" --dangerously-skip-permissions --continue
            ;;
        *)
            __cc_die "unknown mode in .cc-mode: ${mode:-<empty>}"
            return 1
            ;;
    esac
}

# ---- cc (no args — command center launcher) ----
# NOTE: --dangerously-skip-permissions is intentional here; see spec §4.3
# for the "known gap" acceptance. Closes when Phase 5 sandbox profiles land.
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

    __cc_write_mode_file "$cc_workspace" command-center cc "$cc_workspace" "$session_id" "" \
        "$__cc_model_value" "$__cc_model_source"

    __cc_log "COMMAND CENTER: session_id=$session_id model=$__cc_model_value ($__cc_model_source)"

    # Create tmux session with first window in the CC workspace running claude.
    # The EA orchestrates from a trusted workspace and would prompt-thrash
    # without --dangerously-skip-permissions.
    #
    # tmux takes a command STRING, so the model flag is rendered with %q rather
    # than passed as an argv array. CC_SESSION_ID goes in as a per-command
    # prefix inside that string -- NOT via `tmux new-session -e`, which would
    # put it in the tmux session environment and leak it into every window
    # created later, including every cc-branch child.
    local model_flag
    model_flag=$(__cc_model_flag_str)
    tmux new-session -d -s "$tmux_name" -n "cc" -c "$cc_workspace" \
        "CC_SESSION_ID=$(printf '%q' "$session_id") claude${model_flag} --dangerously-skip-permissions"
    tmux attach-session -t "$tmux_name"
}

# ---- cc-branch <task-id> [<repo-path>] ----
# NOTE: --dangerously-skip-permissions is intentional here; see spec §4.3
# for the "known gap" acceptance. Closes when Phase 5 sandbox profiles land.
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
        "$__cc_model_value" "$__cc_model_source"

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

    # Branched sessions run with --dangerously-skip-permissions to match the
    # EA: orchestration is impractical when every tool call prompts. Identity
    # travels via the worktree's .cc-mode.
    #
    # CC_SESSION_ID carries the CHILD's id (not the parent's) and is a
    # per-command prefix inside the tmux command string -- never `new-window
    # -e`, which would write it into the tmux session environment where the
    # next window would inherit a stale id and be refused exit 3.
    local model_flag
    model_flag=$(__cc_model_flag_str)
    tmux new-window -d -t "$tmux_name" -n "$window_name" -c "$worktree" \
        "CC_SESSION_ID=$(printf '%q' "$child_session_id") claude${model_flag} --dangerously-skip-permissions"

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
export -f __cc_color_or_plain __cc_die __cc_log __cc_repo_root __cc_mint_session_id __cc_write_mode_file __cc_write_sandbox_settings \
          __cc_read_mode __cc_find_sandbox_settings \
          __cc_model_policy_path __cc_resolve_model __cc_model_prepare __cc_model_flag_str \
          __cc_company_tmux_session __cc_company_tmux_exists __cc_company_tmux_ensure \
          cc cc-branch cc-teleport cc-explore cc-build cc-continue cc-doctor 2>/dev/null || true
