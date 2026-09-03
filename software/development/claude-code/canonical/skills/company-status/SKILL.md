---
name: company-status
description: On-demand EA company-status pass. Gathers a fresh status report from the tree (children in flight, unread events, what needs the CEO) and safely reclaims the tmux windows of children that have genuinely closed out. Use whenever asked "where do things stand", "status", "what are my branches doing", or before spawning new work. Also use to reclaim finished windows so cc-branch can reuse a task_id.
---

# company-status — the EA status pass, on demand

The command-center CLAUDE.md requires a status orientation at session start.
This skill makes that same pass available **at any moment**, and adds the
window reclaim that the ratified doctrine
(`~/vault/10-middle/decisions/ea-company-status-doctrine.md`) attaches to it.

Two parts, in order:

1. **Report** — answer the three questions from live artifacts.
2. **Reclaim** — close the tmux windows of children that have genuinely
   finished, so `cc-branch` can reuse their task IDs.

## The one rule that matters

> **Gather fresh every single time. Never report from conversation memory.**

This skill exists because of a specific, repeated failure: restating a prior
summary, an event *title*, or an earlier "green" verdict as if it were current
truth. Five recorded instances. The doctrine is
`~/vault/20-surface/claude-memory/feedback_fresh_status_checks.md` — read it if
you have not this session.

Concretely, inside this skill:

- **Never** carry a number, status, or verdict from earlier in the conversation
  into the report. If you already know a child completed, you still re-read its
  slot.
- **Never** state a status from an event title. Titles are claims; open the file.
- **Never** derive an ahead/behind count without `git fetch --all --prune
  --tags` first. `refs/remotes` is a *local cache* and reports fiction silently.
  The scan script does this fetch for you and stamps each count with its
  provenance; if you see `UNVERIFIED` next to a count, say so in the report
  rather than quoting the number bare.
- **Never** cite a tmux window index. Indices renumber on every close — closing
  five windows once renumbered the two survivors. **Task ID is the only stable
  handle**, and it is what `cc-teleport` takes.

## Checklist

- [ ] Step 1: Run the scan (one Bash call, no `cd`)
- [ ] Step 2: Read the scan output and write the three-question report
- [ ] Step 3: Decide reclaim candidates
- [ ] Step 4: Reclaim, atomically
- [ ] Step 5: Report what was reclaimed and what was deliberately kept

---

## Step 1: Run the scan

```bash
bash ~/.claude/skills/company-status/scripts/cc-status-scan.sh --session-id <your-session-id>
```

**Run it as its own Bash call, with no `cd` anywhere in the command.** The
scan resolves identity by walking up from `$PWD` when `--session-id` is
absent, so a `cd` earlier in the same compound command makes it report
another lane's children — the failure class in
`feedback_tree_slot_helpers_resolve_from_cwd.md`. Passing `--session-id`
makes a wrong-lane run *refuse* (exit 3) instead of silently succeeding.
Prefer it always.

The scan prints facts only — it never summarises and never decides. It emits:

| Section | Contents |
|---|---|
| `Q1 — CHILDREN` | every slot whose `parent_id` is yours: task_id, status, `ended_at`, worktree, identity match, branch, **commits ahead/behind main**, **merged?**, **dirty file count**, newest event, task-folder liveness, pane signal |
| `Q2 — UNREAD EVENTS FOR ME` | events newer than the `.read-up-to` marker in your own events dir |
| `Q3 — CANDIDATES` | mechanical flags: blocked, pane signal, stall candidates, done-but-unmerged, reclaim shortlist |

**Check for the `SCAN COMPLETE` sentinel on the last line.** The scan
deliberately does not run under `set -e`, so a broken child is reported and
skipped rather than aborting the run. If the sentinel is missing, the scan
died partway and the sections above it are **incomplete** — do not read a
truncated scan as a quiet company. Re-run it.

### Reading the two liveness signals correctly

The scan gives you two independent signals per child, and they answer
**different questions**. Conflating them is how children have been lost.

**Filesystem — is it making progress?** Task-folder mtime and
`ahead=` commit count. This is the *only* progress oracle. A wedged TUI and a
healthy idle one are indistinguishable in `capture-pane`, and the statusline
context % goes stale too, so a pane that "looks fine" proves nothing. Two
Sentinel branches burned ~8.6 session-hours looking perfectly healthy
(`feedback_verify_branch_liveness_by_filesystem.md`). A child running an hour
with **0 commits and no task folder** is not working, whatever its pane shows —
the scan flags exactly that as a stall candidate.

**Pane — is it stuck on a blocking prompt?** The `signals=` field. This is a
*positive* detector for artefacts an idle-but-healthy session does not render:
a trust dialog, a numbered menu, a permission prompt, `Unknown command: /end`.
Several children have stalled mid-run at an interactive menu and looked
perfectly healthy from the slot alone — the slot said `running`, the session
was idle awaiting input, and nothing but the pane showed it.

So: **presence of a pane signal is informative; absence is not.** And per the
pane-scanning rule, typed-but-unsent text at a Claude TUI prompt is
autogenerated chat suggestion — ignore it, never send it, never attribute it
to the CEO. `signals=none` means "no blocking artefact detected", never "this
child is fine".

Corroborate before acting: a pane signal plus a stale task folder is a stuck
child; a pane signal on a child that committed two minutes ago is noise.

`END_NOT_A_COMMAND` is worth calling out — it means the child finished its
work and then typed `/end`, which is **not a registered slash command in a
`cc-branch` worktree**. Results are written, the slot still says `running`, and
from your side the branch looks *busy* rather than finished. Message that child
to invoke the `end-conversation` skill via the Skill tool instead.

## Step 2: Write the report

Answer the three questions in order, then lead with the most actionable item.
Concise list; do not paste raw event files or raw scan output.

> **In flight:**
> - `AI_ST-66` — running, 3 commits ahead, clean, last event: status (12m ago)
> - `INFRA-42` — running 2h, **0 commits, no task folder** — stall candidate
>
> **New events for me:** 2 unread
> - `0007-blocker.md` from `INFRA-40` (18m ago, critical)
>
> **Needs you:** `INFRA-40` is blocked on a decision only you can make.
>
> **Reclaimed this pass:** none. `desktop-cc-bootstrap` is done but
> deliberately unmerged — window kept pending your call.

Every line must trace to something the scan printed **this turn**.

## Step 3: Decide reclaim candidates

`Q3` prints a reclaim **shortlist**. It is a shortlist, not a decision, and it
is stale the instant it is printed. Do not kill from it.

A finished child whose branch is **deliberately unmerged** — pending a CEO
decision — **keeps its window**. Unmerged is not a stall.

---

## Step 4: Reclaim, atomically

```bash
# always dry-run first
bash ~/.claude/skills/company-status/scripts/cc-reclaim-window.sh <task-id> [<task-id> ...]

# then, having read the verdict
bash ~/.claude/skills/company-status/scripts/cc-reclaim-window.sh --kill <task-id>
```

The gate is four conditions, **all** of which must hold:

| | Condition | Why it exists |
|---|---|---|
| **C1** | slot status is `completed` / `ended-by-user` / `abandoned` **and** `ended_at` is set | a terminal status with empty `ended_at` means close-out did not finish writing |
| **C2** | worktree clean (`git status --porcelain` empty) | uncommitted work would be destroyed with the window |
| **C3** | branch merged into main (`git merge-base --is-ancestor`) | unmerged work is not finished work |
| **C4** | `session_id` in the worktree's `.cc-mode` matches the slot being checked | worktrees are **reused**; a stale `.cc-mode` points at the wrong session |

Each one caught a real case. C4 is the subtle one: resolving the slot **by
task_id alone** once picked up an abandoned session from earlier the same day.
So in the script C4 is not a check bolted on at the end — it is the *resolver*:
worktree → `.cc-mode` session_id → slot. Other slots sharing the task_id are
printed as explicitly-unused near-misses, so the trap is visible rather than
silent.

### Atomicity is built in, not documented

**On 2026-08-15 a window was killed with its slot still reading `running`.**
The four conditions were checked, correctly — across *two command batches*, and
the slot re-check was skipped in the batch that did the kill. The child was
mid-close-out and its memory delta was lost.

The fix is structural, and it is why this is a script rather than a checklist:

- All four conditions and the `tmux kill-window` happen **in one process**.
- **C1 is evaluated last**, after C2/C3/C4 — everything else is durable state
  that will not change under you; the slot flips the moment the child finishes.
- C1 is then **re-read one more time immediately before the kill**, with
  nothing between the read and the comparison. A change aborts the kill and
  exits 4.
- C1 is read from **the slot's status line**, never from a completion event and
  never from an earlier scan.

You cannot recreate this by running the checks yourself across several Bash
calls. **Do not.** Call the script.

### Addressing

Windows are targeted by name with tmux's exact-match prefix
(`company:=<task-id>`), never by index. Without `=`, a numeric task_id like
`42` would be parsed as window *index* 42 and close an unrelated session.

Exit codes: `0` gate passed · `1` refused · `2` usage · `4` race caught.

### Known limit: a folded worktree cannot pass the gate

C2, C3 and C4 all read the worktree. If a child folds its worktree during
`/end`, the gate can never pass and the script refuses with *"no worktree
found"*. That refusal is deliberate — with the worktree gone there is no way
to confirm the work was clean and merged, and loosening the gate to cover it
would reintroduce exactly the class of failure the four conditions exist to
prevent.

In practice the fold and the window close have been observed happening
together, so this usually leaves no orphan (INFRA-40, 2026-09-03: worktree
folded, window already gone, nothing to reclaim). If you do find an orphaned
window whose worktree is gone, **do not force it** — confirm the branch is
merged from the main repo by hand, then close the window explicitly, and say
in your report that you bypassed the gate and why.

## Step 5: Report the outcome

State what was reclaimed **and what was deliberately kept, with the reason**.
A silent "reclaimed 3 windows" hides the two you refused. Refer to branches by
task ID only.

---

## Validating this skill

The reclaim gate ships with a self-contained regression harness. Run it after
any change to `cc-reclaim-window.sh`:

```bash
bash ~/.claude/skills/company-status/scripts/cc-reclaim-exercise.sh
```

Expected final line: **`ALL 8 CASES PASSED`**. It builds a throwaway git repo,
worktrees, tree directory and its **own** tmux session — it never touches the
real `~/vault` tree or the `company` session. The eight cases are the all-pass
path, each of the four conditions failing independently, the worktree-reuse
decoy, the numeric-task_id index trap, and the gate/kill race. Any other final
line is a real defect, and the failing case names the condition that regressed.

Verified passing 8/8 on 2026-09-03 (tmux 3.4).

**If tmux is genuinely unreachable** the harness says so in its preflight and
exits 2 rather than reporting false failures. Note that a plain
`can't find window: X` is a **live server answering** — the window is simply
gone, which for a finished child is the normal state. Only
`error connecting to /tmp/tmux-*/default (Operation not permitted)` means the
socket itself is blocked. The scan distinguishes these as `no-window` versus
`tmux-unreachable`; do not read the first as a broken tmux.

---

## Spawning children: two `cc-branch` traps

A status pass often ends in spawning work. Both of these have bitten.

**(a) Parent resolution follows cwd.** `cc-branch` walks up from the current
directory for a `.cc-mode` and takes its `session_id` as the child's
`parent_id`. Always invoke it **from command-center**, passing the repo as an
argument — never `cd` into the repo first. A stale repo-root `.cc-mode`
mis-parented two children on 2026-07-29: non-empty but *wrong* parent, attached
to a session that would never see them.

`cc-branch` already warns when the parent resolves empty, or to a session with
no tree slot. **Read that output — do not assume linkage worked.** Then verify:

```bash
grep parent_id <worktree>/.cc-mode      # must equal your session_id
```

Do this after **every** spawn.

**(b) A failed `cc-branch` still spawns.** If the `__cc_*` helpers are not
sourced — a non-interactive shell, for instance — the helper calls fail but the
`tmux new-window` line can still run with an empty `-t`, starting a briefless,
unparented session in whatever tmux session is ambient. `cc-branch` carries a
snapshot guard that aborts before side effects when `__cc_die` is missing, but
the guard checks one helper, not all of them. After any spawn that printed
errors, check for an orphan window and confirm the child's slot exists before
treating the branch as real.

## Autonomous briefs must state the goal

**Every autonomous brief must state the session goal explicitly**, in a form
the child can adopt without asking — e.g. *"Treat the deliverable stated in
this brief as the confirmed session goal; do not stop to ask for
confirmation."*

`session-start` Step 6 solicits a one-sentence goal **and waits**. An
autonomous branch has nobody to answer: `ENPM808-71` sat idle ~20 minutes at
that prompt while its four siblings worked.

Write the goal line unconditionally. Sibling work (INFRA-40) is addressing the
prompting behaviour in `session-start` itself; an explicitly-stated goal is
correct whether or not that lands, so this instruction does not depend on it
and does not need revisiting afterwards.

Pair it with the close-out line, for the same reason:

> *"When done, invoke the `end-conversation` skill directly via the Skill tool.
> Do NOT type `/end` — it is not a registered command in this worktree."*

All five branches on 2026-08-13 hit one or both of these.

## Boundaries

- Read the tree; **do not modify other sessions' slots**. This skill reads
  slots and closes windows. It never writes another session's slot or events.
- Vault writes stay in `~/vault/20-surface/`. `00-core/`, `10-middle/` and
  `40-journal/` are not written here under any circumstance.
- Plane sync and the artifact-gated close-out nudge are the other two
  obligations of a full status pass (doctrine items 3 and 4). They are the
  EA's to perform; this skill does not automate them.
