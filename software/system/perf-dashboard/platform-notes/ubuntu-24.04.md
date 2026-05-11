# Ubuntu 24.04 — perf-dashboard notes

## Display server requirement

This module's Tier 2 (Conky widget) requires **X11**. Ubuntu 24.04 ships
with Wayland by default for fresh installs.

Verify your session:

```bash
echo $XDG_SESSION_TYPE
```

If this returns `wayland`, the install scripts will install Conky as an
apt package (harmless when not running) but `configure.sh` will skip the
autostart registration and print a notice.

To switch to X11: at the GDM login screen, click your username, then
click the gear icon at the bottom-right and choose "Ubuntu on Xorg".

## Hybrid GPU detection

The validated configuration is NVIDIA RTX 4070 Mobile (dGPU) + AMD
Phoenix iGPU. The AMD iGPU surfaces under `/sys/class/drm/cardN/` with
`vendor` `0x1002`. The card index can shift across kernel updates.

`configure.sh` detects the AMD card by scanning `/sys/class/drm/card*/device/vendor`
and templates the result into `~/.config/conky/perf-dashboard.conkyrc`.
If the iGPU section breaks after a kernel update, re-run `configure.sh`.

The NVIDIA dGPU is queried via `nvidia-smi` directly. Under PRIME
render-offload (the default on Ubuntu 24.04), the dGPU is asleep most
of the time and `nvidia-smi` calls add a small wakeup cost. The
Conky widget guards `${nvidia}` calls with `${if_match}` so a sleeping
dGPU shows "(asleep / unavailable)" rather than spamming wakeups.

## power-profiles-daemon

Not installed by default on every Ubuntu 24.04 image. `install.sh`
installs it as a hard dependency. The Conky "Profile" line uses
`powerprofilesctl get` directly.
