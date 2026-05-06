# Ubuntu 24.04 LTS Baseline

Takes a fresh Ubuntu 24.04 LTS installation to a ready-to-receive-software
state: updated packages, core utilities, shell, and SSH.

## Prerequisites

- Ubuntu 24.04 LTS installed (minimal or standard)
- User account with sudo access
- Internet connection

## Step index

| Step | Script | Profiles | Description |
|------|--------|----------|-------------|
| 1 | `scripts/01-system-update.sh` | `[all]` | Update system packages |
| 2 | `scripts/02-core-packages.sh` | `[all]` | Install core utilities |
| 3 | `scripts/03-shell-setup.sh` | `[all]` | Install zsh and oh-my-zsh |
| 4 | `scripts/04-ssh-config.sh` | `[all]` | Generate SSH keypair |

## Running the baseline

Run all steps in order:

```bash
bash scripts/01-system-update.sh
bash scripts/02-core-packages.sh
bash scripts/03-shell-setup.sh
bash scripts/04-ssh-config.sh
```

Each script is independently re-runnable. If a previous run was interrupted,
start from the step that failed — earlier steps are idempotent.

## Differences from Ubuntu 22.04

See [`platforms/ubuntu-22.04/README.md`](../ubuntu-22.04/README.md).
