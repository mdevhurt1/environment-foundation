#!/usr/bin/env bash
# Description: Links ~/.agents/{AGENTS.md,skills} to canonical/ and each runtime's global path to them
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04
# Dependencies: the runtimes' config dirs
# Idempotent: re-running replaces symlinks, never copies.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
source "$REPO_ROOT/shared/logging.sh"
require_not_root
canon="$(cd "$SCRIPT_DIR/.." && pwd)/canonical"

link() { # link <target> <linkpath>
    mkdir -p "$(dirname "$2")"
    if [ -e "$2" ] && [ ! -L "$2" ]; then
        mv "$2" "$2.pre-reset-$(date +%Y%m%d-%H%M%S)"
        echo "moved existing $2 aside"
    fi
    ln -sfn "$1" "$2"
    echo "linked $2 -> $1"
}

# Shared location every runtime can be pointed at
link "$canon/AGENTS.md" "$HOME/.agents/AGENTS.md"
skill_root() { # skill_root <dir>: a real dir holding one symlink per kept skill (AI_ST-107)
    # A whole-dir link let Claude Code's cloud skill sync write synced/ into canonical/ (2026-09-23);
    # with per-skill links, vendor content lands beside our skills, never inside the repo.
    if [ -L "$1" ]; then rm "$1"; echo "replaced dir link $1 with a real dir"; fi
    mkdir -p "$1"
    for s in "$HOME"/.agents/skills/*/; do link "${s%/}" "$1/$(basename "$s")"; done
    for l in "$1"/*; do # prune our links whose skill is gone
        if [ -L "$l" ] && [ ! -e "$l" ]; then
            case "$(readlink "$l")" in "$HOME/.agents/skills/"*) rm "$l"; echo "pruned $l";; esac
        fi
    done
}

# no canonical skills dir: leave every runtime's skills untouched
if [ -d "$canon/skills" ]; then
    link "$canon/skills" "$HOME/.agents/skills"
    # Vendor sync that already landed in canonical/ moves out to Claude Code's own root (it was Claude Code's sync)
    if [ -d "$canon/skills/synced" ]; then
        mkdir -p "$HOME/.claude"; vendor_tmp="$(mktemp -d "$HOME/.claude/skills.vendor-XXXXXX")"   # fresh dir: mv cannot nest
        mv "$canon/skills/synced" "$vendor_tmp/synced"
    fi
    # Claude Code has no shared-dir discovery, so its skills root links each shared skill
    skill_root "$HOME/.claude/skills"
    if [ -n "${vendor_tmp:-}" ]; then
        dest="$HOME/.claude/skills/synced"
        [ -e "$dest" ] && dest="$dest.from-canonical-$(date +%Y%m%d-%H%M%S)"   # never mv into an existing synced/
        mv "$vendor_tmp/synced" "$dest" && rmdir "$vendor_tmp"
        echo "moved vendor synced/ out of canonical/ to $dest"
    fi
    # Antigravity CLI: global skills root per its embedded docs
    skill_root "$HOME/.gemini/config/skills"
fi

# Codex: global AGENTS.md. Do NOT link ~/.codex/skills: it is a real directory holding
# Codex's managed .system/ skills, and Codex discovers ~/.agents/skills natively.
link "$HOME/.agents/AGENTS.md" "$HOME/.codex/AGENTS.md"

# Pi: global AGENTS.md; reads ~/.agents/skills natively
link "$HOME/.agents/AGENTS.md" "$HOME/.pi/agent/AGENTS.md"

# Claude Code: the six ~/.claude links into claude-code/canonical/ (idempotent; claude-code's own configure.sh is parked)
cc="$REPO_ROOT/software/development/claude-code/canonical"
link "$cc/CLAUDE.md"                    "$HOME/.claude/CLAUDE.md"
link "$cc/statusline-command.sh"        "$HOME/.claude/statusline-command.sh"
link "$cc/model-policy.json"            "$HOME/.claude/model-policy.json"
link "$cc/shell/cc-memory-inject.sh"    "$HOME/.claude/cc-memory-inject.sh"
link "$cc/shell/cc-outbound-guard.sh"   "$HOME/.claude/cc-outbound-guard.sh"
link "$cc/shell/cc-memory-index-regen.sh" "$HOME/.claude/cc-memory-index-regen.sh"   # AI_ST-116: the path MEMORY.md names

# Claude Code settings.json: a real file the app writes back to, so never a link. Seed it from
# canonical/ only when absent (a fresh machine otherwise gets no hooks); never edit an existing one (AI_ST-128).
st="$HOME/.claude/settings.json"
if [ -L "$st" ]; then
    log_warn "left $st alone: it is a symlink (-> $(readlink "$st")); settings.json must be a real file"
    log_warn "  fix: save anything you want from it, then rm $st and re-run install.sh to seed a real file"
elif [ ! -e "$st" ]; then
    cp "$cc/settings.json" "$st"
    echo "seeded $st from $cc/settings.json (absent before; later edits are yours)"
fi

# Antigravity CLI: its global context path, recorded once in ~/.agents/agy-context-path
if [ -f "$HOME/.agents/agy-context-path" ]; then
    agy_path="$(head -n1 "$HOME/.agents/agy-context-path")"
    case "$agy_path" in
        /*) link "$HOME/.agents/AGENTS.md" "$agy_path" ;;
        *)  log_warn "skipped agy: ~/.agents/agy-context-path must hold one absolute path, got '${agy_path}'"
            log_warn "  fix: echo \"\$HOME/.gemini/config/rules/AGENTS.md\" > ~/.agents/agy-context-path, then re-run install.sh" ;;
    esac
fi
