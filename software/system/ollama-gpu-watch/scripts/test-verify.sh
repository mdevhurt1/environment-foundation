#!/usr/bin/env bash
# Description: Offline acceptance fixture for scripts/verify.sh. Stubs the
#              probe, systemctl and the metric file in a temp HOME: a broken
#              GPU must fail only the live probe row, and a never-run service
#              with no metric file must fail acceptance.
#              Touches no real unit, GPU or textfile directory.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: bash, mktemp
# Idempotent.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT="$(cd "$here/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home/.local/bin" "$tmp/home/.local/share/node_exporter" \
    "$tmp/home/.config/systemd/user" "$tmp/bin"
touch "$tmp/home/.config/systemd/user/ollama-gpu-watch.service"
touch "$tmp/home/.config/systemd/user/ollama-gpu-watch.timer"
printf 'ollama_gpu_ok{container="ollama"} 0\n' > "$tmp/home/.local/share/node_exporter/ollama_gpu_ok.prom"

cat > "$tmp/home/.local/bin/ollama-gpu-probe" <<'STUB'
#!/usr/bin/env bash
echo 'FAIL ollama-gpu: NVML broken inside container'
exit 1
STUB
cat > "$tmp/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *ExecMainStartTimestamp*) echo 'Fri 2026-10-02 10:00:00 EDT' ;;
    *ExecMainStatus*) echo 1 ;;
    *Result*) echo exit-code ;;
    *) exit 0 ;;
esac
STUB
cat > "$tmp/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
echo 'FAIL ollama-gpu: NVML broken inside container'
STUB
chmod +x "$tmp/home/.local/bin/ollama-gpu-probe" "$tmp/bin"/*

set +e
out=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash "$here/verify.sh" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 1 ] || ! grep -q '1 check(s) failed' <<< "$out"; then
    echo "FAIL: expected only live probe to fail (rc=$rc)"
    echo "$out"
    exit 1
fi
echo 'PASS: GPU failure is reported by the live probe row only'

# F4: a service with no recorded start must not skip the metric checks. Probe is
# healthy, ExecMainStartTimestamp is empty, and the metric file is absent: fail.
rm -f "$tmp/home/.local/share/node_exporter/ollama_gpu_ok.prom"
cat > "$tmp/home/.local/bin/ollama-gpu-probe" <<'STUB'
#!/usr/bin/env bash
echo 'OK ollama-gpu: on GPU'
exit 0
STUB
cat > "$tmp/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *ExecMainStartTimestamp*) echo '' ;;
    *) exit 0 ;;
esac
STUB
set +e
out=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash "$here/verify.sh" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 1 ] || ! grep -q 'metric file written' <<< "$out" || grep -q 'All checks passed' <<< "$out"; then
    echo "FAIL: never-run service with no metric file must fail acceptance (rc=$rc)"
    echo "$out"
    exit 1
fi
# ...and with a fresh valid metric file the same state passes.
printf 'ollama_gpu_ok{container="ollama"} 1\n' > "$tmp/home/.local/share/node_exporter/ollama_gpu_ok.prom"
set +e
out=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash "$here/verify.sh" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    echo "FAIL: never-run service with fresh valid metric should pass (rc=$rc)"
    echo "$out"
    exit 1
fi
echo 'PASS: metric checks run even when the service has no recorded start'
