# Condition-Based Waiting

Flaky tests and flaky orchestration both come from the same move: guessing how
long something takes instead of watching for the thing itself. A guess passes
on an idle machine and fails under load, in CI, or on a box where an earlier
probe is still burning a core.

**Core principle:** wait for the actual condition you care about, and pin the
condition to the thing you are waiting on — not to a proxy that something else
can also produce.

## When to use

- a test or script contains `sleep`, `time.sleep()`, or a fixed timeout
- a test passes alone and fails in the full suite, or fails only under load
- you are waiting for a process, a file, a service, or a child session
- a wait "succeeded" but the thing it waited for had not finished

**Don't use when** you are testing timing behavior itself (a debounce, a
retry backoff, a rate limit). Then the delay *is* the subject — and you write
down why the number is what it is.

## The failure this exists to prevent

On 2026-08-08 a background waiter polled a multi-package `colcon test` log
with:

```bash
grep -qE "tests passed|tests failed"     # ❌ proxy, not the thing
```

It matched **package 2 of 3's** summary line and exited early. `colcon
test-result` then ran mid-flight and reported "did not generate a result file"
for tests that went on to pass. It was reported as a failure. It was not one.

The log string was an artifact that an *earlier stage* could also emit. The
condition that actually mattered was "the test process is gone":

```bash
until ! pgrep -f "colcon test" >/dev/null; do sleep 1; done   # ✅ the thing itself
```

## Core patterns

Wrap the polling once and reuse it:

```bash
# wait_for <timeout-seconds> <description> <command...>
wait_for() {
    local timeout=$1 desc=$2; shift 2
    local deadline=$(( SECONDS + timeout ))
    until "$@"; do
        [ "$SECONDS" -lt "$deadline" ] || {
            echo "timed out after ${timeout}s waiting for: ${desc}" >&2
            return 1
        }
        sleep 0.2
    done
}
```

| Waiting for | Condition |
|---|---|
| a process to finish | `wait_for 300 "suite exit" bash -c '! pgrep -f "run-tests.sh"'` |
| a file to appear | `wait_for 30 "report" test -s "$report"` |
| a port to accept | `wait_for 60 "plane" nc -z plane.homelab 80` |
| a service to be healthy | `wait_for 120 "api" curl -fsS -m 5 "$url/health"` |
| a count to be reached | `wait_for 60 "5 events" bash -c '[ "$(ls "$d" | wc -l)" -ge 5 ]'` |
| a child session's progress | `wait_for 600 "a commit" bash -c '[ "$(git -C "$wt" rev-list --count main..HEAD)" -gt 0 ]'` |

Three rules the table encodes:

1. **Every wait has a timeout, and the timeout message names what was
   awaited.** A hang that says "timed out" and nothing else costs the next
   debugging session an hour.
2. **A failed wait is a failure, not a fall-through.** Return non-zero; do not
   let the caller proceed as if the condition held.
3. **Poll the thing, not its shadow.** Process exit over log text; file size
   over file existence; a fetched value over a status string somebody else
   writes.

## What is not a condition

**A pane is not a condition.** A wedged Claude TUI and a healthy idle one are
indistinguishable in `capture-pane`, and the statusline context % goes stale
too. Two Sentinel branches burned roughly 8.6 session-hours looking perfectly
healthy. Check progress on the **filesystem** — task-folder mtime, and
`git rev-list --count main..HEAD` — never the pane
(`feedback_verify_branch_liveness_by_filesystem`).

The pane is still useful for the opposite question: it is a *positive*
detector for a blocking artefact an idle-but-healthy session would not render
— a trust dialog, a numbered menu, `Unknown command: /end`. **Presence of a
pane signal is informative; absence is not.**

**A dead session is not a dead process.** `tmux kill-session` kills the
session, not what is running inside it. One leftover probe ran at 100% CPU for
26 minutes after its session was "cleaned up". Kill by pattern
(`pkill -f <distinctive-args>`) and then verify none remain — that
verification is itself a condition-based wait.

## Waiting on dispatched work

Two failure modes, opposite in shape:

- **Never poll a wait interface with short timeouts.** It burns turns and
  context to learn nothing.
- **Never sit in one silent, open-ended wait either.** A child that dies
  quietly is then discovered at the end of the session instead of in minutes.

So: while you have local work — notes, packaging the next review, reading
reports — keep working; results arrive on their own. When genuinely idle, wait
in **bounded stretches** (five to ten minutes where the platform allows), and
between stretches post one line of status and reconcile your live children:
list them, and chase any that finished without reporting.

A bounded stretch keeps nearly all of a long wait's efficiency while
guaranteeing a stuck child is noticed within minutes.

## Before you trust the result

A wait that returned is not proof the work succeeded — only that the condition
you wrote became true. Ask whether the condition could have been satisfied by
something other than success. If it could, that is the bug, and it is the same
bug as the `colcon` grep.
