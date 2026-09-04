---
name: executing-plans
description: Use when you have a written implementation plan to execute in a separate session with review checkpoints. The single-executor path — one session works the plan task by task. Prefer subagent-driven-development when you can dispatch subagents and the plan's tasks are independent.
---

# executing-plans — work an approved plan, alone, in one session

You hold a plan somebody already approved. Your job is to execute it, not to
redesign it, and to keep the review checkpoints the plan assumes. One session,
one executor, no subagents.

**Announce at start:** "Using executing-plans to implement `<plan path>`."

## Checklist (you MUST complete each item, in order)

- [ ] Step 1: Resolve the plan and confirm the workspace
- [ ] Step 2: Route — should this be subagent-driven-development instead?
- [ ] Step 3: Pre-flight review of the plan
- [ ] Step 4: Execute task by task
- [ ] Step 5: Checkpoints — rule, escalate, and keep working
- [ ] Step 6: Finish

## Step 1: Resolve the plan and confirm the workspace

Plans live in three places in this company. Probe, in this order — the first
hit wins:

```bash
mode_file=$(d="$PWD"; while [ "$d" != / ]; do [ -f "$d/.cc-mode" ] && echo "$d/.cc-mode" && break; d=$(dirname "$d"); done)
slug=$( { grep '^slug=' "$mode_file" || true; } | cut -d= -f2-)
plane_issue=$( { grep '^plane_issue=' "$mode_file" || true; } | cut -d= -f2-)
task_id="${plane_issue:-$slug}"
ls -1 "$HOME/vault/20-surface/company/tasks/$task_id/plan.md" 2>/dev/null   # writing-plans output
ls -1 ./docs/superpowers/plans/*.md 2>/dev/null                            # what cc-build gates on
ls -1 "$HOME/.claude/plans/"*.md 2>/dev/null                               # ad-hoc plan-mode snapshots
```

Both of the first two are live paths, not one legacy and one current:
`writing-plans` writes the task folder, and `cc-build` refuses to launch
without a plan under `docs/superpowers/plans/`. If more than one hits, say
which you took and why before you start.

**Workspace, by `.cc-mode` mode:**

| mode | where you are | what to do |
|---|---|---|
| `branched` | already in `<repo>-branch-<task>` | you **are** the isolated workspace — do not nest another worktree |
| `build` | main worktree, plan already gated | work here; the plan requirement was checked at launch |
| `exploration` | a worktree | work here |
| missing (bare launch) | unknown | treat as exploration; create isolation with using-git-worktrees |

Never start implementation on `main`/`master` without explicit consent. If
`git rev-parse --abbrev-ref HEAD` says main and no one has said otherwise,
stop and get it in writing.

## Step 2: Route

Use **subagent-driven-development** instead of this skill when both hold:

- your harness can dispatch subagents, and
- the plan's tasks are mostly independent.

It buys a fresh context per task and a review gate after each one. Stay here
when there are no subagents, when the tasks are tightly coupled (each one
needs the last one's discoveries in context), or when the plan is short enough
that dispatch overhead exceeds the work.

Say which you chose in one line, then proceed.

## Step 3: Pre-flight review of the plan

Read the plan once, end to end. If it names a spec, read that too — **the spec
is the binding authority and the plan is its argument**; conflicts inside the
plan resolve against the spec. A plan with no reachable spec means every
ruling you make is provisional; say so once, up front.

Then scan for defects before Task 1, and write down what you checked:

- tasks that contradict each other or the plan's Global Constraints
- a name defined in one task and used differently in a later one
  (`clearLayers()` in Task 3 vs `clearFullLayers()` in Task 7 is a bug)
- steps that mandate something the review would treat as a defect

Create one todo per task. A clean scan needs no commentary; findings get ruled
on now, not mid-flight (Step 5).

## Step 4: Execute task by task

For each task: mark in progress → follow the steps exactly (the plan's steps
are bite-sized on purpose) → run the verification the task names → mark
complete.

- **One task, one commit.** The plan template says so, and every commit must
  be independently bisectable.
- **Strict TDD where the task produces code.** Write the failing test, run it,
  watch it go RED, then write the minimal code to reach GREEN. A test that was
  never red is not evidence. Use test-driven-development.
- **One commit per bug**, even when several fixes touch the same file. A
  combined commit destroys bisectability and a later bisect lands on a change
  that fixed three things at once.
- Run the focused test while iterating; run the full suite once before
  committing, not after every edit.
- Record the baseline (`N/N` before) and the result (`N/N` after). "Tests
  passed earlier" is not a result for the tree you are about to commit.

## Step 5: Checkpoints — rule, escalate, and keep working

The plan's checkpoints are real, but **what a checkpoint means depends on
whether anyone is watching your pane.**

**Interactive session (`build`, `exploration`, bare):** a human is reachable.
Raise the concern, state your recommendation, and wait.

**Branched or otherwise autonomous session:** nobody is watching. A question
asked into the pane idles forever while the tree slot still reads `running` —
`ENPM808-71` sat ~20 minutes at exactly such a prompt while four siblings
worked, and all five branches on 2026-08-13 hit this class. So: **decide, log
the decision, escalate in parallel, and keep going.**

Record each decision in the plan's task folder or your working notes as
`Ruling: <what you decided> — <why> — <what it costs if wrong>`. A wrong
ruling costs rework the CEO can see and undo; a session parked on a question
costs the whole day and buys nothing.

Escalate with the stamping helper — never hand-write an event file, because
hand-written `emitted_at` stamps are fiction (4 of 6 were wrong in the
2026-09-03 audit, one impossible):

```bash
bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/../shell/cc-event-emit.sh" \
  --to-session <parent_id from .cc-mode> \
  --verb blocker --severity critical \
  --title "one line" --body "$(cat <<'BODY'
What I need.
What I already ruled out.
What I am working on meanwhile.
BODY
)"
```

A `blocker` or `question` body states what you need **and** what you already
ruled out. Then go work on whatever the blocker does not touch.

**Four things genuinely stop you, and only these:**

1. an irreversible or destructive operation
2. a security-sensitive action
3. a side effect outside this worktree that norms say you ask about first — a
   merge to a shared branch, a push, a publish
4. a plan so broken that every path forward is a guess

**Return to Step 3** when the plan is amended, or when the approach itself
turns out to be wrong. Do not force through a structural defect.

## Step 6: Finish

1. Use verification-before-completion. Evidence before assertions: paste the
   command and its output, do not summarize a run you did not just do.
2. Use finishing-a-development-branch for the integration decision.
3. **Branched sessions do not push.** Merge to local `main` when clean and
   green, then report "merged to local main, unpushed" — the parent (EA)
   session owns the push, so the disclosure review happens with a human
   reachable. `cc-doctor`'s **Push lag** check stays WARN until it lands, so a
   skipped push cannot go silently stale.
4. Emit a `completion` event to your parent: outcome per ticket, what needs
   the parent's action (or "none"), the report path. Thinner completions are
   refused by the helper.
5. Invoke `end-conversation` via the **Skill tool**. `/end` is not a
   registered command and a session waiting on it stalls.

## Common Rationalizations

| Excuse | Reality |
|--------|---------|
| "The plan is obviously wrong here, I'll just do it right" | Rule on it and record the ruling. An unrecorded deviation is a decision made in secret. |
| "I'll ask about this and pick it up when they answer" | In a branched session nobody answers. Rule, emit the event, keep working. |
| "Two tasks touch the same file, one commit is cleaner" | One commit per task. Bisectability is the point. |
| "I'll write the test once the fix works" | A test that was never red proves nothing about what the fix changed. |
| "The suite was green an hour ago" | Green proves only the tree it ran on. Re-run before you commit. |
| "It's merged and green — pushing is a formality" | Merged-but-unpushed work lives on one disk. In a branched session the push is the EA's; say so out loud. |
| "The plan didn't mention a spec, so there isn't one" | Look for it. Without one, every ruling is provisional and you must say so. |
| "Faster to skip the pre-flight scan and fix conflicts as they surface" | A conflict found in Task 7 costs the six tasks built on it. |

## Boundaries

- You execute the plan; you do not rewrite it. Amendments are rulings,
  recorded, not silent edits.
- Stay inside your worktree and your task folder. A sibling session's task
  folder and the `tasks/` parent are read-only — a write failing there is the
  sandbox carveout working, not a bug to route around.
- The EA owns every Plane write. Read tickets freely; report what the board
  should say and let the parent apply it.
- `~/vault/00-core/`, `10-middle/`, and `40-journal/` are never written from
  here, whatever the plan says.
