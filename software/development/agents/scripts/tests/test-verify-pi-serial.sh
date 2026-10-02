#!/usr/bin/env bash
# The two Pi probes must never run against local Ollama at the same time.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
verify="$here/../verify.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"

cat > "$tmp/bin/pi" <<'STUB'
#!/usr/bin/env bash
printf 'called\n' >> "$PI_TEST_DIR/calls"
if ! mkdir "$PI_TEST_DIR/lock" 2>/dev/null; then
    : > "$PI_TEST_DIR/overlap"
fi
sleep 0.3
rmdir "$PI_TEST_DIR/lock" 2>/dev/null || true
STUB
for runtime in claude codex agy; do
    cat > "$tmp/bin/$runtime" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
done
chmod +x "$tmp/bin"/*

HOME="$tmp/home" PATH="$tmp/bin:$PATH" PI_TEST_DIR="$tmp" bash "$verify" > "$tmp/verify.out" 2>&1 || true
test "$(wc -l < "$tmp/calls")" -eq 2
if [ -e "$tmp/overlap" ]; then
    echo 'FAIL: Pi probes overlapped'
    exit 1
fi
echo 'PASS: both Pi probes ran without overlap'
