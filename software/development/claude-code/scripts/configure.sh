#!/usr/bin/env bash
# Description: Deploys the canonical Claude Code dotfiles into ~/.claude/
#              via symlinks, sources cc-functions.sh from ~/.bashrc, and
#              points the user at environment-secrets for sops setup.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: claude installed (install.sh)
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root
require_command claude "install Claude Code first: bash $SCRIPT_DIR/install.sh"
require_command jq

CLAUDE_DIR="$HOME/.claude"
CANONICAL="$REPO_ROOT/software/development/claude-code/canonical"
BACKUP_DIR="$CLAUDE_DIR/.backup-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$CLAUDE_DIR"

# ---- backup any non-symlink files we're about to replace ----
backup_if_real() {
    local target="$1"
    if [ -e "$target" ] && [ ! -L "$target" ]; then
        mkdir -p "$BACKUP_DIR"
        local rel="${target#"$CLAUDE_DIR"/}"
        mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
        mv "$target" "$BACKUP_DIR/$rel"
        log_warn "backed up existing $target -> $BACKUP_DIR/$rel"
    fi
}

# ---- symlink each canonical file/dir ----
link() {
    local src="$1" dst="$2"
    backup_if_real "$dst"
    ln -sfn "$src" "$dst"
    log_ok "linked $dst -> $src"
}

log_info "Deploying canonical dotfiles from $CANONICAL"
link "$CANONICAL/CLAUDE.md"               "$CLAUDE_DIR/CLAUDE.md"
link "$CANONICAL/settings.json"           "$CLAUDE_DIR/settings.json"
link "$CANONICAL/statusline-command.sh"   "$CLAUDE_DIR/statusline-command.sh"

# Skills: link the whole dir, but only after warning if there are existing
# non-canonical skills that would be hidden.
if [ -d "$CLAUDE_DIR/skills" ] && [ ! -L "$CLAUDE_DIR/skills" ]; then
    existing=$(find "$CLAUDE_DIR/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    if [ "$existing" -gt 0 ]; then
        log_warn "$CLAUDE_DIR/skills contains $existing skill(s); these will be moved to backup"
        log_warn "review them and copy any you want to canonical/skills/"
        backup_if_real "$CLAUDE_DIR/skills"
    else
        rmdir "$CLAUDE_DIR/skills"
    fi
fi
ln -sfn "$CANONICAL/skills" "$CLAUDE_DIR/skills"
log_ok "linked $CLAUDE_DIR/skills -> $CANONICAL/skills"

# cc-functions in a stable location too
link "$CANONICAL/shell/cc-functions.sh" "$CLAUDE_DIR/cc-functions.sh"

# Role->model policy. Portable intent, versioned in the repo; the wrappers
# resolve --model from it at launch. Machine-local model pins (if any) belong
# in settings.local.json, never in canonical/settings.json.
link "$CANONICAL/model-policy.json" "$CLAUDE_DIR/model-policy.json"

# Tree-slot helpers invoked from session-start / end-conversation skills.
# Kept as separate scripts (not skill-inline bash) so each runs in a single
# Bash tool call with self-contained shell state.
link "$CANONICAL/shell/cc-tree-slot-write.sh"  "$CLAUDE_DIR/cc-tree-slot-write.sh"
link "$CANONICAL/shell/cc-tree-slot-update.sh" "$CLAUDE_DIR/cc-tree-slot-update.sh"

# Ring-maintenance scanner, invoked from the ring-maintenance skill (Phase 1).
link "$CANONICAL/shell/cc-ring-scan.sh" "$CLAUDE_DIR/cc-ring-scan.sh"

# Agent roster. Same reasoning as skills: the whole directory is linked, so an
# agent added to canonical/agents/ is live on every configured machine without a
# second deploy step. Until 2026-09-03 this directory was the ONE canonical
# asset with no link at all -- ~/.claude/agents/ held a single local file that a
# fresh machine lost silently, because nothing referenced it from here and
# nothing checked for it. scripts/doctor.sh check 2d is the check that stops
# that recurring.
if [ -d "$CLAUDE_DIR/agents" ] && [ ! -L "$CLAUDE_DIR/agents" ]; then
    existing=$(find "$CLAUDE_DIR/agents" -mindepth 1 -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l)
    if [ "$existing" -gt 0 ]; then
        log_warn "$CLAUDE_DIR/agents contains $existing agent definition(s); these will be moved to backup"
        log_warn "review them and copy any you want to canonical/agents/"
        backup_if_real "$CLAUDE_DIR/agents"
    else
        rmdir "$CLAUDE_DIR/agents"
    fi
fi
ln -sfn "$CANONICAL/agents" "$CLAUDE_DIR/agents"
log_ok "linked $CLAUDE_DIR/agents -> $CANONICAL/agents"

# SessionStart injector for the vendored `using-superpowers` skill. Replaces the
# superpowers plugin's own hook, which we lost when the plugin was disabled over
# the brainstorming/writing-plans name collision. Registered in settings.json.
link "$CANONICAL/shell/cc-skills-inject.sh" "$CLAUDE_DIR/cc-skills-inject.sh"

# SessionStart injector for the compacted memory index (AI_ST-69): loads
# ~/vault/20-surface/claude-memory/MEMORY.md into every session, closing the
# write-side/load-side split the auto-memory location override created.
# Registered in settings.json. The regen helper rebuilds the index in its
# compacted one-line-per-memory form.
link "$CANONICAL/shell/cc-memory-inject.sh"      "$CLAUDE_DIR/cc-memory-inject.sh"
link "$CANONICAL/shell/cc-memory-index-regen.sh" "$CLAUDE_DIR/cc-memory-index-regen.sh"

# Plane bookend sync, invoked from session-start / end-conversation /
# ring-maintenance. Until INFRA-46 this was the one shipped helper with no
# link line, leaving the three skills on their skills/../shell/ fallback path.
link "$CANONICAL/shell/cc-plane-sync.sh" "$CLAUDE_DIR/cc-plane-sync.sh"

# PreToolUse gate for the CEO's 2026-09-04 standing rule: agents stage swept
# drafts, the CEO posts. Registered in settings.json as a Bash matcher, so it
# must be linked under $CLAUDE_DIR by the same name the hook command uses.
# Without this link the hook command silently does not exist, and a missing
# hook script fails OPEN -- which is the one failure mode this gate cannot
# have. doctor.sh check 12 is what notices.
link "$CANONICAL/shell/cc-outbound-guard.sh" "$CLAUDE_DIR/cc-outbound-guard.sh"

# Scrub arms. The files keep their .sh extension so the module-wide static
# gate still globs them; the deployed names drop it, because `cc-scrub` is
# what the operator and the docs call the tool (INFRA-59).
# These links are also the hooks' fallback path when a checkout has moved.
link "$CANONICAL/scripts/cc-scrub.sh"          "$CLAUDE_DIR/cc-scrub"
link "$CANONICAL/scripts/cc-scrub-outbound.sh" "$CLAUDE_DIR/cc-scrub-outbound"

# ---- git hooks: bind the scrub surfaces to the repository (INFRA-59) ----
#
# cc-scrub shipped with a measured pre-commit budget and was then bound to
# nothing, so it ran only when somebody remembered. The hooks are deployed
# the same way every other canonical asset is -- as symlinks, so editing
# canonical/hooks/ edits the live gate rather than forking it.
#
# Written into the repository's COMMON hooks directory, which is what
# `git rev-parse --git-path hooks` returns from any worktree. One install
# from the main checkout therefore arms every cc-branch worktree too:
# verified by probe, a linked worktree runs the common dir's hooks with its
# own root as cwd.
install_git_hooks() {
    local hooks_dir configured name src dst stamp

    if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        log_warn "$REPO_ROOT is not a git checkout — cc-scrub hooks skipped"
        return 0
    fi

    # An operator who set core.hooksPath has told git the hooks live
    # elsewhere. Installing into .git/hooks anyway would produce a hook git
    # never runs and a configure.sh that reported it installed — a gate that
    # is not there, reported as present, which is the worst outcome available.
    configured=$(git -C "$REPO_ROOT" config --get core.hooksPath || true)
    if [ -n "$configured" ]; then
        log_warn "core.hooksPath is set to '$configured' — cc-scrub hooks NOT installed"
        log_info "  git would ignore anything written to .git/hooks; install them there by hand"
        return 0
    fi

    hooks_dir=$(git -C "$REPO_ROOT" rev-parse --git-path hooks)
    case "$hooks_dir" in
        /*) ;;
        *) hooks_dir="$REPO_ROOT/$hooks_dir" ;;
    esac
    mkdir -p "$hooks_dir"

    stamp=$(date +%Y%m%d-%H%M%S)
    for name in pre-commit pre-push; do
        src="$CANONICAL/hooks/$name.sh"
        dst="$hooks_dir/$name"
        if [ ! -f "$src" ]; then
            log_warn "canonical hook missing: $src — $name not installed"
            continue
        fi
        # A real file here is the operator's own hook. .git/hooks is
        # untracked, so overwriting it is unrecoverable data loss; move it
        # aside where they will find it rather than into ~/.claude, which is
        # a different machine's concern.
        if [ -e "$dst" ] && [ ! -L "$dst" ]; then
            mv "$dst" "$dst.backup-$stamp"
            log_warn "backed up hook $dst -> $dst.backup-$stamp"
        fi
        ln -sfn "$src" "$dst"
        log_ok "installed git hook $name -> $src"
    done
}
install_git_hooks

# ---- ~/.bashrc source line (idempotent) ----
SOURCE_LINE='[ -f ~/.claude/cc-functions.sh ] && source ~/.claude/cc-functions.sh'
if ! grep -Fxq "$SOURCE_LINE" "$HOME/.bashrc" 2>/dev/null; then
    cat >> "$HOME/.bashrc" <<EOF

# Claude Code workflow wrappers (cc-explore, cc-build, cc-continue)
$SOURCE_LINE
EOF
    log_ok "added cc-functions source line to ~/.bashrc"
else
    log_info "$HOME/.bashrc already sources cc-functions.sh (skip)"
fi

# ---- settings.local.json: warn if missing ----
if [ ! -f "$CLAUDE_DIR/settings.local.json" ]; then
    log_warn "no $CLAUDE_DIR/settings.local.json found"
    log_info "clone environment-secrets and run its install.sh:"
    log_info "  git clone <gitea>/mhurt/environment-secrets ~/environment-secrets"
    log_info "  ~/environment-secrets/install.sh"
fi

# ---- summary ----
log_ok "Claude Code SOP configuration complete"
log_info "Open a new shell (or 'source ~/.bashrc') to pick up cc-* wrappers"
log_info "Run 'cc-doctor' to verify the install"
# The `|| true` is load-bearing: under `set -e`, a clean re-run (no backup
# made) would otherwise turn this final `&&` into exit status 1 (INFRA-51).
[ -d "$BACKUP_DIR" ] && log_info "Pre-install state preserved at: $BACKUP_DIR" || true
