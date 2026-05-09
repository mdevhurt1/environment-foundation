---
name: end-conversation
description: Bookend skill that runs at session close. Captures memory deltas, asks whether to keep the transcript, mirrors approved artifacts into the Obsidian vault's surface ring, optionally folds the worktree, and prompts for promotion candidates. Invoked manually via /end. Should also be invoked when the statusline shows CTX-WARN.
---

# end-conversation — close-of-session bookend

This is the closing ritual. It must complete before significant context
loss (compaction, /clear, session exit) or anything memorable from this
session is forfeit.

## Trigger conditions

- User runs `/end`.
- You observe `CTX-WARN` in the statusline (set by `statusline-command.sh`
  when context usage crosses 80%). When you see this marker, **propose
  `/end` to the user** with a one-line summary of what's at stake. They
  may decline; that's fine. Do not auto-end.

## Checklist (you MUST complete each item, in order)

- [ ] Step 1: Memory delta review
- [ ] Step 2: Specs/plans capture
- [ ] Step 3: Transcript decision
- [ ] Step 4: Memory sync to vault
- [ ] Step 5: Promotion candidates
- [ ] Step 6: Worktree fold (exploration mode only)
- [ ] Step 7: Final report

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

If yes, append a one-line entry to the review queue:
```bash
echo "- $(date +%Y-%m-%d) — <one-line description> (see <pointer>)" \
  >> ~/vault/10-middle/decisions/_review-queue.md
```

**Never** create or edit notes in `00-core/`, `10-middle/`, or `40-
journal/` directly. The queue is the only writable seam between you and
the inner rings; promotion happens in the user's weekly review, not now.

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

## Step 7: Final report

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
5-7. The promotion-candidates question and the final report still apply.

**User runs /end multiple times in one session**: subsequent runs are
no-ops; surface a summary of what was already captured and skip Steps
1-6. Always do Step 7.
