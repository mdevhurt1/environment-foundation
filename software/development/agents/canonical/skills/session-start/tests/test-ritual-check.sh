#!/usr/bin/env bash
# Description: Fixture tests for ritual-check.sh (AI_ST-102). Every case pins
# today's date, the Node version and the INFRA-93 target, and builds its own
# state dir and verify marker under a temp dir, so no case depends on the
# machine's vault, Node or network.
#
# Usage: bash tests/test-ritual-check.sh   (from anywhere)

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
check="$here/../ritual-check.sh"
pass=0 fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# fixture <name> <ring-health dates...>: a state dir holding those reports
fixture() {
    local d="$tmp/$1"; shift; mkdir -p "$d"
    for x in "$@"; do : > "$d/ring-health-$x.md"; done
    echo "$d"
}

run() { # run <name> <expect: empty|regex> ; env comes from the caller
    local name=$1 expect=$2 out rc
    out=$(bash "$check" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then echo "FAIL $name: exit $rc"; fail=$((fail+1)); return; fi
    if [ "$expect" = empty ]; then
        if [ -z "$out" ]; then echo "PASS $name"; pass=$((pass+1)); else echo "FAIL $name: expected no output, got: $out"; fail=$((fail+1)); fi
    elif grep -qE -- "$expect" <<<"$out" && head -n1 <<<"$out" | grep -qx 'Rituals overdue:'; then
        echo "PASS $name"; pass=$((pass+1))
    else echo "FAIL $name: wanted /$expect/ under 'Rituals overdue:', got: ${out:-<nothing>}"; fail=$((fail+1)); fi
}

base() { # all-fresh defaults; each case overrides one thing
    export RITUAL_TODAY=2026-10-01 RITUAL_NODE_VERSION=v24.21.0 RITUAL_INFRA93_TARGET=2026-11-01
    export RITUAL_STATE_DIR; RITUAL_STATE_DIR=$(fixture "fresh-$1" 2026-09-02 2026-09-28 2026-09-11)
    export RITUAL_VERIFY_MARKER="$tmp/no-such-marker.json"
}

base 1; run "all fresh -> silent" empty
base 2; RITUAL_STATE_DIR=$(fixture old 2026-09-02 2026-09-16); run "ring-health 15 days old -> flagged" 'ring-maintenance: last run 2026-09-16, 15 days ago'
base 3; RITUAL_STATE_DIR=$(fixture edge 2026-09-24); run "ring-health exactly 7 days old -> silent" empty
base 4; RITUAL_STATE_DIR=$(fixture empty); run "state dir with no reports -> flagged" 'ring-maintenance: no state/ring-health'
base 5; RITUAL_STATE_DIR="$tmp/absent"; run "no vault state dir -> silent" empty
# newest by filename date, not by mtime: an old report touched today must not hide a recent one, nor vice versa
base 6; RITUAL_STATE_DIR=$(fixture mtime 2026-08-01 2026-09-30); touch -d 2020-01-01 "$RITUAL_STATE_DIR/ring-health-2026-09-30.md"; run "filename date wins over mtime" empty

base 7; printf '{"date": "2026-09-19", "passed": 7, "failed": 3}\n' > "$tmp/v-old.json"; RITUAL_VERIFY_MARKER="$tmp/v-old.json"
run "verify marker 12 days old -> flagged" 'verify.sh: last run 2026-09-19, 12 days ago'
base 8; printf '{"date": "2026-09-30"}\n' > "$tmp/v-new.json"; RITUAL_VERIFY_MARKER="$tmp/v-new.json"; run "verify marker fresh -> silent" empty
base 9; : > "$tmp/v-mtime.json"; touch -d 2026-09-01 "$tmp/v-mtime.json"; RITUAL_VERIFY_MARKER="$tmp/v-mtime.json"
run "verify marker without date field falls back to mtime" 'verify.sh: last run 2026-09-01, 30 days ago'

base 10; RITUAL_NODE_VERSION=v20.19.0; run "node 20 past EOL -> flagged" 'node: v20.19.0 is past end-of-life \(2026-04-30\)'
base 11; RITUAL_NODE_VERSION=v25.1.0; run "node odd major -> flagged unknown" 'node: v25.1.0 is not in'
base 12; RITUAL_NODE_VERSION=v22.3.0; run "node 22 supported -> silent" empty

base 13; RITUAL_INFRA93_TARGET=2026-09-20; run "INFRA-93 target passed -> flagged" 'gitea \(INFRA-93\): monthly update check was due 2026-09-20, 11 days ago'
base 14; RITUAL_INFRA93_TARGET=2026-10-01; run "INFRA-93 due today -> silent" empty
base 15; RITUAL_INFRA93_TARGET=none; run "INFRA-93 unknown -> silent" empty

# Several at once: one header, one line each
base 16; RITUAL_STATE_DIR=$(fixture multi 2026-09-01); RITUAL_NODE_VERSION=v20.1.0; RITUAL_INFRA93_TARGET=2026-09-01
out=$(bash "$check"); lines=$(grep -c '^  - ' <<<"$out"); hdr=$(grep -c '^Rituals overdue:$' <<<"$out")
if [ "$lines" -eq 3 ] && [ "$hdr" -eq 1 ]; then echo "PASS three overdue -> one header, three lines"; pass=$((pass+1))
else echo "FAIL three overdue: header=$hdr lines=$lines: $out"; fail=$((fail+1)); fi

echo "passed=$pass failed=$fail"
[ $((pass + fail)) -gt 0 ] || { echo "FAIL no cases ran"; exit 1; }
[ "$fail" -eq 0 ]
