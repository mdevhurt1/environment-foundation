# Windows 11 Baseline

Development work on Windows 11 is done through WSL2 (Windows Subsystem for
Linux) running Ubuntu 24.04. Gaming uses Windows-native tools.

## Prerequisites

1. Windows 11 with the latest updates applied
2. WSL2 installed and configured with Ubuntu 24.04 as the default distribution

## Installing WSL2

Open PowerShell as Administrator and run:

```powershell
wsl --install
```

Restart when prompted. Ubuntu 24.04 will be installed as the default
distribution. After restarting, open Ubuntu from the Start menu to complete
the initial setup.

## Development setup

Once inside the WSL2 Ubuntu terminal, follow the
[Ubuntu 24.04 baseline](../ubuntu-24.04/README.md) exactly. The WSL
environment is functionally equivalent for development purposes.

## Gaming setup

Gaming software runs in Windows natively — do not use WSL for gaming setup.
See the [gaming profile](../../profiles/gaming.md) and follow the
Windows-specific notes in each gaming software module.

## Limitations in WSL

- Scripts that modify systemd services may not work — WSL2 uses a lightweight
  init. If a script tries to `systemctl enable` something and fails, start the
  service manually instead.
- USB device passthrough requires additional WSL configuration.
- GUI applications require WSLg (included in Windows 11 by default).
