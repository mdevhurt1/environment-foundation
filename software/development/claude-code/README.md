# Claude Code

> **Profiles:** `[dev]` `[workstation]` `[workplace]`
> **Platforms:** ubuntu-24.04 (primary), ubuntu-22.04, windows-11 (WSL)

Anthropic's official CLI for Claude, plus the Claude Code half of the agent
harness: the payload under `canonical/` that every Claude Code session on the
machine loads.

Since the 2026-09-19 reset this module has **one deployer**:
`software/development/agents/scripts/install.sh` owns every `~/.claude` link
(and the shared `AGENTS.md` and skills every runtime reads). This module's own
scripts install and remove the CLI and verify the result; they never create or
remove `~/.claude` links. The old `configure.sh` deploy layer (cc-* wrappers,
tree slots, bookend scripts, cc-doctor) is parked under `parked/` and is not run.

## Dependencies

- Node.js 20+ and npm (installed by `scripts/install.sh` if not present)
- The agents module, which deploys the payload

## Install

```bash
bash scripts/install.sh                                   # Node 20+ and the claude CLI
bash ../agents/scripts/install.sh                         # the ~/.claude links, AGENTS.md, skills
git clone <gitea>/mhurt/environment-secrets ~/environment-secrets
~/environment-secrets/install.sh                          # settings.local.json and ~/.config/agents/env
```

`agents/scripts/install.sh` is idempotent: it re-points links and never copies,
except `~/.claude/settings.json`, which it seeds from `canonical/settings.json`
**only when the file does not exist** (see below).

## Verify

```bash
bash scripts/verify.sh                 # CLI, Node, the six ~/.claude links, settings.json, secrets
bash ../agents/scripts/verify.sh       # the release gate: every runtime reads AGENTS.md, env, skills, hooks
```

## Uninstall

```bash
bash scripts/uninstall.sh              # dry run: lists what would go and what is kept
bash scripts/uninstall.sh --yes        # removes the npm global CLI only
bash ../agents/scripts/uninstall.sh --yes   # removes the ~/.claude links (the owner's uninstall)
```

`scripts/uninstall.sh` removes only what `scripts/install.sh` created. It never
touches the `~/.claude` links, `settings.json`, `settings.local.json`, the vault,
or any `~/.claude/.backup-*` directory left by the parked `configure.sh`; it
restores nothing.

## What is deployed

`agents/scripts/install.sh` links these from `canonical/` into `~/.claude/`:

| `~/.claude/` entry | Source | Role |
|---|---|---|
| `CLAUDE.md` | `canonical/CLAUDE.md` | one line importing `~/.agents/AGENTS.md` |
| `statusline-command.sh` | `canonical/statusline-command.sh` | statusline renderer |
| `model-policy.json` | `canonical/model-policy.json` | role-to-model policy; only the parked wrappers read it today |
| `cc-memory-inject.sh` | `canonical/shell/cc-memory-inject.sh` | SessionStart hook: points the session at MEMORY.md |
| `cc-outbound-guard.sh` | `canonical/shell/cc-outbound-guard.sh` | PreToolUse hook: blocks outbound writes from Bash |
| `cc-memory-index-regen.sh` | `canonical/shell/cc-memory-index-regen.sh` | rebuilds MEMORY.md; `--check` asserts the invariant |

Skills live in `../agents/canonical/skills/`; `~/.claude/skills` is a real
directory holding one link per kept skill, beside any vendor-synced skills.

### settings.json

`~/.claude/settings.json` is a **real file, kept by hand**: Claude Code writes
back to it, so a link would turn every app-side change into a repo diff.
`canonical/settings.json` is the **seed** for a machine that has none:
`agents/scripts/install.sh` copies it into place only when
`~/.claude/settings.json` is absent, and never edits an existing file (a
symlink there is reported and left alone). After that the live file is the
operator's; the seed is not a mirror of it and is expected to differ in
personal preferences (plugins, notifications, UI). Change the seed when a
fresh machine should start differently, not to track the live file.

What must hold in every live file is the hooks block (the outbound guard and
the memory pointer). `agents/scripts/verify.sh` asserts it and, on a missing,
malformed or hookless file, fails with the fix instead of a traceback. Secrets
and per-machine values never go in either file; they belong in
`settings.local.json` (environment-secrets).

## Parked

Everything the reset parked on 2026-09-19 is under `parked/`, unchanged and not
deployed: `configure.sh`, the cc-* wrappers (`shell/cc-functions.sh`), tree-slot
and ring-scan scripts, cc-doctor, the vendored skills, tests and templates. Their
history is in git (`pre-reset-2026-09-19` tag) and in `FREEZE.md` at the repo
root. Restoring any of it is a release story, not a mid-task edit.

## Git scrub hooks (cc-scrub)

`parked/scripts/cc-scrub.sh` scans a diff for disclosure tells (RFC1918 host
literals, absolute paths naming an operator account, session identifiers,
internal hostnames) before they reach a public remote. It still runs: the
repository's `.git/hooks/pre-commit` and `pre-push` are hand-installed wrapper
files (not symlinks, since `.git/hooks` is shared by every worktree) that
resolve `parked/hooks/<name>.sh`, then `canonical/hooks/<name>.sh`, and refuse
the operation if neither exists. See `../agents/README.md`.

```bash
bash parked/scripts/cc-scrub.sh                  # diff <baseline>..HEAD, incl. commit messages
bash parked/scripts/cc-scrub.sh --staged         # what pre-commit runs
bash parked/scripts/cc-scrub.sh --range A..B     # what pre-push runs
bash parked/scripts/cc-scrub.sh --audit          # absolute tree scan; not the default
bash parked/scripts/cc-scrub.sh --calibrate-only # prove the instrument, sweep nothing
```

| exit | meaning |
|---|---|
| 0 | calibration passed, no blocking findings (the only exit that clears) |
| 1 | blocking findings |
| 2 | **INCOMPLETE**: calibration failed, or the corpus could not be fully swept |
| 3 | usage error |

It diffs against a baseline (default `origin/main`) so only new findings in a
BLOCK-tier rule block, and it plants a positive control per rule before every
sweep, so an uncalibrated run is INCOMPLETE rather than CLEAN. There is no
override of its own beyond git's `--no-verify`, and a commit or push made that
way belongs in the session report.

`parked/scripts/cc-scrub-outbound.sh` is the sibling for staged outbound
PR/issue packages (`.title` / `.body.md` / `.target`); it adds register and
typography rules (em dash, curly quotes, AI trailers) and delegates the F1 rules
to `cc-scrub.sh`. No hook calls it; invoke it by path before posting anything.

## Vault

`~/vault/` is designed in `homelab/obsidian-stack/` and is not deployed by this
module. Write rules for agents live in `../agents/canonical/AGENTS.md`.
