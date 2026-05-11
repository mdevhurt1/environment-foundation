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

# ---- internal helpers ----
_cc_color_or_plain() {
    if [ -t 2 ] && [ "${TERM:-dumb}" != "dumb" ]; then
        printf '%s' "$1"
    fi
}
_cc_die() {
    printf '%s[cc] %s%s\n' "$(_cc_color_or_plain $'\033[01;31m')" "$*" "$(_cc_color_or_plain $'\033[00m')" >&2
    return 1
}
_cc_log() {
    printf '%s[cc] %s%s\n' "$(_cc_color_or_plain $'\033[01;36m')" "$*" "$(_cc_color_or_plain $'\033[00m')" >&2
}

_cc_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

_cc_mint_session_id() {
    # 22-char hex ID derived from uuidgen. Falls back to /dev/urandom on
    # systems without uuidgen (rare on Ubuntu).
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr -d '-' | head -c 22
    else
        head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 22
    fi
}

_cc_write_mode_file() {
    # $1 = directory, $2 = mode, $3 = slug, $4 = parent_repo,
    # $5 = session_id, $6 = parent_id (may be empty for top-level launches)
    cat > "$1/.cc-mode" <<EOF
mode=$2
slug=$3
started_at=$(date -Iseconds)
parent_repo=$4
session_id=$5
parent_id=${6:-}
EOF
}

# Write sandbox settings into the worktree so --settings can inject them.
# $1 = worktree directory path
_cc_write_sandbox_settings() {
    local dir="$1"
    printf '%s\n' '{"sandbox":{"enabled":true,"failIfUnavailable":true}}' \
        > "$dir/.cc-sandbox-settings.json"
}

_cc_read_mode() {
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
_cc_find_sandbox_settings() {
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
    local slug="${1:-adhoc}"

    if ! [[ "$slug" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        _cc_die "slug must match [a-zA-Z0-9_-]+ (got: $slug)"
        return 1
    fi

    local repo_root
    repo_root=$(_cc_repo_root) || { _cc_die "not in a git repo"; return 1; }
    [ "$(pwd)" = "$repo_root" ] || { _cc_die "must be at repo root: $repo_root"; return 1; }

    local repo_name worktree branch
    repo_name=$(basename "$repo_root")
    worktree="../${repo_name}-explore-${slug}"
    branch="explore/${slug}"

    if [ -d "$worktree" ]; then
        _cc_log "worktree already exists at $worktree — reusing"
    else
        # If the branch already exists (e.g. worktree was pruned), add without -b.
        if git show-ref --verify --quiet "refs/heads/${branch}"; then
            git worktree add "$worktree" "$branch" || return 1
        else
            git worktree add "$worktree" -b "$branch" || return 1
        fi
    fi

    local session_id
    session_id=$(_cc_mint_session_id)
    _cc_write_mode_file "$worktree" exploration "$slug" "$repo_root" "$session_id" "${CC_PARENT_ID:-}"
    _cc_write_sandbox_settings "$worktree"

    _cc_log "EXPLORE mode: sandboxed (--settings), branch=$branch, worktree=$worktree"
    cd "$worktree" || return 1
    claude --settings "$worktree/.cc-sandbox-settings.json"
}

# ---- cc-build ----
cc-build() {
    local repo_root
    repo_root=$(_cc_repo_root) || { _cc_die "not in a git repo"; return 1; }
    [ "$(pwd)" = "$repo_root" ] || { _cc_die "must be at repo root: $repo_root"; return 1; }

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
        _cc_die "build mode requires a plan or spec; brainstorm first (cc-explore)"
        return 1
    fi

    local session_id
    session_id=$(_cc_mint_session_id)
    _cc_write_mode_file "$repo_root" build "${repo_name}" "$repo_root" "$session_id" "${CC_PARENT_ID:-}"
    _cc_log "BUILD mode: full perms, no prompts"
    claude --dangerously-skip-permissions
}

# ---- cc-continue ----
cc-continue() {
    # Only accept a worktree directory as an argument; plan-file branch dropped.
    if [ -n "${1:-}" ]; then
        if [ -d "$1" ]; then
            cd "$1" || return 1
        else
            _cc_die "no worktree dir named: $1"
            return 1
        fi
    fi

    local mode_data
    mode_data=$(_cc_read_mode) || { _cc_die "no .cc-mode found upward from cwd"; return 1; }

    # Parse .cc-mode into local vars — do NOT export; exporting leaks into the
    # caller's interactive shell and poisons the next claude invocation.
    local mode="" slug="" started_at="" parent_repo=""
    while IFS='=' read -r key val; do
        case "$key" in
            mode)        mode="$val" ;;
            slug)        slug="$val" ;;
            started_at)  started_at="$val" ;;
            parent_repo) parent_repo="$val" ;;
        esac
    done <<< "$mode_data"

    case "${mode:-}" in
        exploration)
            _cc_log "CONTINUE (was EXPLORE: slug=${slug:-?}, started=${started_at:-?})"
            # Re-locate the sandbox settings file inside the worktree.
            local sandbox_settings
            if sandbox_settings=$(_cc_find_sandbox_settings); then
                _cc_log "sandbox settings: $sandbox_settings"
                claude --continue --settings "$sandbox_settings"
            else
                # Settings file missing (e.g. deleted manually); recreate in cwd.
                _cc_write_sandbox_settings "$(pwd)"
                _cc_log "sandbox settings recreated at $(pwd)/.cc-sandbox-settings.json"
                claude --continue --settings "$(pwd)/.cc-sandbox-settings.json"
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
                *) _cc_die "cc-continue cancelled"; return 1 ;;
            esac
            _cc_log "CONTINUE (was BUILD)"
            claude --dangerously-skip-permissions --continue
            ;;
        *)
            _cc_die "unknown mode in .cc-mode: ${mode:-<empty>}"
            return 1
            ;;
    esac
}

# ---- cc (no args — command center launcher) ----
cc() {
    local cc_workspace="$HOME/vault/20-surface/company/_command-center"

    if [ ! -d "$cc_workspace" ]; then
        _cc_die "command center workspace not found at $cc_workspace; run Phase 1 setup"
        return 1
    fi

    # Write a .cc-mode for the command center session if missing or stale.
    # CC sessions are top-level (parent_id empty) and the slug is "cc".
    local session_id
    session_id=$(_cc_mint_session_id)
    _cc_write_mode_file "$cc_workspace" command-center cc "$cc_workspace" "$session_id" ""

    _cc_log "COMMAND CENTER: session_id=$session_id"
    cd "$cc_workspace" || return 1
    claude
}

# ---- cc-doctor (delegates to script) ----
cc-doctor() {
    bash ~/environment-foundation/software/development/claude-code/scripts/doctor.sh "$@"
}

# ---- export to subshells ----
# Public wrappers depend on internal _cc_* helpers; export both so subshells
# (e.g. `bash -c 'cc-explore foo'`) don't fail with "_cc_repo_root: not found".
export -f _cc_color_or_plain _cc_die _cc_log _cc_repo_root _cc_mint_session_id _cc_write_mode_file _cc_write_sandbox_settings \
          _cc_read_mode _cc_find_sandbox_settings \
          cc cc-explore cc-build cc-continue cc-doctor 2>/dev/null || true
