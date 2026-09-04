---
name: end-conversation
description: Bookend skill that runs at session close. Captures memory deltas, decides the transcript, mirrors approved artifacts into the vault's surface ring, optionally folds the worktree, and records the closing state on the session's Plane issue. Invoke via the Skill tool (slash form /end-conversation, not /end), and when the statusline shows CTX-WARN.
---

# end-conversation — close-of-session bookend

The closing ritual. It must complete before significant context loss
(compaction, /clear, session exit) or anything memorable from this session
is forfeit.

Triggers: the user asks to close, or you observe `CTX-WARN` in the
statusline (context ≥ 80%) — then **propose** closing with one line on
what's at stake; the user may decline, never auto-end.

## Checklist (you MUST complete each item, in order)

- [ ] Step 1: Memory delta review
- [ ] Step 1a: Post-rewrite/post-archive corpus sweep (conditional)
- [ ] Step 2: Specs/plans capture
- [ ] Step 2a: Update the Plane issue (one question, then write)
- [ ] Step 3: Transcript decision
- [ ] Step 4: Memory index reconciliation
- [ ] Step 5: Promotion candidates
- [ ] Step 6: Worktree fold (exploration mode only)
- [ ] Step 7: Update the session's tree slot
- [ ] Step 8: Final report

Sandbox note (AI_ST-64, extended by INFRA-54): every vault path steps 1–5
write — `~/vault/20-surface/claude-{memory,transcripts,specs,plans}/`, the
promotion-queue file, and **this session's own**
`~/vault/20-surface/company/tasks/<task_id>/` — is inside the sandbox
`allowWrite` carveout. Run the writes as ordinary Bash; never reach for a
sandbox bypass. The task-folder entry is per session: a sibling's task
folder and the `tasks/` parent itself stay read-only, so a write there
failing is the carveout working, not a bug to route around.

## Step 1: Memory delta review

The memory store is `~/vault/20-surface/claude-memory/` (the location
override — the default `~/.claude/projects/<enc>/memory/` is empty
everywhere). List what this session touched:

```bash
bash ~/.claude/skills/end-conversation/memory-delta.sh
```

(The helper diffs against `.cc-mode` `started_at`; bare sessions fall back
to the last 6 hours.)

For each new/modified file, summarize the change in one line and ask:
keep / edit / discard. Apply the decision. (Autonomous sessions: decide
yourself against the brief's deliverables and note it in the final report.)

## Step 1a: Post-rewrite/post-archive corpus sweep (conditional)

Runs only when this session **rewrote git history** or **moved/archived
vault content that memories point at**; otherwise skip. Both invalidate
referents across the memory corpus, and only the session that did it knows
— a weekly GC finds the damage a week late (AI_ST-70). Scale the sweep to
the event: one grep for a one-folder archive, the hash sweep for a rewrite:

```bash
# memories citing hashes — check each against the rewritten repo (git cat-file -t)
grep -rlnE '\b[0-9a-f]{7,40}\b' ~/vault/20-surface/claude-memory/ --include='*.md' -l
# memories citing a moved path
grep -rln '<old-path-fragment>' ~/vault/20-surface/claude-memory/ --include='*.md'
```

Correct each hit (prefer a dated scope note over deletion when the lesson
keeps value), then `bash ~/.claude/cc-memory-index-regen.sh`. Too large to
finish at close → write the hit-list to the task folder and emit a
`blocker` event to your parent rather than dropping it.

## Step 2: Specs/plans capture

If new files exist in `<repo>/docs/superpowers/specs/`,
`<repo>/docs/superpowers/plans/`, or `~/.claude/plans/`: confirm each is
committed in its home repo (or commit now if the user agrees), then
snapshot to `~/vault/20-surface/claude-specs/` / `claude-plans/`
(`mkdir -p` first). Vault missing → queue under `~/.claude/queue/specs/`
and `queue/plans/` with a note for the next run to flush.

## Step 2a: Update the Plane issue

`session-start` Step 5a said the work *started*; this half says how it
*ended*. It runs after Step 2 so the audit line can name a real commit or
path, and is numbered `2a` so later steps keep their numbers.

```bash
sync=~/.claude/cc-plane-sync.sh
[ -f "$sync" ] || sync=~/.claude/skills/../shell/cc-plane-sync.sh
[ -f "$sync" ] && bash "$sync" resolve \
  || echo "plane-sync: helper not installed — skipping Plane sync (run cc-doctor)"
```

No Plane issue reported → skip to Step 3 (normal for ad-hoc work).
Otherwise **ask exactly one question**, quoting the issue line the helper
printed: is this **done**, **still in progress**, or **blocked**? Then:

```bash
bash "$sync" finish <done|blocked|progress> --note "<what happened> (<sha or path>)"
```

`done` → completed state; `blocked` → Blocked; `progress` → state
unchanged. All three post the comment — the audit trail. The helper
re-fetches after every write and reports what the server actually holds.

**One question, and only one** — a bookend that grows past that gets
skipped, and everything else rides on the same skill. **Never block** —
the helper warns and exits 0 on any network/auth failure. **Autonomous
sessions**: decide from what the session actually did; prefer `progress`
over `done` unless the work is verified finished — check the artifact, not
the brief's claim.

## Step 3: Transcript decision

Ask: "Keep this transcript in the vault?" — a thinking moment, not a
checkbox; the honest answer is usually "no" (surface-ring noise dilutes
signal). If yes — the transcript is the newest JSONL under the encoded
**full cwd** (a worktree session's is NOT under `-home-mhurt`):

```bash
transcript=$(ls -t ~/.claude/projects/"$(pwd | tr '/' '-')"/*.jsonl 2>/dev/null | head -1)
slug=$(echo "$session_goal" | tr -cs 'A-Za-z0-9' '-' | tr A-Z a-z | sed 's/^-//;s/-$//')
~/.claude/skills/end-conversation/render-transcript.sh \
  "$transcript" \
  ~/vault/20-surface/claude-transcripts/$(date +%Y-%m-%d)-${slug}.md \
  "$session_goal"
```

If no: nothing — the JSONL stays in `~/.claude/projects/`.

## Step 4: Memory index reconciliation

If Step 1 found any new, renamed, or re-described memory files:

```bash
bash ~/.claude/cc-memory-index-regen.sh
```

The regenerator derives each line from the file's frontmatter
`description:` — fixing a description IS fixing the index. Never
hand-write essays into MEMORY.md; it is injected into every session
(AI_ST-69). Memories are user-level, not machine-level: don't write
machine-specific facts in the first place; LiveSync handles cross-machine
conflicts.

## Step 5: Promotion candidates

Ask: "Anything from this session deserves promotion to the middle or core
ring?" If yes, append one line to the promotion queue:

```bash
mkdir -p ~/vault/20-surface/company/_command-center/state
echo "- $(date +%Y-%m-%d) — <one-line description> (see <pointer>)" \
  >> ~/vault/20-surface/company/_command-center/state/promotion-queue.md
```

The queue lives on the **surface** ring precisely because this is an
unattended write; `ring-maintenance` drains it weekly with the CEO.
**Never** write `00-core/`, `10-middle/`, or `40-journal/` from this
skill. `00-core/` and `40-journal/` are human-only with no approval path;
promotion into `10-middle` happens only in `ring-maintenance` Phase 2,
per-item, with CEO approval.

## Step 6: Worktree fold (exploration mode only)

If `.cc-mode` says `mode=exploration`, prompt:

> "Fold the worktree?
>   m) merge clean changes back to <base-branch>
>   p) open a draft PR
>   k) keep the worktree for later (default)
>   d) discard (DESTRUCTIVE — confirms required)"

Default **keep**. For `m`/`p`, verify the git/gh commands succeeded before
declaring done. For `d`, require the user to type the worktree name.
`mode=build` → skip.

## Step 7: Update the session's tree slot

Run **this exact single command** — do not split it into parts:

```bash
bash ~/.claude/cc-tree-slot-update.sh
```

It sets `status: completed` and `ended_at` in the slot and appends a
`completion` event to the parent when one exists. Missing
`.cc-mode`/`session_id`/slot → WARN + exit 0 (fine). Surface any non-zero
exit; otherwise echo its output as-is.

## Step 8: Final report

One paragraph (max 4 sentences): what was learned or accomplished; what
was kept (memory, specs, plans, transcript — name them); where each
artifact landed (paths); one sentence on a sensible next session, if
obvious. Then exit silently — the user closes the session when ready.

## Special cases

**Vault not mounted**: warn loudly, queue vault-bound artifacts to
`~/.claude/queue/<subdir>/`, say so in the final report.

**Nothing to capture**: still run Steps 5–8.

**Invoked more than once in a session**: subsequent runs are no-ops —
summarize what was already captured and skip Steps 1–6 including 2a
(asking the Plane question twice is the friction that makes sessions skip
the bookend). Always do Steps 7–8.
