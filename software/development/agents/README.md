# agents

> **Profiles:** `[dev]` `[workstation]` `[workplace]`
> **Platforms:** ubuntu-24.04

One instruction file and one skills directory for every agent runtime on this machine.

| Path | Purpose |
|---|---|
| `canonical/AGENTS.md` | Global instructions. Installed at `~/.agents/AGENTS.md` and linked from `~/.codex/AGENTS.md`, `~/.pi/agent/AGENTS.md`, the Antigravity path in `~/.agents/agy-context-path`, and imported by `~/.claude/CLAUDE.md` |
| `canonical/skills/` | Kept skills: plane-api, systematic-debugging, test-driven-development, verification-before-completion, brainstorming, writing-plans. Installed at `~/.agents/skills`, linked from `~/.claude/skills` and `~/.gemini/config/skills`; Codex and Pi read `~/.agents/skills` natively (`~/.codex/skills` stays a real directory holding Codex's managed `.system/` skills) |
| `scripts/install.sh` | Creates the symlinks above and the five `~/.claude` links; `~/.claude/settings.json` is maintained by hand |
| `scripts/verify.sh` | Proves each runtime reads the file, sees `~/.config/agents/env`, and lists the skills |
| `scripts/uninstall.sh` | Removes the symlinks above; dry run without `--yes`. Never touches `~/.config/agents/env` or the vault |

Secrets reach every shell through `~/.config/agents/env`, written by `~/environment-secrets/install.sh`.

Everything parked on 2026-09-19 is under `../claude-code/parked/` unchanged; see `FREEZE.md` at the repo root.

Git hooks: `.git/hooks/{pre-commit,pre-push}` are hand-installed wrappers that resolve
`parked/hooks/*.sh` then `canonical/hooks/*.sh` and refuse the operation if neither is present.
They are real files, not symlinks, because `.git/hooks` is shared by every worktree.
