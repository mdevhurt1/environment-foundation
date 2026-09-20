#!/usr/bin/env bash
# Description: Zero-dependency TAP assertion harness for the claude-code shell tests. Sourced by each tests/test_*.sh; never executed directly.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, coreutils (mktemp)
#
# WHY A HAND-ROLLED HARNESS AND NOT bats
# --------------------------------------
# bats-core is the obvious candidate and was the first choice. It was rejected
# on the criterion that matters most for a machine-setup repo: a test suite
# nobody can run is worth nothing.
#
#   * bats is NOT installed on this machine (`apt-cache policy bats` reports
#     Installed: (none)), so the suite could not have been executed on the
#     machine it was written for without first `sudo apt install bats`.
#   * Vendoring bats-core would add the repo's FIRST git submodule, and a
#     clone-time network fetch, to a repository whose entire purpose is
#     bootstrapping a machine from nothing.
#   * The repo already HAS a testing idiom: scripts/verify.sh and
#     scripts/doctor.sh both use a `check "<label>" <cmd...>` helper plus a
#     failure counter under `set -uo pipefail`. This harness is that idiom with
#     TAP output bolted on, so there is one convention across 4,347 lines of
#     shell rather than two.
#
# The output is TAP version 13, which every CI runner already understands, so
# choosing bash over bats costs no machine-readability.
#
# Reporters do not use `set -e`: every assertion must run and report. Test
# files are expected to declare `set -uo pipefail`, matching the module
# contract's reporter exemption (docs/module-contract.md).

T_COUNT=0
T_FAIL=0
T_TMPDIRS=()

# Emitted before assertion 1 by t_begin; harmless if a file forgets.
t_begin() {
    printf 'TAP version 13\n'
    printf '# %s\n' "$1"
}

t_pass() {
    T_COUNT=$((T_COUNT + 1))
    printf 'ok %d - %s\n' "$T_COUNT" "$1"
}

# t_fail <description> [diagnostic lines...]
t_fail() {
    local desc="$1"; shift
    T_COUNT=$((T_COUNT + 1))
    T_FAIL=$((T_FAIL + 1))
    printf 'not ok %d - %s\n' "$T_COUNT" "$desc"
    local line
    for line in "$@"; do
        # TAP diagnostics are '#'-prefixed; a value may itself be multi-line.
        printf '%s\n' "$line" | while IFS= read -r l; do printf '#   %s\n' "$l"; done
    done
}

# t_diag <lines...> -- unconditional comment output, not an assertion.
t_diag() { local l; for l in "$@"; do printf '# %s\n' "$l"; done; }

# --- assertions ----------------------------------------------------------

# assert_eq <description> <expected> <actual>
# Values are compared byte-for-byte. Tabs and newlines are rendered visibly in
# the diagnostic, because the two round-trip bugs this suite exists to catch
# both hinge on whitespace that is invisible in a naive diff.
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        t_pass "$desc"
    else
        t_fail "$desc" \
            "expected: $(t_render "$expected")" \
            "actual:   $(t_render "$actual")"
    fi
}

# assert_ne <description> <not-expected> <actual>
assert_ne() {
    local desc="$1" unexpected="$2" actual="$3"
    if [ "$unexpected" != "$actual" ]; then
        t_pass "$desc"
    else
        t_fail "$desc" "value should have differed from: $(t_render "$actual")"
    fi
}

# assert_contains <description> <needle> <haystack>
assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) t_pass "$desc" ;;
        *) t_fail "$desc" "needle:   $(t_render "$needle")" \
                          "haystack: $(t_render "$haystack")" ;;
    esac
}

# assert_not_contains <description> <needle> <haystack>
assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) t_fail "$desc" "unexpectedly found: $(t_render "$needle")" \
                                    "in: $(t_render "$haystack")" ;;
        *) t_pass "$desc" ;;
    esac
}

# assert_rc <description> <expected-rc> <command...>
assert_rc() {
    local desc="$1" want="$2"; shift 2
    t_run "$@"
    if [ "$T_RC" = "$want" ]; then
        t_pass "$desc"
    else
        t_fail "$desc" "expected rc: $want" "actual rc:   $T_RC" \
                       "stderr: $(t_render "$T_ERR")"
    fi
}

# Render a value with tabs/CRs made visible and a marker for the empty string,
# so "" and " " and "\t" are distinguishable in a failure diagnostic.
t_render() {
    if [ -z "$1" ]; then printf '<empty>'; return; fi
    printf '%s' "$1" | sed -e 's/\t/<TAB>/g' -e 's/\r/<CR>/g'
}

# --- running code under test ---------------------------------------------

# t_run <command...> -- sets T_OUT (stdout), T_ERR (stderr), T_RC.
# stdout and stderr are captured SEPARATELY: every helper under test logs
# human prose to stderr and returns its value on stdout, and a harness that
# merged them would pass on a function that printed its answer to the wrong
# stream.
# shellcheck disable=SC2034  # T_OUT/T_ERR/T_RC are read by the sourcing test file.
t_run() {
    local errfile
    errfile=$(mktemp)
    T_OUT=$("$@" 2>"$errfile")
    T_RC=$?
    T_ERR=$(cat "$errfile")
    rm -f "$errfile"
    return 0
}

# t_tmpdir -- print a fresh temp dir, removed by t_finish.
#
# mktemp -d lands under $TMPDIR (normally /tmp), which is deliberate: the
# .cc-mode helpers walk UPWARD from cwd, so a scratch dir created inside this
# repository would find the worktree's own .cc-mode and silently test the
# wrong file. t_tmpdir asserts no ancestor .cc-mode exists before handing the
# directory back.
t_tmpdir() {
    local d probe
    d=$(mktemp -d)
    probe=$(dirname "$d")
    while [ "$probe" != "/" ] && [ -n "$probe" ]; do
        if [ -f "$probe/.cc-mode" ]; then
            printf 'harness: refusing to use %s -- ancestor %s/.cc-mode would shadow the fixture\n' \
                "$d" "$probe" >&2
            rm -rf "$d"
            return 1
        fi
        probe=$(dirname "$probe")
    done
    T_TMPDIRS+=("$d")
    printf '%s\n' "$d"
}

# t_sandbox_env -- neutralise every ambient input the helpers under test read.
#
# __cc_model_policy_path falls back to $HOME/.claude/model-policy.json and then
# to the repo copy beside $HOME/.claude/cc-functions.sh. Both are REAL on a
# configured machine, so without an overridden HOME the "no policy found"
# refusal path is untestable -- it would silently resolve against the
# operator's live policy and pass for the wrong reason.
t_sandbox_env() {
    unset CC_MODEL CC_MODEL_POLICY CC_PERM_MODE
    HOME=$(t_tmpdir) || return 1
    export HOME
}

# --- finish ---------------------------------------------------------------

t_finish() {
    printf '1..%d\n' "$T_COUNT"
    local d
    for d in "${T_TMPDIRS[@]+"${T_TMPDIRS[@]}"}"; do
        [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
    done
    [ "$T_FAIL" -eq 0 ] || return 1
    return 0
}

# t_minimal_path <cmd>... -- build a bin dir holding ONLY the named commands
# (symlinked from their real locations) and print its path.
#
# Used to prove the "jq is not installed" branches. Removing jq from PATH by
# hand is not possible any other way: a non-executable shim named jq is simply
# skipped by the PATH search and the real jq is found anyway, so the branch
# would never be entered and the test would pass for the wrong reason.
t_minimal_path() {
    local d cmd real
    d=$(t_tmpdir) || return 1
    mkdir -p "$d/bin"
    for cmd in "$@"; do
        real=$(command -v "$cmd" 2>/dev/null) || continue
        ln -sf "$real" "$d/bin/$cmd"
    done
    printf '%s\n' "$d/bin"
}
