# Razer on Ubuntu 24.04

Verified against: Ubuntu 24.04.4 LTS, kernel `6.17.0-35-generic`, GNOME.

## DKMS / kernel headers

OpenRazer ships the driver as a DKMS module (`openrazer-driver-dkms`), so it
rebuilds for each kernel. It needs `linux-headers-$(uname -r)`:

```bash
dpkg -s linux-headers-$(uname -r)        # confirm present
```

On this machine `linux-headers-6.17.0-35-generic` is installed, so the module
builds at install time. After a kernel upgrade, DKMS rebuilds automatically; if
a device stops responding after an upgrade, check `dkms status | grep -i razer`
and reboot.

## The plugdev / reboot gate

OpenRazer requires the user to be in the `plugdev` group. `install.sh` runs
`gpasswd -a $USER plugdev`, but **group membership only applies to new login
sessions.** The OpenRazer docs call a full reboot "essential" — prefer reboot
over logout/login so the freshly built DKMS module and udev rules are loaded
cleanly. Confirm after reboot:

```bash
id -nG | tr ' ' '\n' | grep -x plugdev
```

## PPAs vs. the Ubuntu repos

OpenRazer is in Ubuntu `universe`, but it lags upstream and may miss newer
device support. The module uses the official `ppa:openrazer/stable` for current
device coverage. `universe` must still be enabled (it carries dependencies);
`install.sh` ensures this.

## BlackWidow V3 Pro (`1532:025c`) — wired vs. wireless

The BlackWidow V3 Pro is a dual-mode (wired/2.4GHz wireless) keyboard. OpenRazer
support landed via PRs #1622 (wired) and #1623 (wireless); `1532:025c` is
recognized as an alias of the primary `1532:025a`. Wireless-mode feature
coverage has historically trailed wired in OpenRazer — if a specific
effect/feature is missing over the dongle, connect via the charging cable to
confirm whether it's a wireless-path limitation.

## Wayland vs. X11

Unlike Conky-based tooling, OpenRazer/Polychromatic are display-server agnostic
(they talk to the device via the kernel driver + D-Bus daemon, not the
compositor). Works under both GNOME Wayland and X11. Note that *macro/key-replay*
tooling (the macro-gap follow-up) is the part that cares about Wayland vs. X11 —
see `../README.md` "Macro gap" and the task's `macro-gap.md`.
