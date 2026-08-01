# Signal Desktop

> **Profiles:** `[workstation]`
> **Platforms:** ubuntu-24.04 (primary)

End-to-end encrypted messaging and calls. Installed from Signal's **official apt
repository** so it updates cleanly through `apt` alongside the rest of the system.

## Why the official apt repo

Signal publishes a first-party apt repository (`updates.signal.org`), so this
module uses it directly rather than a Flatpak or a standalone `.deb`:

- Updates arrive through normal `apt upgrade` — no bundled self-updater.
- The package is authenticated against Signal's signing key via a `signed-by`
  keyring in `/usr/share/keyrings/`, scoped so the key can only sign the Signal
  repo (not the whole system).

Signal serves its own deb822 source file, so `install.sh` **fetches that file
verbatim** instead of hardcoding the suite/architecture — those have drifted in
the past, and fetching keeps the module current automatically.

## Install

```bash
bash scripts/install.sh
```

The script is idempotent (safe to re-run): it guards the keyring, the apt
source, and the package install so a second run is a no-op.

It performs three steps, matching Signal's official instructions:

1. Fetches `https://updates.signal.org/desktop/apt/keys.asc`, dearmors it, and
   installs it to `/usr/share/keyrings/signal-desktop-keyring.gpg`.
2. Fetches the deb822 source from
   `https://updates.signal.org/static/desktop/apt/signal-desktop.sources` and
   installs it to `/etc/apt/sources.list.d/signal-desktop.sources`.
3. `apt-get update` + `apt-get install signal-desktop`.

## Verify

```bash
bash scripts/verify.sh
```

Checks that the package installed, the `signal-desktop` binary is on PATH, and
the desktop entry exists. All checks should report `[OK]`.

Manual equivalents:

```bash
dpkg -s signal-desktop            # Status: install ok installed
command -v signal-desktop         # /usr/bin/signal-desktop
ls /usr/share/applications/signal-desktop.desktop
```

## After installing — link your phone

1. Launch Signal from the application menu, or run `signal-desktop`.
2. First launch shows a **QR code**. On your phone, open **Signal → Settings →
   Linked Devices → +** and scan it.
3. Signal Desktop is a *linked device*, not a standalone account — your phone
   remains the primary. Message history syncs after linking.

## Updating

Handled by `apt` with the rest of the system:

```bash
sudo apt-get update && sudo apt-get upgrade
```

## Platform notes

| Platform | Notes |
|----------|-------|
| ubuntu-24.04 | Standard install. The upstream repo publishes a single `xenial` suite for `amd64`; this is Signal's own naming, not a per-Ubuntu-release build. |

## Troubleshooting

- **`apt update` fails with a GPG/`NO_PUBKEY` error** → the keyring did not
  install; re-run `bash scripts/install.sh` (it will re-fetch the key).
- **QR code never appears / window is blank** → Signal is an Electron app;
  ensure you launched it in a graphical session, not over plain SSH.
- **"This device is no longer registered"** → the phone unlinked it; re-link via
  Settings → Linked Devices on the phone.
