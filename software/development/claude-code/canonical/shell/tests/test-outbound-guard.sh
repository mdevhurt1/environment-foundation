#!/usr/bin/env bash
# Description: Regression tests for cc-outbound-guard.sh. Each fixture holds one
# Bash command; its extension says the expected verdict (.allow -> exit 0,
# .block -> exit 2). Fixtures are files, not inline strings, so this script's
# own command line carries no client text for a live guard to trip on.
#
# The guard reads its internal allowlist from $HOME/.config/agents/env
# (AI_ST-133), so every run gets a throwaway HOME and the verdicts never depend
# on this machine's real list:
#   fixtures/*        an env file with the TEST list below
#   fixtures/unset/*  twice: no env file at all, then a key holding only
#                     malformed entries. Both must fail closed to loopback.
# The test list uses RFC 5737/2544 documentation ranges, never a real LAN.
#
# Usage: bash tests/test-outbound-guard.sh   (from canonical/shell or anywhere)
# Dependencies: bash 4+, jq

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
guard="$here/../cc-outbound-guard.sh"
pass=0 fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Entries `*`, `.*`, `a|[^@]+` (regex injection) and `evil..example` are junk the guard must drop, not obey;
# fixture c (a public post) proves that by still blocking.
TEST_LIST="export AGENTS_INTERNAL_HOSTS='plane.homelab,git-docs.homelab 192.0.2.* 198.18.* * .* a|[^@]+ evil..example'"
JUNK_LIST="export AGENTS_INTERNAL_HOSTS='* .* a|[^@]+ 192.0.*.1 evil..example http://x'"

mkhome() {  # mkhome <name> [env-line]: a HOME with that env file, or none
    mkdir -p "$tmp/$1/.config/agents"
    [ -n "${2-}" ] && printf 'export OTHER=1\n%s\n' "$2" > "$tmp/$1/.config/agents/env"
    printf '%s' "$tmp/$1"
}

run() {  # run <home> <label> <fixture...>
    local home=$1 label=$2 f want got payload; shift 2
    for f in "$@"; do
        [ -e "$f" ] || continue
        want=0; [ "${f##*.}" = block ] && want=2
        payload=$(jq -n --rawfile c "$f" '{tool_name:"Bash", tool_input:{command:($c|rtrimstr("\n"))}}')
        HOME="$home" bash "$guard" <<<"$payload" >/dev/null 2>&1
        got=$?
        if [ "$got" -eq "$want" ]; then
            pass=$((pass + 1)); echo "PASS $label $(basename "$f") (exit $got)"
        else
            fail=$((fail + 1)); echo "FAIL $label $(basename "$f") (want $want, got $got)"
        fi
    done
}

run "$(mkhome set "$TEST_LIST")" set "$here"/fixtures/*.allow "$here"/fixtures/*.block
run "$(mkhome none)" no-env "$here"/fixtures/unset/*.allow "$here"/fixtures/unset/*.block
run "$(mkhome junk "$JUNK_LIST")" junk-env "$here"/fixtures/unset/*.allow "$here"/fixtures/unset/*.block

echo "passed=$pass failed=$fail"
# Zero fixtures run is a check that cannot fail, not a pass.
[ $((pass + fail)) -gt 0 ] || { echo "FAIL no fixtures found in $here/fixtures"; exit 1; }
[ "$fail" -eq 0 ]
