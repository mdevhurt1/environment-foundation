# OBS Studio

> **Profiles:** `[workstation]`
> **Platforms:** ubuntu-24.04 (primary)

Free, open-source software for video recording and live streaming. Installed from
the **official OBS Project PPA** so it updates cleanly through `apt` alongside the
rest of the system.

## Why the official PPA

The OBS Project publishes a first-party Launchpad PPA
(`ppa:obsproject/obs-studio`), so this module uses it directly rather than a
Flatpak or Snap:

- Updates arrive through normal `apt upgrade` — no separate updater or sandbox.
- Builds track upstream OBS releases more closely than the Ubuntu `universe`
  package, which can lag.

`add-apt-repository` (from `software-properties-common`) writes a deb822 source
under `/etc/apt/sources.list.d/` pointing at the Launchpad archive. The installer
guards on that source already being present, so re-runs never add the PPA twice.

`ffmpeg` is installed as a **recommended companion** — OBS uses it for several of
its encoders and muxers.

## Install

```bash
bash scripts/install.sh
```

The script is idempotent (safe to re-run): it guards the PPA add on the source
file already being present, and each package install on `dpkg -s`, so a second
run is a no-op.

It performs three steps:

1. Adds `ppa:obsproject/obs-studio` via `add-apt-repository` (skipped if the
   source already exists in `/etc/apt/sources.list.d/`).
2. `apt-get update` + `apt-get install obs-studio`.
3. `apt-get install ffmpeg` (recommended companion, guarded separately).

## Verify

```bash
bash scripts/verify.sh
```

Checks that the package installed, the `obs` binary is on PATH, and the desktop
entry exists. All checks should report `[OK]`.

Manual equivalents:

```bash
dpkg -s obs-studio                # Status: install ok installed
command -v obs                    # /usr/bin/obs
ls /usr/share/applications/com.obsproject.Studio.desktop
obs --version                     # OBS Studio <version>
```

## After installing

1. Launch OBS from the application menu, or run `obs`.
2. On first launch the **Auto-Configuration Wizard** offers to tune settings for
   streaming or recording — accept it or skip and configure manually.

## Updating

Handled by `apt` with the rest of the system:

```bash
sudo apt-get update && sudo apt-get upgrade
```

## Platform notes

| Platform | Notes |
|----------|-------|
| ubuntu-24.04 | Standard install. The PPA publishes a `noble` build for `amd64`. Screen capture on a Wayland session uses the PipeWire portal; OBS prompts to pick the source. |

## Troubleshooting

- **`add-apt-repository: command not found`** → install
  `software-properties-common`: `sudo apt-get install -y software-properties-common`,
  then re-run the installer.
- **`apt update` fails after adding the PPA** → the PPA has no build for your
  release; confirm the codename with `lsb_release -cs` and check
  [launchpad.net/~obsproject/+archive/ubuntu/obs-studio](https://launchpad.net/~obsproject/+archive/ubuntu/obs-studio).
- **Blank preview / "Failed to initialize video"** → OBS needs OpenGL 3.3+; over
  plain SSH or in a VM without GPU acceleration the preview will not render.
  Launch it in a graphical session.
- **Screen capture is black on Wayland** → use the **Screen Capture (PipeWire)**
  source and grant the portal permission when prompted.
