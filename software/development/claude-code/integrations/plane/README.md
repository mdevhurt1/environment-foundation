# Plane Integration

> **Profiles:** `[workstation]`
> **Platforms:** ubuntu-24.04 (primary), ubuntu-22.04

Verifies that Claude Code can reach the self-hosted Plane instance and act on
issues via the `plane-api` skill.

## What this does — and does not — install

The `plane-api` skill is **canonical**. It lives at
`software/development/claude-code/canonical/skills/plane-api/` and is deployed
by the module's own `scripts/configure.sh`, which symlinks
`~/.claude/skills` → `canonical/skills`.

This integration installs **nothing**. It is a read-only verification step.

> Earlier versions of this directory shipped a second, forked copy of the skill
> (`skill.md`) and `cp`'d it into `~/.claude/skills/plane-api/SKILL.md`. That
> forked and drifted from canonical, and its `mkdir -p ~/.claude/skills/plane-api`
> would create a real directory that blocks the canonical symlink on a fresh
> machine. The fork has been removed — canonical is the single source of truth.

## Prerequisites

1. Claude Code installed — `software/development/claude-code/scripts/install.sh`
2. Canonical dotfiles deployed — `software/development/claude-code/scripts/configure.sh`
3. Secrets provisioned — `~/environment-secrets/install.sh`

## Credential

`PLANE_API_KEY` is **not** an environment variable and is **not** in `~/.bashrc`
or `~/.zshrc`. It lives in `~/.claude/settings.local.json` under
`.env.PLANE_API_KEY`, written by the `environment-secrets` repo.

Claude Code does not inject that `env` block into the Bash tool's shell, so
`$PLANE_API_KEY` is empty inside tool calls. Read it from the JSON instead:

```bash
PLANE_API_KEY=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.claude/settings.local.json')))['env']['PLANE_API_KEY'])")
```

## Verify

```bash
bash configure.sh
```

Checks the canonical skill is present, the credential is readable, and
`http://plane.homelab` answers with the key accepted. Exits non-zero on any
failure. Override the host with `PLANE_HOST=... bash configure.sh`.

## Host

Use the hostname `plane.homelab` — it survives a VM IP change. If calls
succeed and then suddenly time out, suspect the UDM SE IPS dropping the
inter-VLAN session before suspecting the Plane stack; the `plane-api` skill
documents the diagnostic sequence.
