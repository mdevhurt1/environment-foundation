# Workstation Profile

Full personal machine setup: development tools, Claude Code, and optional
gaming. Primary target platform is Ubuntu 24.04.

> **Applies to:** Ubuntu 24.04 (primary) · Ubuntu 22.04 · Windows 11 (WSL)
>
> For Ubuntu 22.04 or Windows 11, follow each link below and check the
> module's platform notes before running any script.

---

## Setup sequence

### 1. Platform baseline

Run all baseline steps in order:

- [ ] [System update](../platforms/ubuntu-24.04/scripts/01-system-update.sh) `[all]`
- [ ] [Core packages](../platforms/ubuntu-24.04/scripts/02-core-packages.sh) `[all]`
- [ ] [Shell setup](../platforms/ubuntu-24.04/scripts/03-shell-setup.sh) `[all]`
- [ ] [SSH config](../platforms/ubuntu-24.04/scripts/04-ssh-config.sh) `[all]`

### 2. Development tools

- [ ] [Claude Code — install](../software/development/claude-code/scripts/install.sh) `[dev]`
- [ ] [Claude Code — configure](../software/development/claude-code/scripts/configure.sh) `[dev]`
- [ ] [Docker — install](../software/development/docker/scripts/install.sh) `[dev]`
- [ ] [Docker — configure](../software/development/docker/scripts/configure.sh) `[dev]`
- [ ] [Plane — verify](../software/development/claude-code/integrations/plane/README.md) `[workstation]` — read-only check; run after Claude Code configure and `environment-secrets/install.sh`

### 3. System

- [ ] [Performance Dashboard — install](../software/system/perf-dashboard/scripts/install.sh) `[workstation]` — three-tier glanceable system monitor (Vitals + Conky + Netdata)
- [ ] [Performance Dashboard — configure](../software/system/perf-dashboard/scripts/configure.sh) `[workstation]`

### 4. Gaming *(skip on workplace or headless machines)*

- [ ] [Steam — install](../software/gaming/steam/scripts/install.sh) `[gaming]`
- [ ] [Discord — install](../software/gaming/discord/scripts/install.sh) `[gaming]`
