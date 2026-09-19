---
name: session-start
description: Bookend skill that runs at session front. Verifies launch mode, surfaces vault context, reconciles the session's Plane issue, and locks in the session goal used by end-conversation. Loaded via the SessionStart hook; invoke via the Skill tool (slash form /session-start, not /start) to re-orient mid-session.
---

# session-start — front-of-session bookend

Establishes mode, goal, vault context, and tree presence before substantive
work begins.

## Checklist (you MUST complete each item)

- [ ] Step 1: Detect launch context
- [ ] Step 2: Verify mode against `.cc-mode`
- [ ] Step 3: Write the session's tree slot
- [ ] Step 4: Manager-decides on resume (read unread subtree events)
- [ ] Step 5: Surface relevant vault context
- [ ] Step 5a: Reconcile the Plane issue (read-mostly; one write)
- [ ] Step 6: Establish one-sentence session goal (ask only if not already supplied)
- [ ] Step 7: Remind user how to close the session, and the CTX-WARN trigger

Steps 1–5a are probes and helpers — batch their commands into as few Bash
calls as possible and narrate one line per step, so the ritual's tool
rounds stay cheap.

## Step 1: Detect launch context

```bash
pwd
git rev-parse --show-toplevel 2>/dev/null || echo "(not in a repo)"
test -f CLAUDE.md && echo "found per-project CLAUDE.md"
test -f .cc-mode && cat .cc-mode || echo "(no .cc-mode in cwd)"
```

## Step 2: Verify mode against `.cc-mode`

Walk upward from cwd for the nearest `.cc-mode`:
```bash
mode_file=$(while [ "$PWD" != / ]; do [ -f .cc-mode ] && echo "$PWD/.cc-mode" && break; cd ..; done)
```

Sanity-check the declared mode: `exploration` → cwd is a worktree;
`build` → main worktree and a plan exists in `~/.claude/plans/` or
`<repo>/docs/superpowers/plans/`; `branched` → per-task worktree
(`<repo>-branch-<task>`) with `parent_id` set; `command-center` → cwd is
`~/vault/20-surface/company/_command-center/` (the EA / root); missing →
bare launch: treat as exploration and warn. If a declared mode fails its
check, say so and ask whether to abort or proceed.

## Step 3: Write the session's tree slot

Run **this exact single command** — do not split it into parts:

```bash
bash ~/.claude/cc-tree-slot-write.sh
```

It writes `~/vault/20-surface/company/tree/sessions/{session_id}.md` plus
its `.events/` dir and appends a `spawned` event to the parent when one
exists. Missing `.cc-mode`/`session_id` → WARN + exit 0 (fine — bare
launches). Surface any non-zero exit; otherwise echo its output as-is.

## Step 4: Manager-decides on resume

```bash
bash ~/.claude/skills/session-start/events-scan.sh
```

The helper lists events newer than the `.read-up-to` marker; only sessions
with children normally have any ("no unread events" or silence → move on).
For each unread event decide: **Solve** inline, **Ignore**, or
**Escalate** (same-severity event to your parent's events dir; the root/EA
instead surfaces it to the CEO — that orientation is where the EA composes
its status report). Solve and Ignore each log a `decision` event in your
own events dir (Ignore at severity=`info`, explaining why); then bump the
marker with the one-liner the helper printed.

## Step 5: Surface relevant vault context

Skip if `~/vault/` does not exist.

```bash
repo_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
rg -l --max-count 1 "$repo_name" ~/vault/20-surface/claude-memory/ 2>/dev/null
ls ~/vault/10-middle/projects/$repo_name/ 2>/dev/null
```

Surface hits as one-line pointers (path + frontmatter description) — do
not paste contents. No hits → say "no prior vault context for this repo".

## Step 5a: Reconcile the Plane issue

Tells the board the work *started* (end-conversation Step 2a says how it
ended). Numbered `5a` because Steps 6 and 7 are referenced from outside
this file and keep their numbers.

```bash
sync=~/.claude/cc-plane-sync.sh
[ -f "$sync" ] || sync=~/.claude/skills/../shell/cc-plane-sync.sh
[ -f "$sync" ] && bash "$sync" start \
  || echo "plane-sync: helper not installed — skipping Plane sync (run cc-doctor)"
```

The helper resolves the issue (`--issue` → `.cc-mode` `plane_issue=` →
`<task folder>/plane.md` → issue-shaped slug) and moves a backlog/unstarted
issue to started — **nothing else**. Echo its output as-is; its issue line
informs Step 6. **Never block here**: it warns and exits 0 on any network,
auth, or lookup failure, and "no Plane issue" is normal for ad-hoc work. A
non-zero exit is a usage error worth surfacing.

## Step 6: Establish the one-sentence session goal

The goal must be **established**, not necessarily **asked for**. It is
already available if `.cc-mode` has a non-empty `goal=` line (none is
written today, but honour one) OR the first user message states the
objective — a dispatched brief, task assignment, or plan reference (the
case that fires today).

### Branch 1 — goal already available (autonomous / briefed session)

**Do NOT ask. Do NOT wait.** Declare it and proceed to Step 7:

> "Goal (from the dispatched brief, not prompted): <one sentence>."

Say it came from the brief, so a transcript reader sees the prompt was
skipped by design. A branched session has nobody watching its pane — a
question there idles forever while reporting healthy. Vague brief → state
the goal at the confidence you have, note the ambiguity, resolve it as you
work.

### Branch 2 — no goal available (interactive human launch)

Ask "In one sentence, what is this session for?", wait, echo it back.

Either way, keep the goal for the end-conversation summary and transcript
naming. (Design note: `cc-branch` deliberately passes no goal via
`.cc-mode` — the brief already carries it, and a free-text sentence would
break the mode file's single-token field contract; INFRA-40/45.)

## Step 7: Remind user how to close the session

End with this exact one-liner:
> "Ready. When you wrap up, invoke the `end-conversation` skill via the Skill
>  tool (as a slash command it is `/end-conversation`) to walk the closing
>  ritual. If you see `CTX-WARN` on the statusline, propose closing before
>  continuing substantive work — that means context is at 80% and compaction
>  is near."

**Do not write `/end`.** Slash commands resolve by exact skill name:
`/end-conversation` works, `/end` returns `Unknown command` (verified
2026-09-03, v2.1.236). Prefer the Skill-tool form in anything an
autonomous session reads.

## Special cases

**Vault sessions** (cwd under `~/vault/`): restate the ring guardrail at
the end of Step 6 — `00-core/` and `40-journal/` are human-only, no
approval path; `10-middle/` is written only by `ring-maintenance` Phase 2,
one CEO-approved note at a time. Reads everywhere are fine.

**No vault present**: skip Step 3 and warn once: "vault not mounted —
context surfacing skipped; end-conversation imports will queue to
`~/.claude/queue/`."

**Subagent dispatch**: if you were dispatched as a subagent (the system
reminder will say so), skip this skill entirely — the parent already ran it.
