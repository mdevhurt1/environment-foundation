#!/usr/bin/env bash
# Description: Post-install acceptance test for the claude-code module — checks the CLI, Node 20+, that each ~/.claude entry is a symlink into a claude-code canonical/ tree whose target exists, and that ~/.bashrc sources cc-functions.sh.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: claude CLI (install.sh), deployed dotfiles (configure.sh)

set -uo pipefail   # NOTE: no -e — we want every check to run and report.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

CLAUDE_DIR="$HOME/.claude"

fails=0
check() {
  # check "<label>" <command...>
  local label="$1"; shift
  if "$@" &>/dev/null; then
    log_ok "$label"
  else
    log_error "$label"
    fails=$((fails + 1))
  fi
}

# check_canonical_link <path-under-~/.claude> <expected-suffix-under-canonical/>
#
# Acceptance, not drift detection: assert the entry is a symlink whose target
# ends with the canonical path and actually exists. It deliberately does NOT
# compare against this checkout's $REPO_ROOT — the deployed links legitimately
# point at whichever clone ran configure.sh (commonly the main worktree, while
# this script may be run from a branch worktree). scripts/doctor.sh is the tool
# that asserts exact canonical paths for THIS checkout.
check_canonical_link() {
  local name="$1" suffix="$2" target
  local path="$CLAUDE_DIR/$name"
  if [ ! -L "$path" ]; then
    log_error "$path is not a symlink"
    log_warn "  run configure.sh to deploy the canonical dotfiles"
    fails=$((fails + 1))
    return
  fi
  target="$(readlink "$path")"
  case "$target" in
    */software/development/claude-code/canonical/"$suffix")
      if [ -e "$target" ]; then
        log_ok "$name -> $target"
      else
        log_error "$name -> $target (target does not exist — dangling symlink)"
        fails=$((fails + 1))
      fi
      ;;
    *)
      log_error "$name -> $target (not a claude-code canonical/$suffix path)"
      fails=$((fails + 1))
      ;;
  esac
}

log_info "Verifying Claude Code install..."

# --- 1. The CLI itself ---------------------------------------------------
check "claude CLI on PATH" command -v claude
check "claude --version runs" claude --version

# --- 2. Node 20+ (install.sh's floor) ------------------------------------
if command -v node &>/dev/null; then
  node_major="$(node --version | cut -d. -f1 | tr -d 'v')"
  if [ "$node_major" -ge 20 ] 2>/dev/null; then
    log_ok "Node.js $(node --version) meets the 20+ floor"
  else
    log_error "Node.js $(node --version) is below the required version 20"
    fails=$((fails + 1))
  fi
else
  log_error "node not on PATH"
  fails=$((fails + 1))
fi

# --- 3. Deployed dotfiles ------------------------------------------------
check_canonical_link "CLAUDE.md"              "CLAUDE.md"
check_canonical_link "settings.json"          "settings.json"
check_canonical_link "statusline-command.sh"  "statusline-command.sh"
check_canonical_link "skills"                 "skills"
check_canonical_link "cc-functions.sh"        "shell/cc-functions.sh"
check_canonical_link "cc-tree-slot-write.sh"  "shell/cc-tree-slot-write.sh"
check_canonical_link "cc-tree-slot-update.sh" "shell/cc-tree-slot-update.sh"
check_canonical_link "cc-ring-scan.sh"        "shell/cc-ring-scan.sh"
check_canonical_link "model-policy.json"      "model-policy.json"

# --- 4. Shell wiring -----------------------------------------------------
check "~/.bashrc sources cc-functions.sh" \
  bash -c 'grep -Fq "source ~/.claude/cc-functions.sh" "$HOME/.bashrc"'

# --- 5. Secrets: may legitimately be absent -> warn and skip -------------
if [ -f "$CLAUDE_DIR/settings.local.json" ]; then
  log_ok "settings.local.json present (deployed by environment-secrets)"
else
  log_warn "no $CLAUDE_DIR/settings.local.json — API keys will be unavailable"
  log_warn "  clone environment-secrets and run its install.sh (not part of this module)"
fi

# --- 6. Informational: a second, non-npm install shadowing the module's --
claude_path="$(command -v claude 2>/dev/null || true)"
case "$claude_path" in
  "$HOME"/.local/bin/claude)
    log_warn "the active claude is the native install at $claude_path, not the"
    log_warn "  npm global package install.sh manages. Both can coexist; the"
    log_warn "  native one wins on PATH. uninstall.sh removes only the npm one."
    ;;
esac

echo
if [[ "$fails" -eq 0 ]]; then
  log_ok "All checks passed. Versions:"
  claude --version
  node --version
  log_info "Open a new shell (or 'source ~/.bashrc') to pick up the cc-* wrappers."
  log_info "For drift detection against this checkout, run: bash $SCRIPT_DIR/doctor.sh"
  exit 0
else
  log_error "$fails check(s) failed."
  log_warn "Re-run: bash $SCRIPT_DIR/install.sh && bash $SCRIPT_DIR/configure.sh"
  exit 1
fi
