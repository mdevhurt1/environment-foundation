# Docker

> **Profiles:** `[dev]` `[workstation]` `[workplace]`
> **Platforms:** ubuntu-24.04 (primary), ubuntu-22.04 (see platform notes), windows-11 (WSL)

Docker Engine for building and running containers. Installs the official
Docker CE packages (not the snap or distro version).

## Install

```bash
bash scripts/install.sh
```

## Configure

```bash
bash scripts/configure.sh
```

Configure adds your user to the `docker` group so you can run Docker without
`sudo`, and enables the Docker service on boot.

## Platform notes

| Platform | Notes |
|----------|-------|
| ubuntu-24.04 | Standard install |
| ubuntu-22.04 | GPG key path differs — see [platform-notes/ubuntu-22.04.md](platform-notes/ubuntu-22.04.md) |
| windows-11 | Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) natively — do not use this script in WSL |

## Verify

```bash
docker run --rm hello-world
```

> **Note:** Log out and back in after running configure.sh for group membership
> to take effect.
