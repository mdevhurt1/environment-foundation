# Elgato Stream Deck (Boatswain)

> **Profiles:** `[workstation]`
> **Platforms:** ubuntu-24.04 (primary)

Linux-native control for Elgato Stream Deck devices, replacing Elgato's
Windows/macOS-only Stream Deck software.

- **Boatswain** — GTK4 application that binds Stream Deck keys and dials to
  actions (launch commands, OBS scene switching via `obs-websocket`, media
  keys, MPRIS control). Installed as a Flatpak from Flathub.
- **udev rule** — grants the logged-in desktop user access to the device.

Developed against a **Stream Deck Plus** (`0fd9:0084`). The udev rule matches
Elgato's vendor ID `0fd9`, so it covers every Stream Deck model without
modification.

## Why a udev rule is required

Stream Decks are USB HID devices. By default the kernel creates their
`/dev/hidraw*` node owned by `root:root` with mode `0600`, so an unprivileged
desktop app cannot open it — Boatswain launches but reports no devices found.

The rule tags the device with `uaccess`, which makes `systemd-logind` grant the
active session's user an ACL on the node at login. `GROUP="users"` is a fallback
for setups where `uaccess` does not apply.

```
SUBSYSTEMS=="usb", ATTRS{idVendor}=="0fd9", GROUP="users", TAG+="uaccess"
```

Installed to `/etc/udev/rules.d/10-streamdeck.rules`.

## Install

```bash
bash scripts/install.sh
```

Installs Boatswain from Flathub, writes the udev rule, and reloads udev. Both
steps are idempotent — re-running is safe.

> **Replug required.** udev rules apply at device enumeration. A Stream Deck
> that was already plugged in keeps its old root-owned permissions until you
> physically unplug and reconnect it. `install.sh` prints this warning only when
> it actually changed the rule.

## Verify

```bash
bash scripts/verify.sh
```

Checks the flatpak is installed, the rule is present, the device is attached,
and at least one `hidraw` node is read/write for your user. Exits non-zero on
failure. With no device connected it warns and skips the device checks rather
than failing — the module installs correctly on a machine with no Stream Deck.

## Usage

```bash
flatpak run com.feaneron.Boatswain
```

Boatswain is also in the application menu. To drive OBS scenes from the deck,
enable **Tools → WebSocket Server Settings** in OBS and add an OBS action in
Boatswain — see the [OBS Studio module](../../media/obs-studio/README.md).

## Troubleshooting

| Symptom | Cause |
|---|---|
| Boatswain shows no devices | Rule not applied — unplug and reconnect the device |
| Still nothing after replug | Confirm `lsusb \| grep 0fd9` sees it; check the cable is data-capable, not charge-only |
| Works as root only | The `uaccess` tag did not take effect; confirm you are on an active logind session (`loginctl show-session $XDG_SESSION_ID -p Active`) |
