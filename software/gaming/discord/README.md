# Discord

> **Profiles:** `[gaming]` `[workstation]`
> **Platforms:** ubuntu-24.04 (primary), ubuntu-22.04

Voice, video, and text chat. Installed as a Flatpak from Flathub.

## Why Flatpak

Discord ships an official `.deb`, but it does **not** update through `apt` —
its bundled self-updater is unreliable on Linux, so the client periodically
refuses to launch until you manually re-download the package. The Flatpak
build auto-updates cleanly, which suits this repo's goal of durable,
low-maintenance setup. Cost: it introduces Flatpak + the Flathub remote as a
dependency (the install script sets both up for you).

## Install

```bash
bash scripts/install.sh
```

The script installs `flatpak`, adds the Flathub remote, and installs Discord.
A logout/login (or reboot) after the first Flatpak install ensures the
application menu entry and `flatpak` PATH integration are picked up.

## Platform notes

| Platform | Notes |
|----------|-------|
| ubuntu-24.04 | Standard install |
| ubuntu-22.04 | Standard install |
| windows-11 | Download the installer from https://discord.com/download — do not use this script |

## After installing

1. Launch Discord from the application menu, or run `flatpak run com.discordapp.Discord`
2. Log in to your Discord account
3. For screen-share with audio, ensure your system uses PipeWire (default on
   Ubuntu 24.04)

## Updating

Flatpak handles updates automatically. To update on demand:

```bash
flatpak update com.discordapp.Discord
```

## Verify

```bash
flatpak info com.discordapp.Discord
```

Or launch Discord from the application menu.
