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
