#!/usr/bin/env bash
# Description: git pre-commit hook — runs the cc-scrub F1 arm over the staged changes and refuses the commit on any verdict that is not clean. Deployed by the module's configure.sh as a symlink at <repo>/.git/hooks/pre-commit.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, git, cc-scrub.sh (canonical/scripts/)
#
# WHY THIS RUNS MECHANICALLY
#
#   cc-scrub was written because a commit bound for a PUBLIC remote carried
#   the live LAN address of an internal server, and it was found by a human
#   reading 1,283 added lines. The tool shipped with a measured pre-commit
#   budget (0.52s over 50 files, calibration included) and was then bound to
#   nothing at all. A scrubber the operator must REMEMBER to run gets run on
#   the days it is not needed and skipped on the day it is: the incident
#   that produced it happened during a session that was already being
#   careful. This hook is the difference between a tool and a control.
#
# WHY EVERY NON-ZERO EXIT BLOCKS
#
#   cc-scrub distinguishes 1 (blocking findings) from 2 (INCOMPLETE -- it
#   could not prove itself, or could not sweep the whole corpus). Only 0 is
#   a clearance. Treating INCOMPLETE as "probably fine" is precisely the
#   false-zero this tool exists to refuse: an unmeasured corpus reported as
#   a clean one.

set -uo pipefail   # Gate, NOT -e: an abort mid-check must not be mistaken
                   # for a pass. Every exit below is explicit.

HOOK_NAME="pre-commit"

LIB="$(dirname "$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")")/cc-scrub-hook-lib.sh"
if [ ! -f "$LIB" ]; then
    printf '\ncc-scrub %s: REFUSED -- hook library missing at %s\n' "$HOOK_NAME" "$LIB" >&2
    exit 1
fi
# shellcheck source=./cc-scrub-hook-lib.sh
# shellcheck disable=SC1090,SC1091
source "$LIB"

SCRUB=$(cc_hook_resolve_scrub "$0") || {
    cc_hook_no_scrubber "$HOOK_NAME"
    exit 1
}

# An empty index is not a corpus. `git commit` with nothing staged fails on
# its own terms straight after this, and sweeping nothing would print a
# CLEAN verdict over a corpus of zero files -- the exact shape of report
# this toolchain refuses to emit.
if git diff --cached --quiet 2>/dev/null; then
    exit 0
fi

OUT=$(bash "$SCRUB" --staged 2>&1); RC=$?

if [ "$RC" -eq 0 ]; then
    # Corpus honesty on the happy path too: a one-line clearance that says
    # what was actually swept, so a CLEAN over an empty sweep is visible
    # rather than reassuring. awk reads to EOF -- a head/grep -q here would
    # SIGPIPE its producer once the output outgrew one read block.
    printf '%s\n' "$OUT" | awk '/^(corpus|VERDICT)/ { print "cc-scrub pre-commit: " $0 }'
    exit 0
fi

cc_hook_report "$HOOK_NAME" "$RC" "$OUT"
exit 1
