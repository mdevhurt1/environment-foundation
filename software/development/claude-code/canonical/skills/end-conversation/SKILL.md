---
name: end-conversation
description: Bookend skill that runs at session close. Captures memory deltas, asks whether to keep the transcript, mirrors approved artifacts into the Obsidian vault's surface ring, optionally folds the worktree, prompts for promotion candidates, and records the closing state on the session's Plane issue. Invoke via the Skill tool (slash-command form /end-conversation, not /end). Should also be invoked when the statusline shows CTX-WARN.
---

# end-conversation — close-of-session bookend

This is the closing ritual. It must complete before significant context
loss (compaction, /clear, session exit) or anything memorable from this
session is forfeit.

## Trigger conditions

- The user asks to close the session — by invoking this skill via the Skill
  tool, or with the slash command `/end-conversation`.
- You observe `CTX-WARN` in the statusline (set by `statusline-command.sh`
  when context usage crosses 80%). When you see this marker, **propose
  closing to the user** with a one-line summary of what's at stake. They
  may decline; that's fine. Do not auto-end.

## Checklist (you MUST complete each item, in order)

- [ ] Step 1: Memory delta review
- [ ] Step 2: Specs/plans capture
- [ ] Step 2a: Update the Plane issue (one question, then write)
- [ ] Step 3: Transcript decision
- [ ] Step 4: Memory sync to vault
- [ ] Step 5: Promotion candidates
- [ ] Step 6: Worktree fold (exploration mode only)
- [ ] Step 7: Update the session's tree slot
- [ ] Step 8: Final report

## Step 1: Memory delta review

Diff `~/.claude/projects/-home-mhurt/memory/` against where it stood at
session start. (You can approximate by checking `git log` of that dir if
it's tracked, or by listing files modified in the last hour.)

```bash
find ~/.claude/projects/-home-mhurt/memory/ -type f -newer /tmp/.session-start-marker 2>/dev/null
```

For each new/modified file, summarize the change in one line and ask the
user: keep / edit / discard. Apply their decision.

## Step 2: Specs/plans capture

If new files exist in `<repo>/docs/superpowers/specs/` or `<repo>/docs/
superpowers/plans/` or `~/.claude/plans/`, list them. For each:

1. Confirm the file is committed in its home repo (or commit it now if
   the user agrees).
2. Copy a snapshot to the vault if vault is present:
   ```bash
   mkdir -p ~/vault/20-surface/claude-specs ~/vault/20-surface/claude-plans
   cp <spec-file> ~/vault/20-surface/claude-specs/
   cp <plan-file> ~/vault/20-surface/claude-plans/
   ```

If vault is missing, queue under `~/.claude/queue/specs/` and `~/.claude/
queue/plans/` with a note for the next successful end-conversation run
to flush the queue.

## Step 2a: Update the Plane issue

`session-start` Step 5a said the work *started*. This step is the half that
says how it *ended*, and it is the one that matters: `AI_ST-44`, `INFRA-3` and
`INFRA-30` all describe work that finished with nobody to tell, and sat for
months. A closing bookend that asks "is this done?" converts a 90-day silence
into a 10-second answer.

It runs here — after Step 2 knows what the session produced, before Step 3
starts disposing of artifacts — so the audit line can name a real commit or
path. It is numbered `2a` so the steps below it keep their numbers.

First, see what the board currently thinks:

```bash
sync=~/.claude/cc-plane-sync.sh
[ -f "$sync" ] || sync=~/.claude/skills/../shell/cc-plane-sync.sh
[ -f "$sync" ] && bash "$sync" resolve \
  || echo "plane-sync: helper not installed — skipping Plane sync (run cc-doctor)"
```

If it reports no Plane issue for this session, skip to Step 3 — short ad-hoc
work legitimately has none.

Otherwise **ask exactly one question**, quoting the line the helper printed:

> `INFRA-41` — *Mechanize the Plane/vault division of labour in the session bookends*
> Currently: **In Progress**, `high`.
> Is this **done**, **still in progress**, or **blocked**?

Then write the answer, with a one-line audit note naming the commit SHA or
artifact path this session produced:

```bash
bash "$sync" finish <done|blocked|progress> --note "<what happened> (<sha or path>)"
```

`done` moves the issue to the project's completed state; `blocked` moves it to
`Blocked`; `progress` leaves the state alone. All three post the comment —
that comment is the audit trail that makes a stale issue diagnosable later,
which the current board's issues almost entirely lack. The helper re-fetches
after every write and reports what the server actually holds, because a
rate-limit body (`error_code` 5900) is a 2-key dict that reads as a plausible
result if you trust the write response.

**One question, and only one.** Every step here runs many times a day across
the fleet. If this bookend grows past a single question, sessions will start
skipping the bookend entirely — and the tree slot, the memory sweep and the
vault import all ride on the same skill. That costs far more than a stale
board.

**Never block on this.** The helper warns and exits 0 on any network or auth
failure (the UDM IPS drops inter-VLAN sessions; INFRA-37). A session that
cannot reach Plane still completes its close.

**Autonomous sessions.** A briefed branch with nobody watching its pane cannot
be asked. Answer from what the session actually did — the same standard Step 6
of `session-start` applies — and prefer `progress` over `done` unless the work
is genuinely finished and verified. Never report `done` from a plan's or a
brief's claim that something landed; check the artifact the issue is about.

## Step 3: Transcript decision

Ask: "Keep this transcript in the vault?"

This is a thinking moment, not a checkbox. The honest answer is usually
"no" and that's fine. Push back gently if the user says "yes" by reflex —
remind them surface ring noise dilutes signal.

If yes:
1. Find the transcript path. Claude Code writes them to
   `~/.claude/projects/-home-mhurt/<session-id>.jsonl`.
2. Render to markdown using the helper:
   ```bash
   slug=$(echo "$session_goal" | tr -cs 'A-Za-z0-9' '-' | tr A-Z a-z | sed 's/^-//;s/-$//')
   ~/.claude/skills/end-conversation/render-transcript.sh \
     ~/.claude/projects/-home-mhurt/<session-id>.jsonl \
     ~/vault/20-surface/claude-transcripts/$(date +%Y-%m-%d)-${slug}.md \
     "$session_goal"
   ```

If no: nothing — the JSONL stays in `~/.claude/projects/` (purgeable
when you next clean up).

## Step 4: Memory sync to vault

For each memory file approved in Step 1, copy it into the vault:
```bash
mkdir -p ~/vault/20-surface/claude-memory
cp ~/.claude/projects/-home-mhurt/memory/*.md ~/vault/20-surface/claude-memory/
cp ~/.claude/projects/-home-mhurt/memory/MEMORY.md ~/vault/20-surface/claude-memory/
```

LiveSync handles cross-machine conflict resolution. Memory files are
treated as user-level (not machine-level); refuse to write any
machine-specific facts to memory in the first place.

## Step 5: Promotion candidates

Ask: "Anything from this session deserves promotion to the middle or
core ring?"

If yes, append a one-line entry to the promotion queue:
```bash
mkdir -p ~/vault/20-surface/company/_command-center/state
echo "- $(date +%Y-%m-%d) — <one-line description> (see <pointer>)" \
  >> ~/vault/20-surface/company/_command-center/state/promotion-queue.md
```

The queue lives on the **surface** ring. Appending to it is an unattended,
unreviewed write, which is exactly the kind of write the inner rings do not
accept — so it goes here instead. The `ring-maintenance` skill drains this
queue weekly with the CEO present.

**Never** create or edit notes in `00-core/`, `10-middle/`, or `40-journal/`
from this skill. Promotion into `10-middle` happens only in
`ring-maintenance` Phase 2, per-item, with the CEO approving specific
content. `00-core/` and `40-journal/` are human-only with no approval path.

## Step 6: Worktree fold (exploration mode only)

If `.cc-mode` says `mode=exploration`, prompt:

> "Fold the worktree?
>   m) merge clean changes back to <base-branch>
>   p) open a draft PR
>   k) keep the worktree for later (default)
>   d) discard (DESTRUCTIVE — confirms required)"

Default to **keep**. For `m` and `p`, run the appropriate git/gh commands
and verify success before declaring done. For `d`, require the user to
type the worktree name to confirm.

For `mode=build`: skip this step.

## Step 7: Update the session's tree slot

Update the slot file to reflect that the session has ended, and emit
a completion event to the parent (if any).

Run **this exact single command** — do not split it into parts:

```bash
bash ~/.claude/cc-tree-slot-update.sh
```

The helper sets `status: completed` and `ended_at: <now>` in the
session's slot, and (if `.cc-mode` declares a parent whose events
directory exists) appends a `completion` event there.

The helper is a no-op (prints a WARN and exits 0) if `.cc-mode` is
missing, has no `session_id`, or the slot file was never written.
Treat any non-zero exit as a real failure to surface to the user;
otherwise echo the helper's output as-is.

If the session exits without running this skill (e.g., the terminal is closed),
the slot will remain in `status: running` and no parent event will
fire. This is acceptable for the founding state; future phases may
add a wrapper-side stale-slot reaper.

## Step 8: Final report

One paragraph (max 4 sentences):
- What was learned or accomplished
- What was kept (memory updates, specs, plans, transcript? — name them)
- Where each artifact landed (paths)
- One sentence on what would be a sensible next session, if anything
  obvious

Then exit silently — no further proactive action. The user closes the
session when ready.

## Special cases

**Vault not mounted**: warn loudly and queue all artifacts intended for
the vault to `~/.claude/queue/<subdir>/`. Document in the final report
that artifacts are queued.

**No new memory, no specs/plans, transcript declined**: still run Steps
5-8. The promotion-candidates question and the final report still apply.

**This skill is invoked more than once in a session**: subsequent runs are
no-ops; surface a summary of what was already captured and skip Steps
1-6, including Step 2a — the Plane issue has already been answered, and
asking twice is exactly the friction that makes sessions skip the bookend.
Always do Steps 7-8.
