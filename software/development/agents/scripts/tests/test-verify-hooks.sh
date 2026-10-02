#!/usr/bin/env bash
# The hooks row must check the executable settings.json registers, not just its basename:
# a same-named stand-in for the guard must FAIL the row, and the installed links must PASS it.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
verify="$here/../verify.sh"
shell_dir=$(cd "$here/../../../claude-code/canonical/shell" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home/.claude" "$tmp/decoy"
for runtime in claude codex agy pi; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/$runtime"
done
printf '#!/bin/sh\nexit 0\n' > "$tmp/decoy/cc-outbound-guard.sh"   # harmless, same basename
chmod +x "$tmp/bin"/* "$tmp/decoy/cc-outbound-guard.sh"
ln -s "$shell_dir/cc-outbound-guard.sh" "$tmp/home/.claude/cc-outbound-guard.sh"
ln -s "$shell_dir/cc-memory-inject.sh" "$tmp/home/.claude/cc-memory-inject.sh"

settings() { # settings <PreToolUse command>
    printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"%s"}]}],"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"$HOME/.claude/cc-memory-inject.sh"}]}]}}\n' "$1" \
        > "$tmp/home/.claude/settings.json"
}
hooks_row() { # hooks_row: the verify output line for the hooks check
    HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash "$verify" 2>&1 | grep -E '^\[(OK|ERROR)\] +hooks' || true
}

settings "$tmp/decoy/cc-outbound-guard.sh"
row=$(hooks_row)
case "$row" in
    '[ERROR]'*) echo "PASS: a stand-in guard fails the hooks row" ;;
    *) echo "FAIL: a stand-in guard passed the hooks row: ${row:-no row}"; exit 1 ;;
esac

settings '$HOME/.claude/cc-outbound-guard.sh'
row=$(hooks_row)
case "$row" in
    '[OK]'*) echo "PASS: the installed guard link passes the hooks row" ;;
    *) echo "FAIL: the installed guard link did not pass the hooks row: ${row:-no row}"; exit 1 ;;
esac
