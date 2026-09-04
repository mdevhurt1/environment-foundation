---
name: systematic-debugging
description: Use when encountering any bug, test failure, or unexpected behavior, before proposing fixes. Four phases that end at a root cause and a failing test, not at a plausible story about what went wrong.
---

# systematic-debugging — root cause before fix, every time

**Core principle:** ALWAYS find the root cause before attempting a fix. A
symptom fix is a failure, and so is a correct fix arrived at by guessing.

**Violating the letter of this process is violating the spirit of debugging.**

## The Iron Law

```
NO FIXES WITHOUT ROOT CAUSE INVESTIGATION FIRST
```

If you have not completed Phase 1, you cannot propose fixes.

## When to Use

Any technical issue: test failures, bugs in production, unexpected behavior,
performance problems, build failures, integration issues, a helper that exits
0 and does nothing.

**ESPECIALLY when:**

- you are under time pressure (emergencies make guessing tempting)
- "just one quick fix" seems obvious
- you have already tried multiple fixes
- the previous fix did not work
- you do not fully understand the issue

**Do not skip when** the issue seems simple (simple bugs have root causes
too), when you are in a hurry (rushing guarantees rework), or when the CEO
wants it fixed now (systematic is faster than thrashing).

## The Four Phases

Complete each phase before proceeding to the next.

---

### Phase 1: Root Cause Investigation

#### 1. Check the host and the instrument before you believe the failure

**This company's most expensive debugging failures were self-inflicted false
signals, not product defects.** Do this first, every time:

```bash
ps -eo pid,pcpu,etimes,comm --sort=-pcpu | head    # etimes separates YOUR leftovers from this run
uptime                                             # load average vs core count
```

On 2026-08-08 two failures were reported as possible product defects and both
were self-inflicted. A `controller_server` probe left over from an earlier
diagnostic ran at 100% CPU for 26 minutes, pushing load to 15.2 on 4 cores; on
that contended box Nav2's lifecycle manager reported `Failed to change state`
for a node that was configuring fine. `tmux kill-session` had killed the
sessions but **not the processes inside them** — kill by pattern
(`pkill -f <distinctive-args>`) and then verify none remain.

Two tells worth memorizing:

- **A failure whose identity moves between runs is almost always
  environmental.** A real config defect fails the same way every time.
- **A check that has never fired is not an instrument.** Before trusting a
  green, make it go red on purpose. And be *most* sceptical of a count whose
  author advertises having already corrected it once — the sentinel report's
  corrected `awk` range went from a wrong 0 to a wrong 16 against a true 24
  (`reference_a_corrected_instrument_is_not_a_verified_one`).

Say "this looks environmental, confirming on a clean host" rather than
reporting it as a defect. Then re-run and report the clean result.

#### 2. Read error messages carefully

Do not skip past errors or warnings; they often contain the exact solution.
Read stack traces completely. Note line numbers, file paths, error codes.

**Silence is a symptom too.** In this codebase the characteristic failure is a
guard that exits 0 having done nothing: `cc-skills-inject.sh` resolved
`$BASH_SOURCE/../skills` through the `~/.claude` symlink, landed on `~/skills`,
missed, and exited 0 **silently**. Nothing was injected and nothing said so.
When a thing did not happen, ask which guard swallowed it.

#### 3. Reproduce consistently

Can you trigger it reliably? What are the exact steps? Every time? If it is
not reproducible, gather more data — do not guess.

#### 4. Check recent changes

`git log --oneline -20`, `git diff`, new dependencies, config changes,
environment differences. In this repo, also check whether `configure.sh` has
run since the change: `~/.claude/*` symlinks point at whichever clone ran it —
normally the **main** worktree — so an edit made in a branch worktree may not
be the code that is executing.

```bash
readlink ~/.claude/skills   # which clone is actually live?
git rev-parse --show-toplevel
```

#### 5. Gather evidence at every component boundary

**WHEN the system has multiple components** (`cc-branch` → `.cc-mode` →
tree slot → events dir → the parent's read marker; or sandbox → Bash env →
API key → proxy → LAN host), **instrument the boundaries before proposing a
fix:**

```
For EACH component boundary:
  - log what enters
  - log what exits
  - verify environment/config propagation
  - check state at each layer

Run once to gather evidence showing WHERE it breaks
THEN analyze the evidence to identify the failing component
THEN investigate that specific component
```

Worked example — "the parent never sees its children's events":

```bash
# Layer 1: does the child know its parent?
grep -E '^(session_id|parent_id)=' .cc-mode

# Layer 2: did an event file get written at all?
ls -la ~/vault/20-surface/company/tree/sessions/<parent_id>.events/

# Layer 3: what NAMES are in that directory?
ls ~/vault/20-surface/company/tree/sessions/<parent_id>.events/ | sed 's/-.*//' | sort -n | uniq -c

# Layer 4: what does the read marker hold?
cat ~/vault/20-surface/company/tree/sessions/<parent_id>.events/.read-up-to
```

That is the trace that found AI_ST-74: events dirs held **both**
`NNNN-<verb>.md` and `<epoch>-<verb>.md` names, the marker logic treats the
leading number as a monotonic cursor, and once the marker held an epoch
(~1.8e9) every later `NNNN-` event compared below it and was unread forever.
Layers 1–3 were all green. Only Layer 4 showed it.

#### 6. Trace data flow backward

**WHEN the error is deep in a call stack**, see `root-cause-tracing.md` in
this directory. Quick version: where does the bad value originate, what called
this with it, keep tracing up until you find the source, fix at the source.

---

### Phase 2: Pattern Analysis

1. **Find working examples.** What similar thing in this codebase works? The
   canonical skills, shell helpers, and tests are full of near-twins.
2. **Compare against references COMPLETELY.** If you are implementing a
   pattern, read the reference implementation every line. Do not skim. In this
   repo the reference is usually a sibling helper in `canonical/shell/` or a
   sibling test file — both carry a header comment explaining *why* they are
   shaped the way they are. Read the header.
3. **Identify differences.** List every difference between working and broken,
   however small. Do not assume "that can't matter" — the differences that
   mattered here were a `.git` that is a *file* in a worktree, an unquoted
   space inside a `case` bracket expression, and a `local` statement
   referencing a name assigned earlier in the same statement.
4. **Understand dependencies.** What else does this need — settings, env,
   symlinks, a sourced `cc-functions.sh`, a reachable vault, a tmux server?

---

### Phase 3: Hypothesis and Testing

1. **Form a single hypothesis.** State it: "I think X is the root cause
   because Y." Write it down. Be specific.

2. **Test minimally.** The smallest possible change that discriminates. One
   variable at a time. Do not fix several things at once — you will not know
   which one worked.

3. **Verify before continuing.** Worked → Phase 4. Did not work → form a
   **new** hypothesis. Do not stack fixes.

4. **Your explanation of the failure is itself an unchecked claim.** This is
   the failure class that survived three consecutive review rounds in one
   paragraph. When you write a sentence beginning "because", "which cannot",
   or "the reason is", you have made a *new* factual assertion — and it is the
   one nobody audits, because it arrives wearing the correction's
   credibility. Fetch the primary source for it, or **delete the mechanism
   rather than substituting one you cannot verify**. The sentence position
   feels like it needs filling; that feeling is the bug.
   (`reference_an_explanation_of_a_failure_is_an_unchecked_claim`)

5. **When you don't know, say "I don't understand X."** Do not pretend.
   Research more, or escalate — in a branched session that means a `question`
   event to your parent stating what you need *and* what you already ruled
   out, and then continuing on what is not blocked.

---

### Phase 4: Implementation

1. **Create a failing test case first.** Simplest possible reproduction,
   automated if a framework exists. In this repo that is a `t_*` assertion in
   `software/development/claude-code/tests/test_<area>.sh`, picked up
   automatically by `tests/run-tests.sh`. **Watch it go RED against the
   current code** — a test written after the fix proves nothing about what the
   fix changed. Use test-driven-development.

2. **Implement a single fix.** Address the root cause. ONE change. No "while
   I'm here" improvements, no bundled refactoring.

3. **One commit per bug**, even when several fixes touch the same file. Every
   commit must be independently bisectable: `git checkout -q <sha>` and re-run
   the suite. Confirm the end state with `diff -r` against the pre-split tree
   so the split provably lost nothing.

4. **Verify the fix.** Record the baseline before and after — this repo prints
   `N assertions passed across M test file(s)`. Does the target test pass? Did
   anything else break? Use verification-before-completion before claiming
   success.

5. **If the fix doesn't work:** STOP. Count your attempts. Fewer than 3 →
   return to Phase 1 and re-analyze with the new information. **3 or more →
   stop and question the architecture.**

6. **If 3+ fixes failed: question the architecture.**

   Pattern indicating an architectural problem: each fix reveals new shared
   state or coupling somewhere else; fixes require "massive refactoring"; each
   fix creates new symptoms elsewhere.

   Ask: is this pattern fundamentally sound? Are we sticking with it through
   inertia? Refactor versus continue fixing symptoms?

   This is not a failed hypothesis — it is a wrong architecture. Raise it with
   the CEO (or escalate to your parent as a `blocker` event with what you
   ruled out) before attempting more fixes.

## Red Flags — STOP and follow the process

- "Quick fix for now, investigate later"
- "Just try changing X and see if it works"
- "Add multiple changes, run tests"
- "Skip the test, I'll manually verify"
- "It's probably X, let me fix that"
- "I don't fully understand but this might work"
- "The pattern says X but I'll adapt it differently"
- "Here are the main problems: [lists fixes without investigation]"
- proposing solutions before tracing data flow
- **"One more fix attempt"** (when you have already tried 2+)
- **each fix reveals a new problem in a different place**
- **writing a "because" clause you have not sourced**

**All of these mean: STOP. Return to Phase 1.**

## Signals from the CEO that you are doing it wrong

| What you hear | What it means |
|---|---|
| "Is that not happening?" | You assumed without verifying |
| "Will it show us…?" | You should have added evidence gathering |
| "Stop guessing" | You are proposing fixes without understanding |
| "Ultra-think this" | Question fundamentals, not just symptoms |
| "We're stuck?" (frustrated) | Your approach is not working |

When you see these: STOP. Return to Phase 1.

## Common Rationalizations

| Excuse | Reality |
|--------|---------|
| "Issue is simple, don't need process" | Simple issues have root causes too. The process is fast for simple bugs. |
| "Emergency, no time for process" | Systematic debugging is FASTER than guess-and-check thrashing. |
| "Just try this first, then investigate" | The first fix sets the pattern. Do it right from the start. |
| "I'll write the test after confirming the fix works" | A test that was never red is not evidence. |
| "Multiple fixes at once saves time" | You cannot isolate what worked, and you cause new bugs. |
| "The reference is long, I'll adapt the pattern" | Partial understanding guarantees bugs. Read it completely. |
| "I see the problem, let me fix it" | Seeing symptoms ≠ understanding root cause. |
| "One more fix attempt" (after 2+ failures) | 3+ failures = architectural problem. Question the pattern, don't fix again. |
| "The test failed, so the code is broken" | Check the host first. Two of this company's reported defects were leftover processes and a loose wait condition. |
| "I fixed the wrong number and it's right now" | A corrected instrument is not a verified one. Re-derive it a second way. |
| "It passes here, so it's fine" | Your `~/.claude` may point at the other clone. `readlink` before you believe. |

## Quick Reference

| Phase | Key activities | Success criteria |
|-------|---------------|------------------|
| **1. Root cause** | Check host, read errors, reproduce, check recent changes, instrument boundaries | Understand WHAT and WHY |
| **2. Pattern** | Find working examples, compare completely | Identify the differences |
| **3. Hypothesis** | Form one theory, test minimally, source your "because" | Confirmed, or a new hypothesis |
| **4. Implementation** | Failing test first, one fix, one commit, verify | Bug resolved, suite green |

## When the process reveals "no root cause"

If systematic investigation shows the issue really is environmental,
timing-dependent, or external:

1. you have completed the process
2. document what you investigated
3. implement appropriate handling (retry, bounded wait, a real error message)
4. add monitoring or logging for the next occurrence

**But:** 95% of "no root cause" cases are incomplete investigation, and in
this company the leading cause of the other 5% turned out to be a dirty host.

## Supporting Techniques

In this directory:

- **`root-cause-tracing.md`** — trace a bug backward through the call chain to
  the original trigger
- **`defense-in-depth.md`** — validate at every layer after finding the root
  cause, so the bug becomes structurally impossible
- **`condition-based-waiting.md`** — replace arbitrary sleeps with a condition
  pinned to the thing you are actually waiting on
- **`find-polluter.sh`** — bisect a test suite to find which test creates
  unwanted files or state
