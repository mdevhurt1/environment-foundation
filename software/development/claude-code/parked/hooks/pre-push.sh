#!/usr/bin/env bash
# Description: git pre-push hook — runs the cc-scrub F1 arm over each outgoing commit range (including its commit messages) and refuses the push on any verdict that is not clean. Deployed by the module's configure.sh as a symlink at <repo>/.git/hooks/pre-push.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, git, cc-scrub.sh (canonical/scripts/)
#
# WHY A SECOND GATE, WHEN pre-commit ALREADY RAN
#
#   The two hooks sweep different corpora and neither contains the other.
#   pre-commit sees the index and nothing else; it cannot see a COMMIT
#   MESSAGE, because the message does not exist yet when it runs. Measured
#   on this repository, an earlier hand scrub removed a LAN address from
#   the tracked files and then quoted it four times in its own commit
#   message. Push is also the moment the boundary is actually crossed: a
#   local commit discloses nothing, and history rewritten before a push is
#   free. This is the last gate that is still cheap.
#
# THE INTERFACE
#
#   git feeds one line per ref on stdin:
#       <local ref> <local sha> <remote ref> <remote sha>
#   The corpus is <remote sha>..<local sha> -- the commits this push would
#   publish, which is not the same as the working tree and not the same as
#   the branch's whole history.

set -uo pipefail   # Gate, NOT -e: an abort mid-check must not be mistaken
                   # for a pass. Every exit below is explicit.

HOOK_NAME="pre-push"

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

have_commit() { git rev-parse -q --verify "$1^{commit}" >/dev/null 2>&1; }

# published_baseline <local-sha> -- a ref that is already published, to
# bound a push that creates a NEW remote ref (remote sha is all zeros, so
# there is no far side to diff against).
#
# It must not be the tip being pushed: `main..main` is empty, and an empty
# corpus reported CLEAN is the false zero this toolchain refuses. Returning
# nothing is therefore a refusal upstream, not a fallback to "sweep less".
published_baseline() {
    local tip="$1" cand
    for cand in origin/main origin/master main master; do
        if have_commit "$cand" && [ "$(git rev-parse "$cand")" != "$tip" ]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    return 1
}

FAILED=0
CHECKED=0

# Read to EOF. `while read` on a plain stdin has no producer to SIGPIPE,
# and every ref must be swept even after one of them has already failed --
# an operator who fixes the first refusal should not discover the second on
# the next attempt.
while read -r local_ref local_sha remote_ref remote_sha; do
    [ -n "${local_ref:-}" ] || continue

    # A deletion publishes no content. Scanning it is meaningless and
    # refusing it would be a false positive on an ordinary cleanup.
    if cc_hook_is_zero "${local_sha:-}"; then
        continue
    fi

    if cc_hook_is_zero "${remote_sha:-}" || ! have_commit "${remote_sha:-}"; then
        base=$(published_baseline "$local_sha") || {
            printf '\n' >&2
            printf 'cc-scrub %s: REFUSED -- cannot bound the outgoing range for %s\n' \
                "$HOOK_NAME" "${remote_ref:-$local_ref}" >&2
            printf '\n' >&2
            printf '  This push creates a new remote ref and no published baseline\n' >&2
            printf '  (origin/main, origin/master, main, master) resolves to anything\n' >&2
            printf '  other than the tip being pushed, so there is no range to sweep.\n' >&2
            printf '  An unbounded corpus cannot be certified clean.\n' >&2
            printf '\n' >&2
            printf '  Sweep it deliberately instead:  bash cc-scrub.sh --audit\n' >&2
            cc_hook_escape_hatch "$HOOK_NAME" >&2
            FAILED=1
            continue
        }
    else
        base="$remote_sha"
    fi

    CHECKED=$((CHECKED + 1))
    OUT=$(bash "$SCRUB" --range "$base..$local_sha" 2>&1); RC=$?

    if [ "$RC" -eq 0 ]; then
        printf '%s\n' "$OUT" | awk -v r="${remote_ref:-$local_ref}" \
            '/^(corpus|VERDICT)/ { print "cc-scrub pre-push [" r "]: " $0 }'
        continue
    fi

    printf '\ncc-scrub %s: %s -> %s\n' "$HOOK_NAME" "$local_ref" "${remote_ref:-?}" >&2
    cc_hook_report "$HOOK_NAME" "$RC" "$OUT"
    FAILED=1
done

# Nothing to publish (a deletion-only push, or no refs at all) is not a
# failure. CHECKED stays 0 and the push proceeds.
[ "$FAILED" -eq 0 ] || exit 1
exit 0
