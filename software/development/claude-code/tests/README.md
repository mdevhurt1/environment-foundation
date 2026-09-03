# Tests — claude-code shell tooling

    bash tests/run-tests.sh          # the suite
    bash tests/mutate.sh             # proof the suite bites
    bash tests/run-tests.sh -v resolve_model    # one file, raw output

Exit status is 0 only if every assertion passed. Output is TAP version 13, so
any CI runner can consume it without a plugin.

## Why these four functions

`software/development/claude-code/` was ~1,892 lines of shell with no test of
any kind. It mints session IDs, writes `.cc-mode`, resolves model and
permission policy, registers folder trust and drives tmux. The recurring defect
tail — the `^_[^_]` snapshot filter dropping `_cc_*` helpers, tree-slot helpers
resolving from cwd instead of an argument, `configure.sh` exiting 1 on a clean
run, `cc-branch` basing children on main, the sandbox bypass defeating prompt
mode — was found one item at a time, by a live session hitting it mid-task.

Coverage is not the goal. The targets are the functions whose failures are
**silent** rather than loud, because those are the ones a live session cannot
report:

| Target | Silent failure it has |
|---|---|
| `__cc_resolve_model` | A wrong model is not an error. It is a worse session and a larger bill. Claude Code's "Default" is a *moving referent*, so falling through to it reassigns sessions with no diff and no output. |
| `__cc_resolve_perm` | Its fall-through line is a bare tab plus a source name. Lose the tab and the *value* becomes `settings-default`, which `claude` rejects — every launch dies. Gain a policy entry and the wrapper silently out-votes `settings.json permissions.defaultMode`. |
| `__cc_write_mode_file` | `.cc-mode` is **sourced** by `statusline-command.sh:37`. A value containing a space, a quote or a `$(…)` is a shell bug in a file nobody reads. |
| `__cc_read_mode` | Walks upward from cwd. Stop the walk and a session simply stops knowing what it is. |

## Why a hand-rolled harness and not bats

bats-core was the first choice and was rejected on the criterion that matters
most here: **a test suite nobody can run is worth nothing.**

- bats is not installed on this machine (`apt-cache policy bats` → `Installed:
  (none)`), so the suite could not have been run on the machine it was written
  for without first installing a package.
- Vendoring bats-core would add this repository's *first* git submodule, and a
  clone-time network fetch, to a repo whose entire purpose is bootstrapping a
  machine from nothing.
- The repo already has a testing idiom: `scripts/verify.sh` and
  `scripts/doctor.sh` both use a `check "<label>" <cmd…>` helper plus a failure
  counter under `set -uo pipefail`. `harness.sh` is that idiom with TAP output
  added, so there is one convention across the module rather than two.

Dependencies are bash 4+, coreutils, `jq` (already a hard dependency of
`configure.sh`), and `python3` for `mutate.sh` only. `shellcheck` is optional —
`test_shellcheck.sh` skips with a note if it is absent.

## Why tests/ lives inside the module

`docs/module-contract.md` requires `README.md` and `scripts/{install,verify,
uninstall}.sh` per module, and the repo-root linter only inspects
`<module>/scripts/*.sh`. A `tests/` sibling is therefore unconstrained, and
module-local keeps the contract's locality: everything a module needs travels
with the module. There is no repo-root `tests/` to join.

`scripts/verify.sh` (does the *install* work on this machine?) and
`scripts/doctor.sh` (does this *checkout* match what is deployed?) both need a
configured machine. These tests need neither — they run against the checkout
alone, which is what makes them CI-able.

## Files

| File | What it is |
|---|---|
| `run-tests.sh` | Runner. One process per test file, one flat TAP stream out. |
| `harness.sh` | Sourced assertion library. Not executable — it is not an entry point. |
| `test_resolve_model.sh` | `__cc_resolve_model`: env override, policy lookup, `track-latest` pass-through, every refusal path. |
| `test_resolve_perm.sh` | `__cc_resolve_perm`: the settings-default fall-through byte-for-byte, precedence, the deliberate asymmetry with the model resolver. |
| `test_mode_file_roundtrip.sh` | `__cc_write_mode_file` / `__cc_read_mode` against all three real readers of `.cc-mode`. |
| `test_shellcheck.sh` | Static gate at `-S error` over every `*.sh` the module ships. |
| `mutate.sh` | Breaks `cc-functions.sh` eight ways on a throwaway copy and asserts each break is caught. |

## `KNOWN DEFECT` assertions

Some assertions in `test_mode_file_roundtrip.sh` are prefixed `KNOWN DEFECT`.
They **characterise** current behaviour rather than assert correct behaviour —
`mode`, `slug` and `parent_repo` are written unscrubbed, so a value containing a
space, a quote or a command substitution corrupts, truncates or executes when
the statusline sources the file.

They are expected to fail the day the writer is fixed. That is the intended
signal: come back and restate the contract, rather than discovering the change
from a blank statusline. Do not "fix" them by scrubbing spaces — silently
mangling a filesystem path is worse than the symptom. See the INFRA-39 report.

## Adding a test

Copy the header of any `test_*.sh`: resolve `TESTS_DIR`/`MODULE_DIR`/
`REPO_ROOT`, source `harness.sh` and `shared/logging.sh`, call
`require_not_root`, source `$CC_FUNCTIONS_UNDER_TEST`, then `t_begin` … asserts
… `t_finish`. `run-tests.sh` picks up `test_*.sh` automatically. Use
`set -uo pipefail`, never `-e`: a reporter must run every assertion.

When you add a test for a behaviour that matters, add a mutation to
`mutate.sh` that breaks it. An assertion that has never been seen to fail is
decoration.
