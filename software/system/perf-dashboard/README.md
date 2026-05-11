# Performance Dashboard

> **Profiles:** `[workstation]`
> **Platforms:** ubuntu-24.04 (primary)

Three-tier always-on performance dashboard for a Linux laptop. Optimised for glanceability and low resource cost.

- **Tier 1 — GNOME Vitals top bar:** CPU%, RAM%, CPU temp, dGPU usage. Always visible across workspaces.
- **Tier 2 — Conky widget on the second monitor:** rich live view with both GPUs, top-N processes, color-coded threshold flags, battery, power profile.
- **Tier 3 — Netdata, loopback only:** `http://127.0.0.1:19999/`. Fixed 60s polling, ~7 days of history, alerting in the web UI.

See `docs/superpowers/specs/2026-05-10-performance-dashboard-design.md` (vault-mirrored) for the full design and rationale.

## Dependencies

Installed by `install.sh`:

- `conky-all` — widget engine
- `power-profiles-daemon` — for `powerprofilesctl` (Conky "Profile" readout)
- `lm-sensors` — temperature sensor detection
- `gnome-shell-extension-manager` — GUI fallback for managing extensions
- `curl`, `jq` — used by install/doctor scripts
- Netdata — installed via the official kickstart with `--disable-telemetry --no-updates`
- Vitals GNOME extension — installed via D-Bus (one user-confirmation dialog)

## Install

```bash
bash scripts/install.sh
bash scripts/configure.sh
```

After install, **log out and back in** to activate the Vitals extension. (GNOME extensions cannot be hot-loaded into a running shell session.)

## Verify

```bash
bash scripts/doctor.sh
```

All checks should report `[PASS]`. Reach Tier 3 in a browser at <http://127.0.0.1:19999/>.

## Uninstall

```bash
bash scripts/uninstall.sh
```

Interactive — prompts before each destructive step.

## Platform notes

| Platform | Notes |
|----------|-------|
| ubuntu-24.04 | Fully supported. Tier 2 requires X11. See `platform-notes/ubuntu-24.04.md`. |

## Troubleshooting

- **Vitals not in top bar after install** → log out/in; or `gnome-extensions enable Vitals@CoreCoding.com`
- **Conky not on the second monitor** → edit `xinerama_head` in `~/.config/conky/perf-dashboard.conkyrc` (defaults to head 1)
- **AMD iGPU section shows error** → re-run `bash scripts/configure.sh` (re-detects the card)
- **Netdata web UI unreachable** → `systemctl status netdata`; logs via `journalctl -u netdata`
- **`doctor.sh` reports a security FAIL on Netdata bind** → STOP. Inspect `/etc/netdata/netdata.conf` for the `[web].bind to` line; it must read `127.0.0.1`. Do not connect this machine to untrusted networks until fixed.
