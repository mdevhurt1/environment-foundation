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
| `cc-branch <task-id> [<repo>]` | branched worker in its own worktree + tmux window | delegate a task from the EA |
| `cc-doctor` | n/a | verify install, detect drift |

Direct `claude` invocation still works but is non-SOP — prefer wrappers.
Only the wrappers apply the model policy below; a bare `claude` still gets
Claude Code's Default.

### Model policy

Claude Code's "Default" resolves to the **most capable model available to the
account**, so it is a moving referent: when a new model joins the account
roster, Default silently captures every session that has not pinned one. On
2026-08-20 that moved the EA session from Opus 5 to Fable 5 with no diff and no
output anywhere. It had already moved Opus 4.8 -> Opus 5 before that.

`canonical/model-policy.json` maps **session roles to model choices**, and the
`cc-*` wrappers resolve `--model` from it at launch:

| Role | Used by |
|---|---|
| `ea` | `cc` — the command-center / EA session |
| `branched-worker` | `cc-branch` children |
| `explore` | `cc-explore` |
| `build` | `cc-build` |
| `review-lane`, `cheap-mechanical`, `subagent-default`, `scheduled` | reserved; not yet mechanized |

Each role takes one of three legal values:

- `"track-latest"` — deliberately accept Default; the tier **may move**. The
  wrapper passes no `--model` and records `model_source=policy:<role>`, so the
  choice is on record even though the command line looks unpinned.
- a tier alias — `opus`, `sonnet`, `fable`, `haiku`. Tier pinned, version
  tracks within it. This is what survives a new model joining the roster.
- an exact id — e.g. `claude-opus-5[1m]`. Fully pinned.

The point is not to ban Default. It is that Default must be **chosen** rather
than inherited.

**The EA session picks its model up here.** `cc` resolves role `ea` before
creating the tmux session and passes the flag inside the window's command
string, so the EA is subject to the same policy as everything it spawns.

**Override a single launch** with an env prefix — recorded as
`model_source=env`, so an override is as visible in the tree as a policy
choice is:

```bash
CC_MODEL=opus cc-branch <task-id> [<repo-path>]
```

`CC_MODEL` also bypasses policy lookup entirely, so a missing or broken policy
file can never strand you. Absent that override the wrappers **refuse to
launch** rather than falling back to Default — a refusal costs one command,
whereas the silent version was discovered by a bill.

**Where the choice is visible:**

- `.cc-mode` and the session's tree slot carry `model` / `model_source`
  (intent).
- The statusline shows the **running** model from the harness, plus a
  `MODEL-DRIFT` marker when it disagrees with the stamped intent (reality).

**When the account roster changes**, `cc-doctor` check 10c WARNs about any
model not listed in the policy's `known_models`. Adding it there *is* the act
of deciding that `track-latest` still applies; pinning the affected roles is
the other option.

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
