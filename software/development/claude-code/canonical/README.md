# Canonical Claude Code dotfiles

Files in this directory are symlinked into `~/.claude/` by
`../scripts/configure.sh`. They are the **single source of truth** for
non-secret, non-machine-specific Claude Code configuration.

## Hard rules

1. **No secrets.** Use `environment-secrets` (sops-encrypted) for anything
   sensitive. `cc-doctor` greps for common secret patterns and fails the
   build if it finds them here.
2. **No absolute paths to `$HOME`.** Use `~/` or `$HOME` so files work on
   any machine. Doctor enforces.
3. **Edits go here, not to `~/.claude/`.** Edits to `~/.claude/CLAUDE.md`
   would be silently overwritten on the next install. Edit
   `canonical/CLAUDE.md`, commit, push, then `git pull` on every machine.
4. **Nothing model-related in `settings.json`.** No `model`,
   `availableModels`, `enforceAvailableModels` or `fallbackModel`. That file
   is a live symlink the running app writes back to, so a model key there
   becomes a recurring phantom diff that reads like a human edit. The
   ROLE->model mapping is portable intent and lives in `model-policy.json`;
   a per-machine pin (if ever needed) lives in the untracked
   `~/.claude/settings.local.json`. Doctor check 10a fails on a violation.

## Layout

- `CLAUDE.md` — global Claude instructions (loaded on every session)
- `settings.json` — Claude Code settings (no secrets, no per-machine, no model)
- `model-policy.json` — role->model policy (see the module README)
- `statusline-command.sh` — statusline renderer (mode, cwd, context %)
- `shell/cc-functions.sh` — `cc-explore`, `cc-build`, `cc-continue` wrappers
- `skills/session-start/SKILL.md` — front-of-session bookend
- `skills/end-conversation/SKILL.md` — close-of-session bookend
