# Razer Peripherals (OpenRazer + Polychromatic)

> **Profiles:** `[workstation]` `[gaming]`
> **Platforms:** ubuntu-24.04 (primary)

Linux-native control for Razer peripherals, replacing Razer Synapse (Windows-only).

- **OpenRazer** — open-source kernel driver (DKMS) + user-space daemon that
  exposes Razer device features (lighting, DPI, polling rate, battery) to Linux.
- **Polychromatic** — GUI (`polychromatic-controller`) and CLI
  (`polychromatic-cli`) front-end for OpenRazer: per-device effects, profiles,
  and quick toggles.

## Detected hardware

| Device | USB ID | OpenRazer support |
|--------|--------|-------------------|
| Razer BlackWidow V3 Pro (keyboard) | `1532:025c` | Supported (alias of primary `1532:025a`) |

Only the keyboard enumerates on USB at present. If a Razer mouse with a wireless
dongle is added, OpenRazer will surface it Synapse-style once the daemon is
running — re-run `scripts/verify.sh` to confirm it appears.

## Dependencies

Installed by `install.sh` (all from official PPAs):

- `openrazer-meta` — pulls the DKMS driver (`openrazer-driver-dkms`) and daemon.
  Requires `linux-headers-$(uname -r)` so DKMS can build the module (already
  present on this machine).
- `polychromatic` — GUI controller + CLI.

PPAs added: `ppa:openrazer/stable`, `ppa:polychromatic/stable`. The script also
ensures the Ubuntu `universe` component is enabled (an OpenRazer dependency).

## Install

```bash
bash scripts/install.sh
```

> **⚠️ A reboot is required.** `install.sh` adds your user to the `plugdev`
> group, which OpenRazer needs to access the device. The group change does not
> take effect in the current session — **reboot before verifying** (a full
> reboot is recommended over logout/login, per the OpenRazer docs, so the DKMS
> module and udev rules load cleanly).

## Verify

After rebooting:

```bash
bash scripts/verify.sh
```

Checks that the DKMS module built, the daemon runs, and Polychromatic sees the
BlackWidow. All checks should report `[OK]`.

Manual equivalents:

```bash
dkms status | grep -i razer            # module built + installed
openrazer-daemon -v                    # daemon version prints
polychromatic-cli --list-devices       # BlackWidow V3 Pro listed
```

## Macro gap

OpenRazer + Polychromatic cover lighting, DPI, polling rate, and basic key
remapping well, but **do not replicate Synapse's macro/automation engine.**
This is a known constraint. Closing it is a separate, CEO-dispatched follow-up —
see `~/vault/20-surface/company/tasks/razer-software/macro-gap.md` for the
recommendation (candidates: `input-remapper`, `keyd`, per-game configs).

## Platform notes

| Platform | Notes |
|----------|-------|
| ubuntu-24.04 | Fully supported. DKMS builds against kernel 6.17.x with headers installed. See `platform-notes/ubuntu-24.04.md`. |

## Troubleshooting

- **`dkms status` shows no razer module** → confirm `linux-headers-$(uname -r)`
  is installed, then `sudo dkms autoinstall` and reboot.
- **Daemon runs but `--list-devices` is empty** → you have not rebooted since
  `gpasswd -a $USER plugdev`; confirm membership with `id -nG | grep plugdev`.
- **BlackWidow V3 Pro in wireless mode behaves oddly** → wireless support has
  historically been less complete than wired; connect via the charging cable if
  a feature is missing. See `platform-notes/ubuntu-24.04.md`.
- **PPA add fails on a minimal install** → `sudo apt install software-properties-common`
  provides `add-apt-repository`.
