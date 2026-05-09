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

## Layout

- `CLAUDE.md` — global Claude instructions (loaded on every session)
- `settings.json` — Claude Code settings (no secrets, no per-machine)
- `statusline-command.sh` — statusline renderer (mode, cwd, context %)
- `shell/cc-functions.sh` — `cc-explore`, `cc-build`, `cc-continue` wrappers
- `skills/session-start/SKILL.md` — front-of-session bookend
- `skills/end-conversation/SKILL.md` — close-of-session bookend
