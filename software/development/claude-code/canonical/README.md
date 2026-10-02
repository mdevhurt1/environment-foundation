# Canonical Claude Code dotfiles

Files in this directory are symlinked into `~/.claude/` by
`software/development/agents/scripts/install.sh`, the one owner of the
`~/.claude` links since the 2026-09-19 reset. They are the **single source of
truth** for non-secret, non-machine-specific Claude Code configuration.

## Hard rules

1. **No secrets.** Use `environment-secrets` (sops-encrypted) for anything
   sensitive.
2. **No absolute paths to `$HOME`.** Use `~/` or `$HOME` so files work on
   any machine.
3. **Edits go here, not to `~/.claude/`.** Edits to `~/.claude/CLAUDE.md`
   land in this repo through the link anyway; edit `canonical/`, commit, and
   `git pull` on every machine.
4. **Nothing model-related in `settings.json`.** No `model`,
   `availableModels`, `enforceAvailableModels` or `fallbackModel`. The
   ROLE->model mapping is portable intent and lives in `model-policy.json`;
   a per-machine pin (if ever needed) lives in the untracked
   `~/.claude/settings.local.json`.

## Layout

- `CLAUDE.md` — global Claude instructions (loaded on every session)
- `settings.json` — Claude Code settings (no secrets, no per-machine, no model); not linked: `~/.claude/settings.json` is a real file kept by hand
- `model-policy.json` — role->model policy (see the module README)
- `statusline-command.sh` — statusline renderer (mode, cwd, context %)
- `shell/cc-memory-inject.sh` — SessionStart hook: points the session at MEMORY.md (AI_ST-123)
- `shell/cc-outbound-guard.sh` — PreToolUse hook: blocks outbound writes from Bash (AI_ST-110); internal hosts beyond loopback come from `AGENTS_INTERNAL_HOSTS` in `~/.config/agents/env` (AI_ST-133)
- `shell/cc-memory-index-regen.sh` — rebuilds MEMORY.md from the memory files; `--check` asserts the invariant (AI_ST-116)
- `shell/tests/` — guard fixtures and runner
- Skills, including `session-start` and `end-conversation`, live in `software/development/agents/canonical/skills/`, shared by all four runtimes
