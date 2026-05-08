# Plane Integration

> **Profiles:** `[workstation]`
> **Platforms:** ubuntu-24.04 (primary), ubuntu-22.04

Installs the `plane-api` skill so Claude Code can create, read, and update
Plane issues directly from the terminal.

## Prerequisites

- Claude Code installed (`software/development/claude-code/scripts/install.sh`)
- Plane accessible at `plane.homelab`

## Configure

```bash
bash configure.sh
```

Installs `skill.md` to `~/.claude/skills/plane-api/SKILL.md` and prints
the instruction for setting `PLANE_API_KEY`.

## Verify

```bash
ls ~/.claude/skills/plane-api/SKILL.md
echo $PLANE_API_KEY
```

The first command confirms the skill is installed. The second should print
your API key — if it is empty, add `export PLANE_API_KEY="your-key-here"`
to `~/.zshrc` and run `source ~/.zshrc`.
