#!/usr/bin/env bash
# Description: Regression tests for cc-outbound-guard.sh. Each fixture holds one
# Bash command; its extension says the expected verdict (.allow -> exit 0,
# .block -> exit 2). Fixtures are files, not inline strings, so this script's
# own command line carries no client text for a live guard to trip on.
#
# Usage: bash tests/test-outbound-guard.sh   (from canonical/shell or anywhere)
# Dependencies: bash 4+, jq

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
guard="$here/../cc-outbound-guard.sh"
pass=0 fail=0

for f in "$here"/fixtures/*.allow "$here"/fixtures/*.block; do
    [ -e "$f" ] || continue
    want=0; [ "${f##*.}" = block ] && want=2
    payload=$(jq -n --rawfile c "$f" '{tool_name:"Bash", tool_input:{command:($c|rtrimstr("\n"))}}')
    bash "$guard" <<<"$payload" >/dev/null 2>&1
    got=$?
    if [ "$got" -eq "$want" ]; then
        pass=$((pass + 1)); echo "PASS $(basename "$f") (exit $got)"
    else
        fail=$((fail + 1)); echo "FAIL $(basename "$f") (want $want, got $got)"
    fi
done

echo "passed=$pass failed=$fail"
# Zero fixtures run is a check that cannot fail, not a pass.
[ $((pass + fail)) -gt 0 ] || { echo "FAIL no fixtures found in $here/fixtures"; exit 1; }
[ "$fail" -eq 0 ]
