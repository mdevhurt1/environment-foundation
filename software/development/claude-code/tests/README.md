# Tests — claude-code shell tooling

    bash tests/run-tests.sh          # the suite
    bash tests/mutate.sh             # proof the suite bites
    bash tests/run-tests.sh -v resolve_model    # one file, raw output

Exit status is 0 only if every assertion passed. Output is TAP version 13, so
any CI runner can consume it without a plugin.

## Why these functions

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
| `__cc_write_mode_file` | `.cc-mode` used to be **sourced** by `statusline-command.sh`. A value containing a space, a quote or a `$(…)` was a shell bug in a file nobody reads. INFRA-45 gave the file a quoting contract; these tests are what hold it. |
| `__cc_read_mode` | Walks upward from cwd. Stop the walk and a session simply stops knowing what it is. |
| `statusline-command.sh` | The reader that ran that shell bug, once per repaint, in every session. It now parses `.cc-mode` against a key whitelist instead of sourcing it. |

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
| `test_mode_file_roundtrip.sh` | `__cc_write_mode_file` / `__cc_read_mode` against all three real readers of `.cc-mode`, plus the quoting contract (section 9). |
| `test_statusline.sh` | `statusline-command.sh` end to end: badges, model drift, `CTX-WARN`, and a table of **hand-written** hostile `.cc-mode` files the writer-side fix cannot reach. |
| `test_shellcheck.sh` | Static gate at `-S error` over every `*.sh` the module ships. |
| `test_doctor_symlinks.sh` | `doctor.sh` symlink checks judge against the canonical (main-worktree) checkout, so branch and main runs agree (INFRA-47). |
| `test_doctor_push.sh` | `doctor.sh` push-lag check: unpushed commits on main surface as a WARN with count and age (INFRA-50). |
| `test_memory_inject.sh` | `cc-memory-inject.sh`: the SessionStart memory-index injection (AI_ST-69). |
| `test_configure.sh` | `configure.sh` against a scaffold + sandbox HOME: full link set (incl. `cc-plane-sync.sh`, INFRA-46) and exit 0 on a clean idempotent re-run (INFRA-51). |
| `test_plane_sync.sh` | `cc-plane-sync.sh`: usage refusals, identity precedence, the warn-and-exit-0 network contract, and the HTTP flows against a loopback fake Plane. |
| `test_entry_points.sh` | The seven public `cc-*` entry points: refusals that must leave nothing behind, and spawn flows against claude/tmux shims (the half-spawn surface). |
| `mutate.sh` | Breaks the five subjects (`cc-functions.sh`, `statusline-command.sh`, `doctor.sh`, `configure.sh`, `cc-plane-sync.sh`) twenty-four ways on throwaway copies and asserts each break is caught. |

## The `.cc-mode` quoting contract

`test_mode_file_roundtrip.sh` sections 3–6 used to carry assertions prefixed
`KNOWN DEFECT`, which **characterised** the writer's behaviour rather than
asserting correct behaviour, and which said in the file that they were
"expected to fail the day the writer is fixed". INFRA-45 fixed it; they are
restated against the contract, on their original fixtures, so the before/after
is readable in one place.

The contract itself is stated once, in `canonical/shell/cc-functions.sh` above
`__cc_mode_quote`. In brief: a value is written bare iff every character is in
`[A-Za-z0-9_@%+:,./-]`, otherwise single-quoted with `'` escaped as `'\''`;
line breaks are the one thing the format cannot hold and are stripped. The
invariant section 9 enforces is that **sourcing a `.cc-mode` produced by
`__cc_write_mode_file` can never execute anything and can never alter a field
other than the one being assigned** — checked with an execution canary on the
filesystem, not by reading output for an error message.

Two rules for anyone extending this:

- Do not make the encoding unconditional. Six other readers parse `.cc-mode`
  with `grep '^key=' | cut -d= -f2-` and would all need changing in lockstep.
  Section 9d pins the wire format for real values so this cannot happen by
  accident.
- Do not "fix" a hostile value by scrubbing it. Silently mangling a filesystem
  path is worse than the symptom — that was true before the contract and it is
  why the contract quotes rather than deletes.

## Adding a test

Copy the header of any `test_*.sh`: resolve `TESTS_DIR`/`MODULE_DIR`/
`REPO_ROOT`, source `harness.sh` and `shared/logging.sh`, call
`require_not_root`, source `$CC_FUNCTIONS_UNDER_TEST`, then `t_begin` … asserts
… `t_finish`. `run-tests.sh` picks up `test_*.sh` automatically. Use
`set -uo pipefail`, never `-e`: a reporter must run every assertion.

A test file that exercises a script rather than a sourced function should read
its subject from a `*_UNDER_TEST` variable the same way — `test_statusline.sh`
uses `STATUSLINE_UNDER_TEST` — so `mutate.sh` can point it at a mutant.

When you add a test for a behaviour that matters, add a mutation to
`mutate.sh` that breaks it. An assertion that has never been seen to fail is
decoration.
