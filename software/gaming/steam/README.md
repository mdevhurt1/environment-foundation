# Steam

> **Profiles:** `[gaming]` `[workstation]`
> **Platforms:** ubuntu-24.04 (primary), ubuntu-22.04

Valve's game distribution platform. Installs the official Steam client with
i386 (32-bit) support required for many games.

## Install

```bash
bash scripts/install.sh
```

## Platform notes

| Platform | Notes |
|----------|-------|
| ubuntu-24.04 | Standard install |
| ubuntu-22.04 | Standard install |
| windows-11 | Download the installer from https://store.steampowered.com — do not use this script |

## After installing

1. Launch Steam from the application menu
2. Log in to your Steam account
3. Enable Steam Play (Proton) for Windows games:
   **Steam → Settings → Compatibility → Enable Steam Play for all titles**

## GPU drivers

Steam performance depends on having the correct GPU drivers installed. Install
your GPU drivers before Steam:

- NVIDIA: see `software/development/nvidia-drivers/` *(add when needed)*
- AMD: included in the Ubuntu kernel; install `mesa-vulkan-drivers` for Vulkan

## Verify

Launch Steam from the application menu or run `steam` in the terminal.
