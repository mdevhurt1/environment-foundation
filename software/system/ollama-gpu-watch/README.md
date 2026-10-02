# Ollama GPU watch

> **Profiles:** `[workstation]`
> **Platforms:** ubuntu-24.04 (primary)

Detects the failure that every other check misses: the Ollama container on a
GPU host stays up and answers HTTP 200, but has lost the GPU and serves every
model on the CPU, 10-240x slower (AI_ST-106).

Seen on marcus-desktop (RTX 3090):

- **2026-09-25:** unattended-upgrades moved the nvidia driver 595.84 ->
  595.91.07; NVML then broke inside the running `ollama` container for 6.5 h
  (`docker exec ollama nvidia-smi -L` = `Failed to initialize NVML: Unknown
  Error`, `/api/ps` `size_vram=0`, 16 tokens in 49.7 s). The host's
  `nvidia-smi` was healthy throughout. Fix: `docker restart ollama`.
- **2026-10-01, with no driver change** (host and image both at 595.91.07):
  the same NVML error and `qwen3.6:35b` at `size_vram=0`. The container was
  started 2026-09-30 12:18Z; the log shows CUDA init failing from at least
  2026-10-01 20:47Z, with 26 systemd `Reloading` events since that start. This
  matches the second known trigger: a `systemctl daemon-reload` under cgroup v2
  drops a running container's device-cgroup grant.

## Why this approach

A probe of the *evidence*, not of liveness. `ollama-gpu-probe` fails when any
of these is true:

1. `docker exec ollama nvidia-smi --query-gpu=name,driver_version` exits
   non-zero or prints an NVML error. This catches both triggers.
2. The driver version inside the container differs from the host's
   (`nvidia-smi` on the host, or `/proc/driver/nvidia/version` as a fallback).
   This is the 09-25 signature: a driver upgraded under a running container.
3. A model in `/api/ps` has `size_vram/size` below `OGW_MIN_VRAM_RATIO`
   (default 0.50). A healthy `qwen3.6:35b` sits at ~0.90 because it spills
   ~1.7 GiB, so the gate is a ratio with a low floor and not `== 1`. With no
   model loaded the probe does not fail on this check.
4. With `--bench` only: a short timed generation against the smallest loaded
   model decodes below `max(OGW_MIN_TOKS, OGW_BASELINE_FRACTION x baseline)`.
   The rate is `eval_count / eval_duration`, so load time is excluded.
   `--bench` never picks a model to load: it uses one that is already loaded,
   or `OGW_BENCH_MODEL` if you set it. Record a baseline once, while healthy:
   `ollama-gpu-probe --bench --save-baseline`.

Output is one line: `OK ollama-gpu: gpu=... driver host=X container=X
models=name@93.9%vram ...` (exit 0), or `FAIL ollama-gpu: <reason>` (exit 1).
Usage errors exit 2. All thresholds are environment variables, or `KEY=VALUE`
lines in `~/.config/ollama-gpu-watch/config`; they are listed in the probe's
header.

A systemd **user** timer runs the probe every 15 minutes. On failure the
service raises a critical `notify-send` notification, the unit goes `failed`
(visible in `systemctl --user --failed`), and the probe writes
`~/.local/share/node_exporter/ollama_gpu_ok.prom`:

```
ollama_gpu_ok{container="ollama",host_driver="595.91.07",container_driver="595.91.07"} 1
ollama_gpu_probe_timestamp_seconds 1790000000
ollama_gpu_vram_ratio{model="qwen3.6:35b"} 0.939
```

No node-exporter runs on marcus-desktop today (checked 2026-10-01: no
`node_exporter` binary, no unit, no container, nothing on :9100). The file is
written anyway so that adding node-exporter with
`--collector.textfile.directory=$HOME/.local/share/node_exporter` makes the
metric scrapeable with no change here.

## Install

```bash
bash scripts/install.sh      # links the probe + units, enables the timer
systemctl --user start ollama-gpu-watch.service   # first run now
bash scripts/verify.sh
```

`install.sh` needs no root and installs no packages. It needs docker-group
membership, `jq` and `curl`. User timers stop when the user's last session
ends unless lingering is on (`loginctl enable-linger $USER`).

## Verify

```bash
bash scripts/verify.sh       # timer enabled+active, last run, fresh metric, live probe
bash scripts/test.sh         # offline unit test with stubbed docker/nvidia-smi/curl
```

`test.sh` replays the healthy case and every failure signature. Its positive
control feeds the probe the exact 09-25 output (`Failed to initialize NVML:
Unknown Error`) and asserts `FAIL`.

## Uninstall

```bash
bash scripts/uninstall.sh          # dry run: prints what would go
bash scripts/uninstall.sh --yes
```

This removes the links, the timer enablement and the metric file. It keeps your
config, the stored baseline, and everything about the ollama container.

## Remedy, as opposed to detection: an apt post-invoke restart (not installed)

This hook restarts the container after any dpkg run that changed an nvidia
driver package. It lives in `/etc/apt/apt.conf.d`, so it needs root and is a
**human step**. The module does not install it.

```bash
sudo tee /usr/local/sbin/restart-ollama-on-nvidia-change >/dev/null <<'SH'
#!/bin/sh
# Restart the ollama container when the installed nvidia driver packages change.
stamp=/var/lib/ollama-nvidia-pkg.stamp
now=$(dpkg-query -W -f='${Package} ${Version}\n' 'nvidia-driver-*' 'libnvidia-compute-*' 2>/dev/null | sort)
[ "$now" = "$(cat "$stamp" 2>/dev/null)" ] && exit 0
printf '%s\n' "$now" > "$stamp"
docker ps -q --filter name='^ollama$' | grep -q . && docker restart ollama >/dev/null 2>&1
exit 0
SH
sudo chmod 0755 /usr/local/sbin/restart-ollama-on-nvidia-change
echo 'DPkg::Post-Invoke { "/usr/local/sbin/restart-ollama-on-nvidia-change || true"; };' \
  | sudo tee /etc/apt/apt.conf.d/99-restart-ollama-on-nvidia-change
```

**Recommendation: do not add it yet. Install the probe first.** The hook covers
one trigger, the 09-25 driver upgrade. It would not have prevented the
2026-10-01 detach, which happened with no driver change. It also restarts
inference mid-request, during an unattended run. If the new kernel module has
not loaded yet (no reboot), the restarted container can still be broken, and
only the probe would show that. The root-cause fix for the daemon-reload
trigger is in the nvidia-container-toolkit configuration (CDI device injection,
or explicit `/dev/nvidia*` device entries, instead of the legacy
`runtime: nvidia` hook). That is a separate change, tracked as a follow-up.

## Platform notes

| Platform | Notes |
|----------|-------|
| ubuntu-24.04 | Supported. Intended for the GPU host that runs the `ollama` container (marcus-desktop). |
