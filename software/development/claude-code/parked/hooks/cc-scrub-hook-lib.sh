#!/usr/bin/env bash
# Description: Shared resolution and refusal logic for the cc-scrub git hooks — locates the F1 arm from the hook's own deployed location and prints the refusal banner. Sourced by pre-commit.sh and pre-push.sh; never executed directly.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, git, coreutils (readlink)
#
# WHY A LIBRARY AND NOT TWO COPIES
#
#   The two hooks differ only in which corpus they hand cc-scrub: staged
#   changes, or the range a push would publish. Everything else -- finding
#   the scrubber, deciding what its exit codes mean, and telling the
#   operator what to do about it -- is one policy. Two copies of a policy
#   is one policy and one stale copy, and the stale one is always the gate.

# The all-zero object id git uses for "this ref does not exist". Matched by
# shape rather than by length so a sha256 repository is handled too.
cc_hook_is_zero() {
    case "${1:-}" in
        "") return 0 ;;
        *[!0]*) return 1 ;;
        *) return 0 ;;
    esac
}

# cc_hook_resolve_scrub -- print the path to the F1 arm, or fail.
#
# Resolved from the HOOK's own real path, not from the working tree being
# committed in. The hook is a symlink deployed once, from the checkout that
# ran configure.sh, exactly like every link under ~/.claude -- so the gate
# is one known version in every worktree rather than whatever copy the
# branch under test happens to carry.
#
# A missing scrubber is a hard failure, never a pass. A gate that fails
# open converts "unguarded" into "verified guarded", which is the one
# failure mode a gate may not have.
cc_hook_resolve_scrub() {
    local self here cand
    self=$(readlink -f "$1" 2>/dev/null) || self=""
    if [ -n "$self" ]; then
        here=$(dirname "$self")
        cand="$here/../scripts/cc-scrub.sh"
        if [ -f "$cand" ]; then printf '%s\n' "$cand"; return 0; fi
    fi
    # The deployed user-facing name, for an install whose checkout moved.
    cand="$HOME/.claude/cc-scrub"
    if [ -f "$cand" ]; then printf '%s\n' "$cand"; return 0; fi
    return 1
}

# cc_hook_no_scrubber <hook-name> -- refuse because the instrument is absent.
cc_hook_no_scrubber() {
    printf '\n' >&2
    printf 'cc-scrub %s: REFUSED -- the cc-scrub F1 arm could not be found.\n' "$1" >&2
    printf '\n' >&2
    printf '  Looked beside this hook (canonical/scripts/cc-scrub.sh) and at\n' >&2
    printf '  ~/.claude/cc-scrub. A gate that cannot run must not report clean,\n' >&2
    printf '  so this is a refusal rather than a skip.\n' >&2
    printf '\n' >&2
    printf '  Fix: re-run the module configure.sh from the main checkout.\n' >&2
    cc_hook_escape_hatch "$1" >&2
}

# cc_hook_escape_hatch <hook-name> -- the one documented way past the gate.
#
# There is deliberately NO environment-variable override. git already
# provides --no-verify and cannot be stopped from honouring it, so a second
# bypass would add a quieter one that leaves no trace in the operator's
# shell history. The house rule is that using it is a reportable event.
cc_hook_escape_hatch() {
    local verb="commit"
    [ "$1" = "pre-push" ] && verb="push"
    printf '\n'
    printf '  This gate has no override of its own. git'"'"'s own bypass is\n'
    printf '  `git %s --no-verify`, which skips the sweep entirely -- so a\n' "$verb"
    printf '  %s made that way must say so in the session report.\n' "$verb"
}

# cc_hook_report <hook-name> <rc> <output> -- render a non-clean verdict.
cc_hook_report() {
    local name="$1" rc="$2" out="$3" why
    case "$rc" in
        1) why="blocking finding(s) in the swept corpus" ;;
        2) why="INCOMPLETE -- the sweep could not prove itself, so it cannot report clean" ;;
        3) why="cc-scrub usage error -- the hook called it wrongly, which is a bug in the hook" ;;
        *) why="cc-scrub exited $rc, which this hook does not recognise" ;;
    esac
    printf '\n' >&2
    printf 'cc-scrub %s: REFUSED -- %s\n' "$name" "$why" >&2
    printf '\n' >&2
    printf '%s\n' "$out" >&2
    cc_hook_escape_hatch "$name" >&2
}
