# Root Cause Tracing

Bugs surface deep in a call chain — a file written to the wrong directory, a
hook that produces nothing, a marker that never advances. The instinct is to
fix where the error appears. That is treating a symptom.

**Core principle:** trace backward through the chain until you find the
original trigger, then fix at the source.

## When to use

- the error happens deep in execution, not at the entry point
- the stack trace or the call chain is long
- it is unclear where an invalid value originated
- you need to know which test or which caller triggers the problem

If you can trace backward, do. If the chain genuinely dead-ends, fix at the
symptom point **and** add defense-in-depth so the class cannot recur.

## The tracing process

### 1. Observe the symptom

State it as an observation, not a diagnosis.

```
Every session starts without the skills mandate injected.
No error. The hook exits 0.
```

### 2. Find the immediate cause

What code directly produces this?

```bash
[ -r "$SKILL_MD" ] || exit 0     # the guard that swallows it
```

### 3. Ask what set the value

```
SKILL_MD=$(dirname "$BASH_SOURCE")/../skills/using-superpowers/SKILL.md
  ← BASH_SOURCE is ~/.claude/cc-skills-inject.sh (the DEPLOYED symlink)
  ← so "../skills" resolves to ~/skills, which does not exist
  ← the guard is reached, and it exits 0 by design
```

### 4. Keep tracing up

Why is the script running through a symlink at all? Because `configure.sh`
symlinks `~/.claude/*` at whichever clone it was run from. That is not a bug —
it is the deployment model — which means **the script, not the deployment, has
to resolve robustly.**

### 5. Fix at the source

```bash
SKILL_MD="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/using-superpowers/SKILL.md"
```

Root cause: a path derived relative to `$BASH_SOURCE` in a file that is always
invoked through a symlink. Not "the skill file was missing."

**The general shape:** in this repo, tooling that runs from a worktree must
match canonical paths **by suffix or through `$CLAUDE_CONFIG_DIR`**, never
against its own `REPO_ROOT` — `~/.claude/*` points at whichever clone ran
`configure.sh`, normally the main worktree
(`reference_claude_dotfile_symlinks_target_main_worktree`).

## A second worked chain: the read marker that never advanced

| Level | Question | Answer |
|---|---|---|
| Symptom | parent never surfaces a child's events | `events-scan.sh` prints "no unread events" |
| Immediate cause | the marker comparison | leading filename number ≤ `.read-up-to` |
| One level up | what numbers are in the dir? | **both** `NNNN-` and `<epoch>-` names |
| One level up | who writes which? | `cc-tree-slot-write.sh` wrote sequential; dispatched children wrote epochs |
| Source | the naming contract | there wasn't one |

Fix at the source (AI_ST-74): one helper stamps every event, naming it
`max(epoch-now, highest-leading-number + 1)`, so the leading number strictly
increases regardless of which naming era the directory carries. The
marker logic becomes correct by construction rather than by convention.

**Note what the fix was not.** It was not "bump the marker back", which
addresses one directory, and not "rename the old files", which addresses one
day. Fixing at the source means the invalid state can no longer be produced.

## Adding instrumentation when you cannot trace by reading

Log **before** the dangerous operation, not after it fails, and include the
values you are about to act on:

```bash
printf '[trace] %s: dir=%q cwd=%q config=%q\n' \
  "${FUNCNAME[0]:-main}" "$dir" "$PWD" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" >&2
```

Write to **stderr**, not a log file that a caller may be suppressing, and not
stdout — in this codebase stdout is frequently the helper's actual return
value, and a debug line there corrupts the caller.

For a call chain, capture the shell's own stack:

```bash
for i in "${!BASH_SOURCE[@]}"; do
  printf '[trace]   #%d %s:%s in %s\n' "$i" "${BASH_SOURCE[$i]}" "${BASH_LINENO[$i-1]:-?}" "${FUNCNAME[$i]:-main}" >&2
done
```

Then run once and read the evidence:

```bash
bash tests/run-tests.sh 2>&1 | grep '^\[trace\]'
```

### Two shell traps that hide the evidence itself

- **`set -o pipefail` collapses which stage failed.** `$?` is the rightmost
  non-zero status, so it cannot distinguish a legitimate no-match from a real
  error. Read `PIPESTATUS`
  (`reference_bash_pipefail_hides_which_stage_failed`).
- **`producer | sort -rn | head -1` starts SIGPIPE-aborting at roughly 400
  lines of producer output**, not at the 64 KiB pipe buffer — the bar is the
  consumer's single read block. Under `errexit` that is a silent exit 141 with
  zero output, which reads exactly like "no results"
  (`reference_sort_head_sigpipe_fires_at_the_read_block`).

If your instrumentation prints nothing, suspect the instrument before you
conclude the code path was not taken.

## Finding which test causes pollution

When state appears during a suite but you do not know which test creates it,
bisect with `find-polluter.sh` in this directory:

```bash
./find-polluter.sh '/tmp/some-leftover-dir' 'tests/test_*.sh'
```

It runs test files one at a time and stops at the first one that produces the
named path. Set `POLLUTER_TEST_CMD` if your suite is not run per-file with
`bash <file>`.

## Key principle

Found the immediate cause → can you trace one level up? → yes: trace → is this
the source? → no: keep tracing → yes: **fix at the source**, then add
validation at each layer so the bug becomes impossible.

**NEVER fix just where the error appears.**
