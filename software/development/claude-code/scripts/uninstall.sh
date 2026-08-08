#!/usr/bin/env bash
# Description: Removes the Claude Code SOP deployment — the ~/.claude symlinks configure.sh created, the ~/.bashrc source line, and the npm global CLI. Dry run by default; --yes to proceed. Never removes settings.local.json, the vault, or the canonical repository the links point at.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: npm (CLI installed by install.sh), symlinks deployed by configure.sh
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

CLAUDE_DIR="$HOME/.claude"
NPM_PKG="@anthropic-ai/claude-code"
BASHRC_LINE='[ -f ~/.claude/cc-functions.sh ] && source ~/.claude/cc-functions.sh'

# The exact set configure.sh creates: <name under ~/.claude> -> <suffix under canonical/>
LINK_NAMES=(
  CLAUDE.md
  settings.json
  statusline-command.sh
  skills
  cc-functions.sh
  cc-tree-slot-write.sh
  cc-tree-slot-update.sh
  cc-ring-scan.sh
)
LINK_SUFFIXES=(
  CLAUDE.md
  settings.json
  statusline-command.sh
  skills
  shell/cc-functions.sh
  shell/cc-tree-slot-write.sh
  shell/cc-tree-slot-update.sh
  shell/cc-ring-scan.sh
)

# is_canonical_link <name> <suffix>
# True only if ~/.claude/<name> is a symlink whose target is a claude-code
# canonical/<suffix> path. Anything else — a real file, a link somewhere else —
# is not ours to remove.
is_canonical_link() {
  local path="$CLAUDE_DIR/$1" suffix="$2" target
  [ -L "$path" ] || return 1
  target="$(readlink "$path")"
  case "$target" in
    */software/development/claude-code/canonical/"$suffix") return 0 ;;
    *) return 1 ;;
  esac
}

# Newest backup configure.sh made, if any.
# Returns empty (and 0) when there is nothing to find. The directory guard
# matters: without it `find` on a missing ~/.claude exits 1, pipefail
# propagates that, and set -e would abort the dry run before it printed the
# KEEP block — a hard failure for the legitimate nothing-to-do case.
latest_backup() {
  [ -d "$CLAUDE_DIR" ] || return 0
  find "$CLAUDE_DIR" -maxdepth 1 -type d -name '.backup-*' 2>/dev/null | sort | tail -1
}

ASSUME_YES=0
case "${1:-}" in
  --yes) ASSUME_YES=1 ;;
  "")    ASSUME_YES=0 ;;
  *)     log_error "Unknown argument: $1 (only --yes is accepted)"; exit 2 ;;
esac

plan() { printf '  - %s\n' "$*"; }
keep() { printf '  . %s\n' "$*"; }
skip() { printf '  ? %s\n' "$*"; }

log_warn "==================================================================="
log_warn " The cc-* shell wrappers (cc-branch, cc-teleport, cc-explore,"
log_warn " cc-build) source ~/.claude/cc-functions.sh, and the skills every"
log_warn " Claude Code session loads live behind ~/.claude/skills."
log_warn " Removing these links BREAKS EVERY RUNNING SESSION on this machine."
log_warn " Close your sessions first."
log_warn "==================================================================="
echo

log_info "Claude Code uninstall would REMOVE:"
for i in "${!LINK_NAMES[@]}"; do
  name="${LINK_NAMES[$i]}"
  suffix="${LINK_SUFFIXES[$i]}"
  if is_canonical_link "$name" "$suffix"; then
    plan "symlink: $CLAUDE_DIR/$name -> $(readlink "$CLAUDE_DIR/$name")"
  elif [ -e "$CLAUDE_DIR/$name" ] || [ -L "$CLAUDE_DIR/$name" ]; then
    # -L as well as -e: [ -e ] is false for a symlink whose target is gone, and
    # a dangling foreign link must still be reported, not silently ignored.
    skip "$CLAUDE_DIR/$name exists but is not a canonical symlink — LEFT ALONE"
  fi
done
if grep -Fxq "$BASHRC_LINE" "$HOME/.bashrc" 2>/dev/null; then
  plan "the cc-functions source line configure.sh appended to ~/.bashrc"
fi
if npm ls -g --depth=0 "$NPM_PKG" &>/dev/null; then
  plan "npm global package: $NPM_PKG"
fi

backup="$(latest_backup)"
if [ -n "$backup" ]; then
  log_info "and would RESTORE:"
  plan "the pre-install state configure.sh saved at $backup"
fi

log_info "and would deliberately KEEP:"
keep "$CLAUDE_DIR/settings.local.json — API keys and secrets"
keep "$CLAUDE_DIR/projects, history and any session state"
keep "the environment-foundation repository the links point into"
keep "~/vault/ — never touched under any circumstance"
if [ -e "$HOME/.local/bin/claude" ]; then
  keep "$HOME/.local/bin/claude — a native install this module did not create"
fi
keep "Node.js — install.sh installs it, but other software depends on it"

if [ "$ASSUME_YES" -ne 1 ]; then
  log_warn "Dry run — nothing was removed. Re-run with --yes to proceed."
  exit 0
fi

# --- Remove only verified canonical symlinks -------------------------------
# Plain `rm`, never `rm -r` and never `rm -f`: ~/.claude/skills is a symlink to
# a DIRECTORY inside the repository. `rm -rf` on it (especially with a trailing
# slash) would delete the canonical skills from the repo itself. `rm` on a
# symlink removes the link and never follows it.
for i in "${!LINK_NAMES[@]}"; do
  name="${LINK_NAMES[$i]}"
  suffix="${LINK_SUFFIXES[$i]}"
  if is_canonical_link "$name" "$suffix"; then
    rm "$CLAUDE_DIR/$name"
    log_ok "removed symlink $CLAUDE_DIR/$name"
  elif [ -e "$CLAUDE_DIR/$name" ] || [ -L "$CLAUDE_DIR/$name" ]; then
    # Same widening as the plan loop above, so both runs agree.
    log_warn "$CLAUDE_DIR/$name is not a canonical symlink — left alone"
  fi
done

# --- Remove the ~/.bashrc line and the comment above it --------------------
if grep -Fxq "$BASHRC_LINE" "$HOME/.bashrc" 2>/dev/null; then
  cp "$HOME/.bashrc" "$HOME/.bashrc.pre-claude-uninstall"
  # Filter the BACKUP into a temp file, then mv it into place. Never redirect
  # straight into ~/.bashrc: the redirect truncates before the pipeline runs,
  # so a chain that matches nothing (a ~/.bashrc holding only our two managed
  # lines) would leave the real file empty AND abort under pipefail before the
  # log line naming the backup ever printed. mktemp in $HOME keeps the mv on
  # one filesystem, so it is an atomic rename with no truncated window.
  # `|| true`: grep -Fxv exits 1 when it emits no lines, which is a legitimate
  # empty result here, not an error.
  bashrc_tmp="$(mktemp "$HOME/.bashrc.uninstall.XXXXXX")"
  chmod --reference="$HOME/.bashrc.pre-claude-uninstall" "$bashrc_tmp" 2>/dev/null || true
  { grep -Fxv "$BASHRC_LINE" "$HOME/.bashrc.pre-claude-uninstall" \
      | grep -Fxv '# Claude Code workflow wrappers (cc-explore, cc-build, cc-continue)' \
      > "$bashrc_tmp"; } || true
  mv "$bashrc_tmp" "$HOME/.bashrc"
  log_ok "removed the cc-functions source line from ~/.bashrc"
  log_info "previous ~/.bashrc saved at ~/.bashrc.pre-claude-uninstall"
else
  log_ok "~/.bashrc has no cc-functions source line — skipping."
fi

# --- Restore whatever configure.sh backed up -------------------------------
backup="$(latest_backup)"
if [ -n "$backup" ]; then
  log_info "Restoring pre-install state from $backup..."
  # -n: never overwrite anything still present (e.g. settings.local.json).
  cp -rn "$backup"/. "$CLAUDE_DIR"/ 2>/dev/null || true
  log_ok "restored from $backup (the backup directory itself is kept)"
else
  log_ok "no configure.sh backup found — nothing to restore."
fi

# --- Remove the npm global CLI ---------------------------------------------
if npm ls -g --depth=0 "$NPM_PKG" &>/dev/null; then
  log_info "Removing the npm global $NPM_PKG..."
  sudo npm uninstall -g "$NPM_PKG"
  log_ok "$NPM_PKG removed."
else
  log_ok "$NPM_PKG is not installed globally — skipping."
fi

if [ -e "$HOME/.local/bin/claude" ]; then
  log_warn "$HOME/.local/bin/claude is still present — a native install this"
  log_warn "  module did not create. Remove it yourself if you want it gone."
fi

log_ok "Claude Code uninstall complete."
log_warn "Open a new shell: the cc-* wrappers are gone from this one's environment."
log_info "settings.local.json, your vault and the repository were not touched."
