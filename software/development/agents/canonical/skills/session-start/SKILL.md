---
name: session-start
description: Bookend skill that runs at session front. Detects the launch context, makes sure the memory index has been read, surfaces vault context, reconciles the session's Plane issue, and locks in the session goal used by end-conversation. Invoke by name (Claude Code slash form /session-start, not /start) at the start of a session or to re-orient mid-session.
---

# session-start — front-of-session bookend

Establishes context, memory, goal and board state before substantive work
begins.

## Checklist (you MUST complete each item)

- [ ] Step 1: Detect launch context
- [ ] Step 2: Make sure the memory index has been read
- [ ] Step 3: Surface relevant vault context
- [ ] Step 4: Reconcile the Plane issue (read-mostly; one write)
- [ ] Step 5: Establish one-sentence session goal (ask only if not already supplied)
- [ ] Step 6: Remind the operator how to close the session

Steps 1–4 are probes — batch their commands into as few shell calls as
possible and narrate one line per step, so the ritual stays cheap.

## Step 1: Detect launch context

```bash
pwd
git rev-parse --show-toplevel 2>/dev/null || echo "(not in a repo)"
for f in AGENTS.md CLAUDE.md; do test -f "$f" && echo "found per-project $f"; done
```

A per-project instruction file adds to the global AGENTS.md; read it if
your runtime has not already loaded it.

## Step 2: Make sure the memory index has been read

AGENTS.md requires reading `~/vault/20-surface/claude-memory/MEMORY.md` at
session start (Claude Code's SessionStart hook prints a pointer to it with
the current line count; the index itself is not injected). If you have
already read it this session, do not read it again. If you have not, read
it in full now — if your read shows fewer memory lines than the pointer
named, keep reading.

## Step 3: Surface relevant vault context

Skip if `~/vault/` does not exist.

```bash
repo_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
grep -rl --include='*.md' "$repo_name" ~/vault/20-surface/claude-memory/ 2>/dev/null | head -20
ls ~/vault/10-middle/projects/"$repo_name"/ 2>/dev/null
```

Surface hits as one-line pointers (path + frontmatter description) — do
not paste contents. No hits → say "no prior vault context for this repo".

## Step 4: Reconcile the Plane issue

Tells the board the work *started* (end-conversation Step 3 says how it
ended). Resolve the issue from, in order: an issue named in the operator's
first message or brief, a `plane.md` in the task folder
(`~/vault/20-surface/company/tasks/<task_id>/`), or a task_id shaped like
an issue (e.g. `AI_ST-12`). None → "no Plane issue" is normal for ad-hoc
work; move on.

With an issue: read it using the `plane-api` skill. If its state is in the
`backlog` or `unstarted` group, move it to the project's `In Progress`
state — **that is the only write**. Report the issue line (identifier,
title, state before → after); it informs Step 5. **Never block here**: on
any network, auth, or lookup failure, warn in one line and continue.

## Step 5: Establish the one-sentence session goal

The goal must be **established**, not necessarily **asked for**. It is
already available if the first message states the objective — a brief,
task assignment, or plan reference.

### Branch 1 — goal already available (briefed session)

**Do NOT ask. Do NOT wait.** Declare it and proceed to Step 6:

> "Goal (from the brief, not prompted): <one sentence>."

Say it came from the brief, so a transcript reader sees the prompt was
skipped by design. A session nobody is watching idles forever on a
question. Vague brief → state the goal at the confidence you have, note
the ambiguity, resolve it as you work.

### Branch 2 — no goal available (interactive launch)

Ask "In one sentence, what is this session for?", wait, echo it back.

Either way, keep the goal for the end-conversation summary and transcript
naming.

## Step 6: Remind the operator how to close the session

End with this one-liner:
> "Ready. When you wrap up, invoke the `end-conversation` skill (Claude
>  Code: `/end-conversation`) to walk the closing ritual. In Claude Code, if
>  you see `CTX-WARN` on the statusline, propose closing before continuing
>  substantive work — context is at 80% and compaction is near."

**Do not write `/end`.** Slash commands resolve by exact skill name:
`/end-conversation` works, `/end` returns `Unknown command`.

## Special cases

**Vault sessions** (cwd under `~/vault/`): restate the ring guardrail at
the end of Step 5 — agents write only under `20-surface/`; `00-core/`,
`10-middle/` and `40-journal/` are never written, no approval path exists
(promotion candidates are drafted on the surface and the operator places
them; see `ring-maintenance`). Reads everywhere are fine.

**No vault present**: skip Steps 2–3 and warn once: "vault not mounted —
memory and context surfacing skipped; end-conversation cannot capture to
the vault this session."

**Subagent dispatch**: if you were dispatched as a subagent, skip this
skill entirely — the parent already ran it.
