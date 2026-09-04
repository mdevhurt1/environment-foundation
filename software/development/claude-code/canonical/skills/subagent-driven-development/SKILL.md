---
name: subagent-driven-development
description: Use when executing implementation plans with independent tasks in the current session. Dispatches a fresh implementer per task, gates each on a task review, and closes with a whole-branch review — the controller's context stays clean for coordination.
---

# subagent-driven-development — one session controls, subagents do the work

Execute a plan by dispatching a fresh implementer per task, a task review
(spec compliance + code quality) after each, and one broad whole-branch review
at the end.

**Why subagents:** you delegate to agents with isolated context. By crafting
their instructions precisely you keep them focused; they never inherit your
session's history, so you construct exactly what they need. This is what
preserves *your* context for coordination — the scarce resource in a long run.

**Core principle:** fresh subagent per task + task review (spec + quality) +
broad final review = high quality, fast iteration.

**Narration:** at most one short line between tool calls. The ledger and the
tool results carry the record.

## Rulings, not stalls

**A running plan does not wait on a human.** Conflicts, ambiguities, plan
defects, a cap you would have asked to exceed — decide them. The spec is the
binding authority, the plan is its argument, and your judgment settles what
neither answers.

This is not a preference, it is what the pane can support. A branched session
has nobody watching it: `ENPM808-71` sat ~20 minutes at a prompt while four
siblings worked, and all five branches on 2026-08-13 hit that class. A wrong
ruling costs rework the CEO can see and undo; a session parked on a question
costs the whole day and buys nothing.

Record every decision in the ledger as:

```
Ruling: <what you decided> — <why> — <what it costs if wrong>
```

**Escalate in parallel, then keep working.** Escalation is not a stop. Emit a
`question` or `blocker` event to your parent stating what you need **and what
you already ruled out**, then go work on what the blocker does not touch:

```bash
bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/../shell/cc-event-emit.sh" \
  --to-session "$parent_id" --verb blocker --severity critical \
  --title "one line" --body "$(cat <<'BODY'
What I need.
What I already ruled out.
What I am doing meanwhile.
BODY
)"
```

Never hand-write an event file: hand-authored `emitted_at` stamps are fiction
— 4 of 6 were wrong in the 2026-09-03 audit, one impossible (AI_ST-74).

**Four things stop you, and only these:** an irreversible or destructive
operation; a security-sensitive action; a side effect outside this worktree
that norms say you ask about first (a merge to a shared branch, a push, a
publish); and a plan so broken that every path forward is a guess.

## When to use

| You have | Tasks are | Then |
|---|---|---|
| an implementation plan | mostly independent | **this skill** — fresh context per task, review gate per task |
| an implementation plan | tightly coupled (each needs the last one's discoveries in context) | executing-plans, or manual execution |
| an implementation plan | independent, but no subagent dispatch available | executing-plans |
| no plan | — | brainstorming → writing-plans first |

Against **executing-plans**: same session, no context switch; a fresh subagent
per task so context never pollutes; a review after each task; and no
human-in-loop between tasks.

## The process, end to end

1. **Setup** — confirm the worktree, resolve the plan workspace, check for a
   ledger, read the plan, pre-flight scan.
2. **Per task:** dispatch implementer → handle its report → generate the
   review package → dispatch the task reviewer.
   - Spec ✅ and quality approved → ledger the completion, next task.
   - Otherwise → **fix loop**, up to 5 rounds (rounds 1–3 resume the original
     implementer; rounds 4–5 dispatch fresh on a more capable model). Every
     round ends with a scoped re-review.
   - Round 5 still open → **the breaker**: adjudicate each open finding
     yourself, park it with a ruling or rule on the smallest unblocking
     change. Never silently discard.
3. **After all tasks** — one whole-branch review, ONE fix dispatch for its
   findings, one scoped re-review, adjudicate residuals.
4. **Finish** — roll up every `Ruling:` line, delete the plan workspace, hand
   off to finishing-a-development-branch.

## Setup

### Worktree

The work happens in an isolated worktree. By `.cc-mode` mode:

| mode | action |
|---|---|
| `branched` | you are already in `<repo>-branch-<task>` — **do not nest another worktree** |
| `build` | main worktree, plan already gated at launch — work here |
| `exploration` / missing | create or verify isolation with using-git-worktrees |

Never start implementation on `main`/`master` without explicit consent.

### The plan and the spec

Plans live in three places; probe in this order and say which you took:

```bash
mode_file=$(d="$PWD"; while [ "$d" != / ]; do [ -f "$d/.cc-mode" ] && echo "$d/.cc-mode" && break; d=$(dirname "$d"); done)
slug=$( { grep '^slug=' "$mode_file" || true; } | cut -d= -f2-)
plane_issue=$( { grep '^plane_issue=' "$mode_file" || true; } | cut -d= -f2-)
task_id="${plane_issue:-$slug}"
ls -1 "$HOME/vault/20-surface/company/tasks/$task_id/plan.md" 2>/dev/null   # writing-plans output
ls -1 ./docs/superpowers/plans/*.md 2>/dev/null                            # what cc-build gates on
ls -1 "$HOME/.claude/plans/"*.md 2>/dev/null                               # plan-mode snapshots
```

Read the plan **once**, note its context and Global Constraints, and create a
todo per task. If it names a spec, read that too — the spec is the authority
the plan argues from, and conflicts inside the plan resolve against it. A plan
with no reachable spec gets a ledger note saying so; rulings made without one
are provisional.

### The workspace and the ledger

Conversation memory does not survive compaction. Controllers that lost their
place have re-dispatched entire completed task sequences — the single most
expensive failure in this process. **Track progress in a ledger file, not only
in todos.**

- Each plan owns a workspace. Run this skill's `scripts/sdd-workspace
  PLAN_FILE`; it prints the plan's git-ignored directory
  (`<repo-root>/.cc/sdd/<plan-basename>/`), home to every artifact for THIS
  plan: ledger, briefs, reports, review packages. Another plan's directory is
  never yours to read or write.
- Check for this plan's ledger at `<workspace>/progress.md`. If its first line
  names your plan file, tasks with a `Task <N>: complete` line are DONE — do
  not re-dispatch them; resume at the first task without one. A task whose
  last line is a fix round is mid-loop: resume at the next round.
- A ledger whose first line names a **different** plan file — or a stray one
  at a legacy path (`.superpowers/sdd/…`, or a flat
  `.superpowers/sdd/progress.md`) — is another plan's progress. Leave it in
  place and start your own, fresh.
- Create the ledger with its identity as the first line:
  `# SDD ledger — plan: <plan file path>`.
- The ledger is your recovery map: the commits it names exist in git even when
  your context no longer remembers creating them. **After compaction, trust
  the ledger and `git log` over your own recollection.**
- `git clean -fdx` destroys the workspace (it is git-ignored scratch). If that
  happens, recover from `git log`.

### Pre-flight scan

Before dispatching Task 1, scan the plan for conflicts, writing down what you
checked as you check it:

- tasks that contradict each other or the plan's Global Constraints
- anything the plan mandates that the review rubric treats as a defect (a test
  that asserts nothing, verbatim duplication of a logic block)

**The scan's output is a table, not a verdict.** One row for every pair of
tasks sharing a file or an interface: the two tasks, what one produces against
what the other consumes, what you found. One row for every task: whether its
own text agrees with itself — the tests it specifies against the code it
specifies, the files it creates against the files it later touches. "The scan
is clean" without those rows is not a scan you ran.

Write the table to the ledger, rule on every finding before execution begins
(each finding against the plan text that mandates it), and record each ruling
beside its row. Then dispatch Task 1. The review loop remains the net for
conflicts that only emerge from implementation.

## Model Selection

Use the least powerful model that can do each role — but **specify it
explicitly, every dispatch.**

**An omitted model is not "the sensible default", it is a moving referent.**
Claude Code's Default resolves to the most capable model on the account, so a
newly-released model captures every unpinned dispatch with no diff, no event
and no line of output. That is how the EA session silently moved Opus 5 →
Fable 5 — discovered by a bill, which is why `__cc_resolve_model` refuses
rather than falling back.

This company's register of record is `canonical/model-policy.json`, and it
already carries the three roles this skill needs:

| SDD role | policy role | today |
|---|---|---|
| mechanical implementer (1–2 files, complete spec) | `cheap-mechanical` | `track-latest` |
| reviewer / scoped re-reviewer | `review-lane` | `track-latest` |
| in-process Agent-tool dispatch generally | `subagent-default` | `track-latest` |

All three read `track-latest` and are marked "not yet mechanized" — the CEO
assigns real tiers on merge review. Until they are pinned, **name the model in
each dispatch and say in the ledger which tier you chose and why.** Do not
invent a fourth policy role.

Complexity signals for implementation tasks:

- touches 1–2 files with a complete spec → cheapest tier
- touches multiple files with integration concerns → standard tier
- requires design judgment or broad codebase understanding → most capable

Reviews scale to the diff's size, complexity, and risk: a small mechanical
diff does not need the most capable model; a subtle concurrency change does.
Scoped re-reviews of small fix diffs take a cheap-to-mid tier. **The final
whole-branch review takes the most capable available model.** Fix-loop
escalation (rounds 4–5) takes at least one tier above the implementer that got
stuck.

**Turn count beats token price.** Wall-clock and context cost scale with how
many turns a subagent takes, and the cheapest models routinely take 2–3× the
turns on multi-step work, costing more overall. Use a mid-tier model as the
floor for reviewers and for implementers working from prose. When the plan
text contains the complete code to write, the implementation is transcription
plus testing — cheapest tier is right. Single-file mechanical fixes too.

## The Task Loop

**Batch small same-shape work.** When the plan lists several tasks that are
each a small, independent edit of the same kind — the same one-line fix,
constant change, or field addition repeated across files — do not dispatch one
subagent per task. Compose ONE brief listing every file and its change, send
the batch to a single subagent, and review its diff as one unit. Reserve
one-dispatch-per-task for work needing its own judgment, tests, or review
surface.

**Hand artifacts over as files.** Everything you paste into a dispatch prompt,
and everything a subagent prints back, stays resident in your context for the
rest of the session and is re-read on every later turn.

**Waiting.** Never poll a wait interface with short timeouts, and never sit in
one silent open-ended wait either. While you have local work — ledger updates,
packaging the next review, reading reports — keep working; results arrive on
their own. When genuinely idle, wait in bounded stretches (five to ten
minutes where the platform allows); between stretches post one line of status
and reconcile your live children, chasing any that finished without reporting.
See `../systematic-debugging/condition-based-waiting.md`.

### 1. Dispatch the implementer

Record BASE (`git rev-parse HEAD`) before dispatching — the review package and
the fix-round diffs need it.

- **Task brief:** run `scripts/task-brief PLAN_FILE N`. It extracts the task's
  full text to a uniquely named file and prints the path. The brief is the
  single source of requirements. Your dispatch carries: (1) one line on where
  this task fits; (2) the brief path, introduced as "read this first — it is
  your requirements, with the exact values to use verbatim"; (3) interfaces
  and decisions from earlier tasks the brief cannot know; (4) your resolution
  of any ambiguity you noticed in the brief; (5) the report-file path and the
  report contract. Exact values — numbers, magic strings, signatures, test
  cases — appear **only** in the brief. Never make a subagent read the whole
  plan.
- **Report file:** name it after the brief (`…/task-N-brief.md` →
  `…/task-N-report.md`) and put it in the dispatch. The implementer writes the
  full report there and returns only status, commits, a one-line test summary,
  and concerns.
- **A dispatch describes one task, not the session's history.** Do not paste
  accumulated prior-task summaries into later dispatches. A fresh subagent
  needs its task, the interfaces it touches, and the global constraints.
  Nothing else.
- The dispatch carries the **no-subagents contract** (it is in the implementer
  template): the implementer never dispatches subagents — not helpers, and
  never a reviewer. Review arrives from you, after the report. A reviewer a
  worker spawns duplicates the task review you were going to dispatch anyway,
  at full cost, and its approval counts for nothing.
- If an earlier task parked a finding in the area this task touches, carry a
  pointer to that ledger entry in the dispatch.
- Record the implementer's agent identity from the dispatch result — fix-loop
  rounds 1–3 resume this agent.
- **Never dispatch multiple implementers in parallel** (conflicts).

Template: [implementer-prompt.md](implementer-prompt.md)

### 2. Handle the report

**DONE** — generate the review package (`scripts/review-package PLAN_FILE BASE
HEAD`; it prints the file path it wrote). BASE is the commit you recorded
before dispatching — **never `HEAD~1`**, which silently drops all but the last
commit of a multi-commit task. Then dispatch the task reviewer with that path.

**DONE_WITH_CONCERNS** — the work is complete but the implementer flagged
doubts. Read them first. Concerns about correctness or scope get addressed
before review; observations ("this file is getting large") get noted and you
proceed.

**NEEDS_CONTEXT** — provide the missing information and re-dispatch.

**BLOCKED** — assess: a context problem → more context, same model; needs more
reasoning → more capable model; too large → break it up; the plan itself is
wrong → rule on the correction, ledger it, re-dispatch carrying the ruling.

**Never** ignore an escalation or force the same model to retry without
changes. If the implementer said it is stuck, something has to change.

If the implementer asks questions — before starting or mid-task — answer
clearly and completely, and do not rush it into implementation.

### 3. Review the task

Per-task reviews are task-scoped gates; the broad review happens once, at the
end. **Never skip the task review, and never accept a report missing either
verdict** — spec compliance AND task quality are both required. An
implementer's self-review never replaces it.

- **Hand the reviewer its diff as a file.** Run `scripts/review-package
  PLAN_FILE BASE HEAD` and pass the printed path. The diff never enters your
  context, and the reviewer sees commits, stat summary, and full `-U10` diff
  in one Read. Never dispatch a task reviewer without a diff file.
- **Reviewer inputs:** the brief file, the report file, the review package,
  plus the global constraints that bind the task.
- **The global-constraints block is the reviewer's attention lens.** Copy the
  binding requirements verbatim from the plan's Global Constraints or the
  spec: exact values, exact formats, and the stated relationships between
  components ("same layout as X", "matches Y"). The reviewer's template
  already carries the process rules — the constraints block is for what THIS
  project's spec demands.
- Do not add open-ended directives ("check all uses", "run race tests if
  useful") without a concrete, task-specific reason.
- Do not ask a reviewer to re-run tests the implementer already ran on the
  same code — the report carries the test evidence.
- **Do not pre-judge findings.** Never instruct a reviewer to ignore or not
  flag a specific issue. If you think a finding would be a false positive, let
  it be raised and adjudicate it in the loop. If your prompt contains "do not
  flag", "don't treat X as a defect", "at most Minor", or "the plan chose" —
  stop: you are pre-judging, usually to spare yourself a review loop.

A reviewer may report **"⚠️ Cannot verify from diff"** items — requirements
living in unchanged code or spanning tasks. These do not block the rest of the
review, but **you** resolve each one before marking the task complete; you
hold the cross-task context the reviewer lacks. A confirmed gap is a failed
spec review and enters the fix loop.

Template: [task-reviewer-prompt.md](task-reviewer-prompt.md)

### 4. The fix loop

Triggered by: spec ❌, any Critical or Important finding, or a ⚠️ item you
confirmed as a real gap.

Two routes leave the loop immediately:

- **Minor findings never enter it.** Record them in the ledger as you go
  (`Task <N>: minor (deferred): <one-liner>`) and point the final whole-branch
  review at that list so it can triage what must be fixed before merge. A
  roll-up nobody reads is a silent discard.
- **A plan-mandated finding is yours to rule on.** Weigh the finding against
  the plan text, decide with the spec as binding authority, ledger the ruling
  before acting. Do not dismiss a finding because the plan mandates it, and do
  not dispatch a fix that contradicts the plan without a recorded ruling.

Everything else enters the loop. **A round is one fix dispatch plus one scoped
re-review. Five rounds maximum per task.**

**Rounds 1–3 — resume the original implementer.** Send the open findings
verbatim; its context is intact. If your harness cannot message a live
subagent, dispatch a fresh one carrying the brief path, the report-file path,
and the findings — the report file is the persistent memory either way.

**Rounds 4–5 — fresh implementer, more capable model,** with the brief path,
the report-file path, the open findings, and this framing: "A prior
implementer attempted this task N times; you own it now. Read the report file
for what was tried." A loop that survives three resumes usually means the
implementer cannot see its own problem — fresh eyes and a capability bump in
one move.

**Every round, either way:** the implementer fixes, re-runs the tests covering
the amended code, appends its fix report to the same report file, and returns
the short contract. Before re-dispatching the reviewer, confirm the fix report
contains **the covering tests, the command run, and the output**; dispatch the
re-review once all three are present. Name the covering test files in the fix
message — a one-line fix does not need the whole suite.

**The re-review is scoped.** Run `scripts/review-package PLAN_FILE FIX_BASE
HEAD` where FIX_BASE is the head the previous review saw, and dispatch
[re-review-prompt.md](re-review-prompt.md) with the findings list, the brief,
the report file, and the printed diff path. The re-reviewer verdicts each
finding ADDRESSED or NOT ADDRESSED and flags new breakage **in the fix diff
only**. New Critical/Important breakage there joins the open findings.
Out-of-scope observations become deferred minors — they never extend the loop.

**After each round,** append to the ledger:
`Task <N>: fix round <R>/5 (<X> addressed, <Y> open — <finding one-liners>; commits <a7>..<b7>)`

**Never fix findings yourself in the controller session.** Your context stays
clean for coordination, and controller fixes skip review.

**The breaker.** When round 5's re-review still leaves findings open, stop
dispatching and adjudicate each one — you hold the plan and the cross-task
context the reviewer lacks:

- **Reviewer is wrong, or the point is contestable:** park it —
  `Task <N>: parked — <finding> — Ruling: <why the code stands>`. The final
  review sees both sides.
- **Real, but nothing downstream builds on it:** park it the same way, with a
  ruling saying it is real and deferred.
- **Real and load-bearing** — a later task builds on it, or it reveals a plan
  defect: rule on the smallest change that unblocks the dependent work, ledger
  it as `Task <N>: Ruling: <finding> — <what you decided and why>`, and carry
  it into the next task's dispatch. Parking a structural failure silently lets
  every dependent task build on it. Stop only when the defect leaves every
  path forward a guess.

**Adjudicate only at the cap.** Adjudicating earlier to end a loop is
pre-judging with a different name. Every adjudication is a ledger entry — a
silent discard is forbidden.

### 5. Complete the task

When the review is clean — or every open finding is parked with a ruling at
the cap — append the completion line in the same message as your other
bookkeeping:

- `Task <N>: complete (commits <base7>..<head7>, review clean)`
- `Task <N>: complete (commits <base7>..<head7>, <K> parked)` after a tripped
  breaker

Then mark the todo complete and move on. Never move to the next task while the
review has open Critical/Important issues that are neither fixed nor
parked-with-ruling at the cap.

## Final Review

Run `scripts/review-package PLAN_FILE MERGE_BASE HEAD` (MERGE_BASE = where the
branch started, e.g. `git merge-base main HEAD`) and include the printed path
in the dispatch, so the final reviewer reads one file instead of re-deriving
the branch diff. Dispatch on the **most capable available model**, using
requesting-code-review's
[code-reviewer.md](../requesting-code-review/code-reviewer.md). Point it at
the ledger's deferred-minor and parked lines so it can triage what must be
fixed before merge.

If it returns findings, dispatch **ONE** fix subagent with the complete
findings list — not one fixer per finding. Per-finding fixers each rebuild
context and re-run suites, and a final-review fix wave done that way can cost
more than all the tasks combined. Then run exactly one scoped re-review of the
fix wave. Adjudicate residuals as in the breaker: park with rulings, or rule
on the load-bearing ones and ledger the decision. **There is no second fix
wave** — residual load-bearing findings surface when
finishing-a-development-branch presents the options.

## Finish

1. **Roll up the rulings.** Before deleting anything, collect every ledger line
   containing `Ruling:` — preflight rulings, parked findings, breaker
   adjudications, all of them — into your final message under
   **"Rulings I made"**, in the order you made them, each with what it costs if
   wrong. The list is exhaustive: if the ledger holds a ruling, the list holds
   it. **That list is the only place decisions you took on the CEO's behalf
   reach them.** A ruling that dies with the workspace was a decision made in
   secret.
2. **Delete this plan's workspace** (`rm -rf <workspace>`) once the final
   review is clean and its fixes are merged — git history is the record now.
   Sibling directories belong to other plans; leave them alone.
3. **Use finishing-a-development-branch** for the integration decision.
   **Branched sessions do not push** — merge to local `main` when clean and
   green, report "merged to local main, unpushed", and let the parent (EA)
   session run the disclosure review and the push.
4. **Emit a `completion` event** to your parent: the outcome per
   ticket/deliverable, what needs the parent's action (or "none"), and the
   report path. Thinner completions are refused by the helper (exit 5).
5. **Invoke `end-conversation` via the Skill tool.** `/end` is not a
   registered command; a session waiting on it stalls while its slot still
   reads `running`.

## Common Rationalizations

| Excuse | Reality |
|--------|---------|
| "Close enough on spec compliance" | The reviewer found spec gaps = not done. Fix, or hit the cap and adjudicate — those are the only exits. |
| "I'll fix it myself, dispatching is overhead" | Controller fixes pollute your context and skip review. Resume the implementer. |
| "One more round will converge" | Past the cap, rounds don't converge — the failure is structural. Adjudicate and route. |
| "The reviewer will just find something new anyway" | Scoped re-reviews verify fixes; they cannot wander. New findings on untouched code go to the ledger, not the loop. |
| "This finding is obviously wrong, I'll drop it" | You adjudicate only at the cap, and every ruling is a ledger entry. Silent discards are forbidden. |
| "The fix was small, skip the re-review" | Unreviewed fixes are how regressions land. Every round ends with a scoped re-review. |
| "Reviews slow the loop down" | The loop without reviews is unverified churn. Reviews are its brakes and steering. |
| "Ledger bookkeeping is overhead" | The ledger is what survives compaction. Controllers without one have re-dispatched entire completed task sequences. |
| "The implementer spawned its own reviewer — free extra assurance" | A duplicate seat on the same diff. A worker-spawned reviewer is a defect to flag, not rigor. |
| "I'll ask the CEO which way to go" | Nobody is watching this pane. Rule, ledger it, emit the event, keep working. |
| "I'll leave the model unset and let it pick" | Default is a moving referent. Unpinned dispatch is how a tier changed silently and was found by a bill. |
| "The branch is green, I'll push it" | A branched session never pushes. The EA runs the disclosure review and the push. |

## Boundaries

- **You control; you do not implement.** The controller's context is for
  coordination. Fixes, tests, and commits belong to dispatched agents.
- Stay inside your worktree, your plan's workspace, and your own task folder.
  A sibling's task folder and the `tasks/` parent are read-only — a write
  failing there is the sandbox carveout working, not a bug to route around.
- **The EA owns every Plane write.** Read tickets freely; report what the board
  should say and let the parent apply it.
- `~/vault/00-core/`, `10-middle/`, and `40-journal/` are never written from
  here.
