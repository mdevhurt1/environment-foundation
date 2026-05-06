# environment-foundation

A personal, versioned reference for setting up any machine — from a fresh OS
install to a fully configured working environment. Covers the full stack for
any context: development, gaming, personal computing, creative work.

Public under the MIT license for OSS convenience. Authored for personal use
first.

## How it works

Three layers build on each other:

1. **Platform baseline** (`platforms/`) — OS-level setup: system updates,
   core utilities, shell configuration, SSH.
2. **Software modules** (`software/`) — self-contained install and config for
   each piece of software. Documents platform exceptions where behavior differs.
3. **Profile guides** (`profiles/`) — ordered checklists that sequence
   baseline + software for a specific use-case context. Start here.

## Start here

Pick the profile that matches your machine:

| Profile | Use case |
|---------|----------|
| [Workstation](profiles/workstation.md) | Full personal machine: development + optional gaming |
| [Workplace](profiles/workplace.md) | Work machine: development, no gaming |
| [Gaming](profiles/gaming.md) | Gaming-focused setup |

## Supported platforms

| Platform | Status |
|----------|--------|
| Ubuntu 24.04 LTS | Primary |
| Ubuntu 22.04 LTS | Supported |
| Windows 11 (WSL2) | Supported |

## Adding a new platform or software module

- New **platforms** go in `platforms/<os-version>/` following the structure
  of `platforms/ubuntu-24.04/`.
- New **software modules** go in `software/<category>/<name>/` following the
  structure of any existing module.
- New **categories** go at the same level as `development/` and `gaming/`
  inside `software/` when the boundary is clear.

## License

MIT
