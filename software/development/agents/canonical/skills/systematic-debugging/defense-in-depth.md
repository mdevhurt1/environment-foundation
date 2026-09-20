# Defense-in-Depth Validation

You fixed the bug at its source. One check, at the right place, feels
sufficient. It is not: a single check is bypassed by a different code path, by
a refactor, by a test double, or by the next caller who did not know it
existed.

**Core principle:** validate at every layer the data passes through. Make the
bug structurally impossible, not merely absent.

Single validation says "we fixed the bug." Multiple layers say "the bug cannot
be produced."

## The four layers

### Layer 1 — entry-point validation

Reject obviously invalid input at the boundary, with a message that names the
value:

```bash
[ $# -eq 1 ] || { echo "usage: sdd-workspace PLAN_FILE" >&2; exit 2; }
plan=$1
[ -f "$plan" ] || { echo "no such plan file: $plan" >&2; exit 2; }

slug=$(basename "$plan" .md)
[ -n "$slug" ] && [ "$slug" != "." ] && [ "$slug" != ".." ] \
  || { echo "cannot derive a workspace name from: $plan" >&2; exit 2; }
```

Note the third check. `basename` can return `.` or `..`, and a directory named
`..` under the repo root is a different kind of bad day. Entry validation earns
its keep on the inputs nobody would type on purpose.

### Layer 2 — operation validation

Ensure the values make sense for *this* operation, even though a caller
already checked them:

```bash
git rev-parse --verify --quiet "$base" >/dev/null || { echo "bad BASE: $base" >&2; exit 2; }
git rev-parse --verify --quiet "$head" >/dev/null || { echo "bad HEAD: $head" >&2; exit 2; }
```

### Layer 3 — environment guards

Refuse dangerous operations in contexts where they cannot be right. This is
the layer that stops a test run from writing outside its sandbox, or a helper
from acting on the wrong session:

```bash
# refuse to act on a slot that is not the one this worktree belongs to
worktree_session=$(grep '^session_id=' "$worktree/.cc-mode" | cut -d= -f2-)
[ "$worktree_session" = "$slot_session" ] || {
    echo "refusing: worktree .cc-mode names $worktree_session, slot is $slot_session" >&2
    exit 1
}
```

That is the shape of `cc-reclaim-window.sh`'s C4 condition, and it exists
because resolving a slot **by task_id alone** once picked up an abandoned
session from earlier the same day. Worktrees are reused; a stale `.cc-mode`
points at the wrong session.

### Layer 4 — ordering and re-read, where state can change under you

The layer most often missing. When a check and the action it authorizes are
separated by other work, the check is stale by the time the action runs.

`cc-reclaim-window.sh` again, as the reference implementation:

- all four conditions and the `tmux kill-window` happen **in one process**
- the volatile condition (slot status) is evaluated **last**, after the
  durable ones
- it is then **re-read immediately before the kill**, with nothing between the
  read and the comparison; a change aborts and exits 4
- it is read from the slot's own status line, never from a completion event
  and never from an earlier scan

On 2026-08-15 a window was killed with its slot still reading `running`. All
four conditions had been checked — correctly — but across *two command
batches*, and the re-check was skipped in the batch that did the kill. The
child was mid-close-out and its memory delta was lost.

**You cannot recreate a Layer 4 guarantee by running the checks yourself
across several tool calls.** If atomicity matters, it has to live in one
process — that is why these are scripts and not checklists.

### Layer 5 (optional) — forensic instrumentation

When the layers above fail, you want to know what they saw. Log to stderr,
before the operation, with the values in scope. See `root-cause-tracing.md`.

## Applying the pattern

1. **Trace the data flow.** Where does the bad value originate? Where is it
   used?
2. **Map every checkpoint** it passes through.
3. **Add validation at each layer** — entry, operation, environment, ordering.
4. **Test each layer independently.** Bypass Layer 1 in a test and verify
   Layer 2 catches it. A layer you have never watched fire is not a layer.

That last point is the whole discipline. `cc-reclaim-window.sh` ships with
`cc-reclaim-exercise.sh`, whose eight cases are the all-pass path, **each of
the four conditions failing independently**, the worktree-reuse decoy, the
numeric-task_id index trap, and the gate/kill race. Every case corresponds to
a layer, and every layer has been watched fire.

## When not to

Defense in depth is for values that cross boundaries and for operations that
destroy things. It is not a licence to wrap every function in argument checks:
a guard nobody can trigger is dead code that still has to be read and
maintained. If you cannot write the test that fires it, you do not need it
yet.

## Key insight

Different layers catch different cases: entry validation catches most bugs,
operation checks catch edge cases, environment guards catch context-specific
danger, ordering catches races, and instrumentation catches whatever is left.

**Do not stop at one validation point** — but do be able to say, for each one,
which failure it caught.
