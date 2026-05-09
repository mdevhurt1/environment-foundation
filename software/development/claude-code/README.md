# Claude Code

> **Profiles:** `[dev]` `[workstation]` `[workplace]`
> **Platforms:** ubuntu-24.04 (primary), ubuntu-22.04, windows-11 (WSL)

Anthropic's official CLI for Claude. Provides an agentic coding assistant
directly in the terminal with tool use, codebase context, and extensibility
via MCP servers and hooks.

## Dependencies

- Node.js 20+ and npm (installed by `install.sh` if not present)

## Install

```bash
bash scripts/install.sh
```

## Configure

```bash
bash scripts/configure.sh
```

Configure sets up `~/.claude/settings.json` with a baseline configuration and
prints instructions for setting your `ANTHROPIC_API_KEY`.

## Platform notes

| Platform | Notes |
|----------|-------|
| ubuntu-24.04 | Fully supported, primary target |
| ubuntu-22.04 | Fully supported |
| windows-11 | Run inside WSL2 Ubuntu terminal |

## Verify

```bash
claude --version
```

## Workflow SOP

This module deploys a deterministic Claude Code workflow. See the design spec at:
`docs/superpowers/specs/2026-05-08-claude-obsidian-workflow-sop-design.md`
(gitignored — local copy).

### Install

```bash
bash scripts/install.sh        # installs Claude Code itself
bash scripts/configure.sh      # symlinks canonical/ into ~/.claude/, adds cc-* wrappers
```

Then clone and install secrets (separate private repo):

```bash
git clone <gitea>/mhurt/environment-secrets ~/environment-secrets
~/environment-secrets/install.sh
```

Verify: `cc-doctor`

### Wrappers

| Command | Mode | When |
|---|---|---|
| `cc-explore <slug>` | sandbox + git worktree + strict perms | research, debug, brainstorm |
| `cc-build` | full perms, main worktree (requires plan) | execute approved plan |
| `cc-continue [name]` | inherits original mode from `.cc-mode` | resume a worktree/session |
| `cc-doctor` | n/a | verify install, detect drift |

Direct `claude` invocation still works but is non-SOP — prefer wrappers.

### Bookend skills

- **session-start** — auto-runs via SessionStart hook. Verifies mode,
  surfaces vault context, declares goal.
- **end-conversation** — run `/end` (or react to `CTX-WARN` in
  statusline). Walks the closing ritual: memory delta, spec/plan
  capture, transcript decision, vault sync, promotion candidates,
  worktree fold.

### Vault

`~/vault/` (designed in `homelab/obsidian-stack/`, not deployed by
this module). Three rings + journal:
- `00-core/` — human-only inner ring
- `10-middle/` — human-curated synthesis
- `20-surface/` — machine-fed by end-conversation
- `40-journal/` — daily voice practice

Promotion is always manual, weekly cadence. See `00-core/_rituals/weekly-review.md`.
