---
name: end-conversation
description: Bookend skill that runs at session close. Captures memory deltas, mirrors approved specs and plans into the vault's surface ring, records the closing state on the session's Plane issue, decides the transcript, reconciles the memory index, queues promotion candidates, and optionally folds the worktree. Invoke by name (Claude Code slash form /end-conversation, not /end), and in Claude Code when the statusline shows CTX-WARN.
---

# end-conversation — close-of-session bookend

The closing ritual. It must complete before significant context loss
(compaction, clear, session exit) or anything memorable from this session
is forfeit.

Triggers: the operator asks to close, or (Claude Code) you observe
`CTX-WARN` in the statusline (context ≥ 80%) — then **propose** closing
with one line on what's at stake; the operator may decline, never auto-end.

## Checklist (you MUST complete each item, in order)

- [ ] Step 1: Memory delta review
- [ ] Step 1a: Post-rewrite/post-archive corpus sweep (conditional)
- [ ] Step 2: Specs/plans capture
- [ ] Step 3: Update the Plane issue (one question, then write)
- [ ] Step 4: Transcript decision
- [ ] Step 5: Memory index reconciliation
- [ ] Step 6: Promotion candidates
- [ ] Step 7: Worktree fold (only if this session made a worktree)
- [ ] Step 8: Final report

Every vault write this skill makes is under `~/vault/20-surface/`. Run them
as ordinary writes; never reach for a sandbox bypass.

The memory index regenerator used below:

```bash
regen=~/.claude/cc-memory-index-regen.sh   # linked by environment-foundation agents/scripts/install.sh
```

## Step 1: Memory delta review

The memory store is `~/vault/20-surface/claude-memory/`. List what this
session touched, passing the session's start time if you know it:

```bash
bash ~/.agents/skills/end-conversation/memory-delta.sh "<start time, optional>"
```

For each new/modified file, summarize the change in one line and ask:
keep / edit / discard. Apply the decision. (Unattended sessions: decide
yourself against the brief's deliverables and note it in the final report.)

## Step 1a: Post-rewrite/post-archive corpus sweep (conditional)

Runs only when this session **rewrote git history** or **moved/archived
vault content that memories point at**; otherwise skip. Both invalidate
referents across the memory corpus, and only the session that did it knows
(AI_ST-70). Scale the sweep to the event: one grep for a one-folder
archive, the hash sweep for a rewrite:

```bash
# memories citing hashes — check each against the rewritten repo (git cat-file -t)
grep -rlE '\b[0-9a-f]{7,40}\b' ~/vault/20-surface/claude-memory/ --include='*.md'
# memories citing a moved path
grep -rl '<old-path-fragment>' ~/vault/20-surface/claude-memory/ --include='*.md'
```

Correct each hit (prefer a dated scope note over deletion when the lesson
keeps value), then reconcile the index as in Step 5. Too large to finish at
close → write the hit-list to the task folder and name it in the final
report rather than dropping it.

## Step 2: Specs/plans capture

If new files exist in `<repo>/docs/superpowers/specs/`,
`<repo>/docs/superpowers/plans/`, or your runtime's plan directory (Claude
Code: `~/.claude/plans/`): confirm each is committed in its home repo (or
commit now if the operator agrees), then snapshot to
`~/vault/20-surface/claude-specs/` / `claude-plans/` (`mkdir -p` first).
Specs and plans already written in the task folder need no snapshot.

## Step 3: Update the Plane issue

`session-start` Step 4 said the work *started*; this says how it *ended*.
It runs after Step 2 so the comment can name a real commit or path. Use the
`plane-api` skill for every call.

No Plane issue for this session, and Step 2 captured **no** new spec or
plan → skip to Step 4. Normal for ad-hoc work.

No Plane issue, but Step 2 **did** capture a new spec or plan → this work
outlives the session and has no board presence. Ask **one** question: does
this have a Plane issue to link, and which? Answer "no", or no answer →
skip to Step 4 and say so in the final report.

**This is not a second question.** It fires only where the bookend
otherwise asks none: a session with an issue asks its one
done/progress/blocked question and never reaches this branch.

With an issue, **ask exactly one question**, quoting the issue line: is
this **done**, **still in progress**, or **blocked**? Then post a comment
`<what happened> (<sha or path>)` on the issue, and set the state: `done` →
the project's `completed` state; `blocked` → add the project's `blocked`
label (there is no Blocked state; keep the existing labels, since `labels`
replaces the list) and leave the state unchanged; `progress` → state
unchanged. All three post the comment — the audit trail. Re-read the issue
after writing and report what the server actually holds.

**One question, and only one** — a bookend that grows past that gets
skipped. **Never block** — on any network/auth failure, warn and continue.
**Unattended sessions** never ask: decide from what the session actually
did; prefer `progress` over `done` unless the work is verified finished —
check the artifact, not the brief's claim.

## Step 4: Transcript decision

Ask: "Keep this transcript in the vault?" — a thinking moment, not a
checkbox; the honest answer is usually "no" (surface-ring noise dilutes
signal).

If yes and the runtime is Claude Code — the transcript is the newest JSONL
under the encoded **full cwd** (a worktree session's is NOT under
`-home-mhurt`). Claude Code maps every character outside `[A-Za-z0-9-]` to `-`,
so `_` and `.` go too (`AI_ST-100` -> `AI-ST-100`; checked against all 169
project dirs 2026-10-01). The dir name starts with `-`, so keep the path prefix:

Nothing exports the goal to a shell, so fill in the first line yourself:

```bash
session_goal='<the one-sentence goal from session-start Step 5>'
transcript=$(ls -t ~/.claude/projects/"$(pwd | sed 's/[^A-Za-z0-9-]/-/g')"/*.jsonl 2>/dev/null | head -1)
slug=$(echo "$session_goal" | tr -cs 'A-Za-z0-9' '-' | tr A-Z a-z | sed 's/^-//;s/-$//')
[ -n "$transcript" ] && [ -n "$slug" ] || { echo "no transcript or empty goal: not rendered"; exit 1; }
mkdir -p ~/vault/20-surface/claude-transcripts
bash ~/.agents/skills/end-conversation/render-transcript.sh \
  "$transcript" \
  ~/vault/20-surface/claude-transcripts/$(date +%Y-%m-%d)-${slug}.md \
  "$session_goal"
```

The renderer reads Claude Code's JSONL schema only. Other runtimes: say
there is no renderer for this runtime and skip. If no: nothing — the
runtime keeps its own session log.

## Step 5: Memory index reconciliation

If Step 1 or 1a added, renamed, re-described or removed any memory file:

```bash
regen=~/.claude/cc-memory-index-regen.sh   # set here too: each block may run in a fresh shell
if [ -f "$regen" ]; then bash "$regen" && bash "$regen" --check
else echo "regen script not installed: MEMORY.md left untouched"; fi
```

The regenerator writes `MEMORY.md` under a lock, so concurrent sessions
cannot clobber each other, and `--check` asserts the per-file invariant
both ways (every memory file has exactly one line, every line has a file).
New lines take their hook from the file's frontmatter `description:` —
fixing a description IS fixing the index. Without the script, do **not**
edit `MEMORY.md`: a hand edit bypasses the lock. Name in the final report
each memory file this session added, renamed or removed, and hand the
operator the command that restores the regenerator
(`bash ~/environment-foundation/software/development/agents/scripts/install.sh`)
followed by the Step 5 block. Never hand-write essays into `MEMORY.md`;
every session reads it.

## Step 6: Promotion candidates

Ask: "Anything from this session deserves promotion to the middle or core
ring?" If yes, append one line to the promotion queue:

```bash
mkdir -p ~/vault/20-surface/company/_command-center/state
echo "- $(date +%Y-%m-%d) — <one-line description> (see <pointer>)" \
  >> ~/vault/20-surface/company/_command-center/state/promotion-queue.md
```

The queue lives on the surface ring because this is an unattended write;
`ring-maintenance` walks it with the operator. **Never** write `00-core/`,
`10-middle/`, or `40-journal/` from this skill or any other: agents have no
write path to them. `ring-maintenance` drafts promoted notes on the surface
and the operator places them.

## Step 7: Worktree fold (only if this session made a worktree)

Skip unless this session created the git worktree it is working in
(`git rev-parse --git-dir` differs from `--git-common-dir`, and you made
it). Then prompt:

> "Fold the worktree?
>   m) merge clean changes back to <base-branch>
>   p) open a draft PR
>   k) keep the worktree for later (default)
>   d) discard (DESTRUCTIVE — confirmation required)"

Default **keep**. Merging and opening a PR are outward actions AGENTS.md
reserves for an explicit ask, and the answer here is that ask. For `m`/`p`,
verify the git commands succeeded before declaring done. For `d`, require
the operator to type the worktree name.

## Step 8: Final report

One paragraph (max 4 sentences): what was learned or accomplished; what
was kept (memory, specs, plans, transcript — name them); where each
artifact landed (paths); one sentence on a sensible next session, if
obvious. Then stop — the operator closes the session when ready.

## Special cases

**Vault not mounted**: warn loudly, skip every vault write, and list in the
final report what would have been captured so the operator can capture it
by hand.

**Nothing to capture**: still run Steps 6–8.

**Invoked more than once in a session**: later runs are no-ops — summarize
what was already captured and skip Steps 1–7 (asking the Plane question
twice is the friction that makes sessions skip the bookend). Always do
Step 8.
