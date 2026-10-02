#!/usr/bin/env bash
# A broken GPU should make only the live probe row fail when the watch is installed.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
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
