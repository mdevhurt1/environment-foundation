#!/usr/bin/env bash
# Description: cc-doctor — drift detection for the Claude Code SOP install.
#              Checks the ~/.claude symlinks against canonical/, that canonical/
#              carries no secrets or absolute home paths, and that the shell
#              wrappers are wired up. Prints OK/WARN/FAIL per check and exits
#              non-zero if any FAIL.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: claude installed and configured (install.sh, configure.sh)
# Idempotent.

set -uo pipefail   # NOT -e: doctor must run all checks even if some fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

CANONICAL="$REPO_ROOT/software/development/claude-code/canonical"
CLAUDE_DIR="$HOME/.claude"

OK=0 WARN=0 FAIL=0

# Local reporters, not shared/logging.sh's log_*: these add ANSI colour and
# maintain the three counters the summary needs. Sourcing the shared library
# above is additive — log_*, require_command and require_not_root do not
# collide with ok/warn/fail/heading.
ok()   { printf '\033[01;32m[OK]\033[00m   %s\n' "$*"; OK=$((OK+1)); }
warn() { printf '\033[01;33m[WARN]\033[00m %s\n' "$*"; WARN=$((WARN+1)); }
fail() { printf '\033[01;31m[FAIL]\033[00m %s\n' "$*"; FAIL=$((FAIL+1)); }

heading() { printf '\n\033[01;34m== %s ==\033[00m\n' "$*"; }

# ---- 1. Symlinks point to canonical ----
heading "Symlinks"
check_symlink() {
    local link="$1" expect="$2"
    if [ ! -e "$link" ]; then fail "$link missing"; return; fi
    if [ ! -L "$link" ]; then warn "$link exists but is not a symlink (drift)"; return; fi
    actual=$(readlink "$link")
    if [ "$actual" = "$expect" ]; then
        ok "$link -> $expect"
    else
        fail "$link -> $actual (expected $expect)"
    fi
}
check_symlink "$CLAUDE_DIR/CLAUDE.md"             "$CANONICAL/CLAUDE.md"
check_symlink "$CLAUDE_DIR/settings.json"         "$CANONICAL/settings.json"
check_symlink "$CLAUDE_DIR/statusline-command.sh" "$CANONICAL/statusline-command.sh"
check_symlink "$CLAUDE_DIR/skills"                "$CANONICAL/skills"
check_symlink "$CLAUDE_DIR/cc-functions.sh"       "$CANONICAL/shell/cc-functions.sh"

# ---- 2. canonical/ contains no secrets, no /home/<user>/ paths ----
heading "Canonical safety"
# Match secret VALUES, not variable-name references. Documentation that mentions
# "$PLANE_API_KEY" or describes which env vars to set is not a leak; an actual
# secret string in canonical is. Add new value-shape patterns here as new
# services are integrated.
secret_pattern='(sk-[a-zA-Z0-9]{20,}|sk-ant-[a-zA-Z0-9_-]{20,}|plane_api_[a-f0-9]{16,}|gh[ps]_[a-zA-Z0-9]{30,}|AKIA[0-9A-Z]{16})'
if grep -rE "$secret_pattern" "$CANONICAL" 2>/dev/null; then
    fail "secret-shaped string found in canonical/ (above)"
else
    ok "no secret-shaped strings in canonical/"
fi

# Allow ~ and $HOME but not absolute /home/<user>/ paths
if grep -rE '/home/[a-z][a-z0-9_-]*/' "$CANONICAL" 2>/dev/null \
        | grep -v '#'; then
    fail "absolute /home/<user>/ path found in canonical/ (above)"
else
    ok "no hardcoded user home paths in canonical/"
fi

# ---- 3. ~/.bashrc sources cc-functions.sh ----
heading "Shell integration"
if grep -Fq 'cc-functions.sh' "$HOME/.bashrc" 2>/dev/null; then
    ok "$HOME/.bashrc sources cc-functions.sh"
else
    fail "$HOME/.bashrc does not source cc-functions.sh (cc-* commands unavailable)"
fi

# ---- 4. settings.local.json (secrets) ----
heading "Secrets"
if [ -f "$CLAUDE_DIR/settings.local.json" ]; then
    perms=$(stat -c '%a' "$CLAUDE_DIR/settings.local.json")
    if [ "$perms" = "600" ]; then
        ok "settings.local.json present (chmod 600)"
    else
        warn "settings.local.json present but chmod $perms (expected 600)"
    fi
    if jq -e '.env.PLANE_API_KEY // empty' "$CLAUDE_DIR/settings.local.json" >/dev/null; then
        ok "settings.local.json contains PLANE_API_KEY"
    else
        warn "settings.local.json missing PLANE_API_KEY (Plane integration disabled)"
    fi
else
    fail "settings.local.json missing — run environment-secrets/install.sh"
fi

# ---- 5. age key ----
heading "sops + age"
if [ -r "$HOME/.config/sops/age/keys.txt" ]; then
    perms=$(stat -c '%a' "$HOME/.config/sops/age/keys.txt")
    if [ "$perms" = "600" ]; then
        ok "age key present (chmod 600)"
    else
        warn "age key present but chmod $perms (expected 600)"
    fi
else
    warn "age key missing — sops decrypt won't work; needed for environment-secrets"
fi

# ---- 6. Vault ----
heading "Vault"
if [ -d "$HOME/vault" ]; then
    ok "$HOME/vault exists"
    for d in 00-core 10-middle 20-surface 40-journal 60-resources 90-archive; do
        if [ -d "$HOME/vault/$d" ]; then
            ok "  $HOME/vault/$d"
        else
            warn "  $HOME/vault/$d missing"
        fi
    done
    for sub in claude-memory claude-transcripts claude-specs claude-plans inbox; do
        if [ -d "$HOME/vault/20-surface/$sub" ]; then
            ok "  $HOME/vault/20-surface/$sub"
        else
            warn "  $HOME/vault/20-surface/$sub missing"
        fi
    done
else
    warn "$HOME/vault missing — end-conversation will queue artifacts to $HOME/.claude/queue/"
fi

# ---- 7. Repo cleanliness ----
heading "Repos"
for repo in "$REPO_ROOT" "$HOME/environment-secrets"; do
    if [ -d "$repo/.git" ]; then
        if [ -z "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then
            ok "$repo is clean"
        else
            warn "$repo has uncommitted changes"
        fi
    else
        warn "$repo is not a git repo (or missing)"
    fi
done

# ---- 8. Shell-snapshot safety of cc-* helper names ----
heading "Shell snapshot safety"
# Claude Code's Bash tool does not re-run your rc files. It restores shell state
# from ~/.claude/shell-snapshots/snapshot-<shell>-*.sh, which is generated with:
#
#     typeset +f | grep -vE '^_[^_]' | while read func; do typeset -f "$func"; done
#
# That filter exists to drop zsh completion functions (conventionally named
# `_command`), and it explicitly keeps double-underscore helpers. By the same
# rule it silently drops OUR single-underscore helpers. The public cc-* function
# is captured, its `_cc_*` callees are not, and because cc-branch has no `set -e`
# it half-runs: worktree + tmux window get created, but no .cc-mode, no
# session_id, no tree slot and no spawned event. Enforce `__cc_*` naming.
ccf="$CANONICAL/shell/cc-functions.sh"
if [ ! -f "$ccf" ]; then
    fail "canonical/shell/cc-functions.sh missing — cannot check snapshot safety"
else
    # Scan code only: strip whole-line comments first, so the explanatory prose
    # in cc-functions.sh (which necessarily spells out the old `_cc_*` names)
    # cannot trip the check. Require at least one character after the prefix so
    # a bare `_cc_` in a trailing comment is not mistaken for an identifier.
    code=$(grep -vE '^[[:space:]]*#' "$ccf")
    hostile_defs=$(printf '%s\n' "$code" | grep -oE '^_[^_][A-Za-z0-9_]*\(\)' \
                   | tr -d '()' | sort -u)
    hostile_calls=$(printf '%s\n' "$code" | grep -oE '(^|[^A-Za-z0-9_])_cc_[A-Za-z0-9][A-Za-z0-9_]*' \
                    | grep -oE '_cc_[A-Za-z0-9_]*' | sort -u)
    if [ -n "$hostile_defs" ] || [ -n "$hostile_calls" ]; then
        fail "cc-functions.sh uses helper names the shell snapshot drops (single '_' prefix)"
        printf '       offending names:\n'
        printf '         %s\n' $(printf '%s\n%s\n' "$hostile_defs" "$hostile_calls" | sort -u)
        printf '       fix: rename to __cc_* (the snapshot filter keeps double underscores)\n'
    else
        ok "cc-* helper names survive the shell-snapshot filter (no single-underscore helpers)"
    fi
fi

# ---- summary ----
heading "Summary"
printf 'OK: %d  WARN: %d  FAIL: %d\n' "$OK" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
