#!/usr/bin/env bash
# The guard allowlist row must FAIL on an empty AGENTS_INTERNAL_HOSTS in any quoting
# (the guard then allows loopback only) and PASS on a real entry.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
verify="$here/../verify.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home/.config/agents"
for runtime in claude codex agy pi; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/$runtime"
done
chmod +x "$tmp/bin"/*

allowlist_row() { # allowlist_row <env line>: the verify output line for the allowlist check
    printf '%s\n' "$1" > "$tmp/home/.config/agents/env"
    HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash "$verify" 2>&1 | grep -E '^\[(OK|ERROR)\] +guard allowlist' || true
}

for line in "export AGENTS_INTERNAL_HOSTS=" "export AGENTS_INTERNAL_HOSTS=''" 'export AGENTS_INTERNAL_HOSTS=""'; do
    row=$(allowlist_row "$line")
    case "$row" in
        '[ERROR]'*) ;;
        *) echo "FAIL: empty allowlist ($line) did not fail the row: ${row:-<no row>}"; exit 1 ;;
    esac
done
for line in "export AGENTS_INTERNAL_HOSTS='tracker.internal'" 'export AGENTS_INTERNAL_HOSTS="tracker.internal"'; do
    row=$(allowlist_row "$line")
    case "$row" in
        '[OK]'*) ;;
        *) echo "FAIL: allowlist ($line) did not pass the row: ${row:-<no row>}"; exit 1 ;;
    esac
done
echo 'PASS: allowlist row fails on an empty value in any quoting'
