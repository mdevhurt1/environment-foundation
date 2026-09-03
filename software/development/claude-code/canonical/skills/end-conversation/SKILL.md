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
- [ ] Step 1a: Post-rewrite/post-archive corpus sweep (conditional)
- [ ] Step 2: Specs/plans capture
- [ ] Step 2a: Update the Plane issue (one question, then write)
- [ ] Step 3: Transcript decision
- [ ] Step 4: Memory index reconciliation
- [ ] Step 5: Promotion candidates
- [ ] Step 6: Worktree fold (exploration mode only)
- [ ] Step 7: Update the session's tree slot
- [ ] Step 8: Final report

## Step 1: Memory delta review

The memory store is `~/vault/20-surface/claude-memory/` (the auto-memory
location override in CLAUDE.md — NOT the default
`~/.claude/projects/<enc>/memory/`, which is empty everywhere). The delta
reference is this session's own start time, which `.cc-mode` already
records — no marker file exists or is needed. (Repaired 2026-09-03,
INFRA-48: the previous version of this step diffed a nonexistent directory
against a marker nothing wrote, and had silently found nothing since the
location override landed.)

```bash
mode_file=$(dir=$(pwd); while [ "$dir" != / ]; do [ -f "$dir/.cc-mode" ] && echo "$dir/.cc-mode" && break; dir=$(dirname "$dir"); done)
started_at=$(grep '^started_at=' "$mode_file" 2>/dev/null | cut -d= -f2-)
if [ -n "$started_at" ]; then
  find ~/vault/20-surface/claude-memory/ -name '*.md' ! -name MEMORY.md -newermt "$started_at"
else
  echo "(no .cc-mode started_at — bare session; falling back to last 6 hours)"
  find ~/vault/20-surface/claude-memory/ -name '*.md' ! -name MEMORY.md -mmin -360
fi
```

For each new/modified file, summarize the change in one line and ask the
user: keep / edit / discard. Apply their decision. (Autonomous sessions:
decide yourself against the brief's deliverables; note the decision in the
final report instead of asking.)

## Step 1a: Post-rewrite/post-archive corpus sweep (conditional)

Runs only when this session did either of these things; otherwise skip:

- **rewrote git history** in any repo (rebase/filter-repo/force-move of
  published commits), or
- **moved or archived vault content that memories point at** (e.g. a
  `tasks/<id>/` folder into `tasks/_archive/`).

Both events invalidate referents recorded in the memory corpus — every
memory citing a pre-rewrite hash or a pre-move path now misinforms its
reader. The 2026-08-20 sentinel history rewrite and the task-folder archive
sweep were never followed by such a pass, and by 2026-09-03 41% of sampled
checkable reference memories carried a dead or false referent (AI_ST-70).
This step exists so that cannot silently happen again. It lives HERE, not
in ring-maintenance, because the session that performed the rewrite is the
only actor that knows it happened and what the old referents looked like —
a weekly GC discovers the contamination up to a week late, after other
sessions have already recalled the false claims.

Sweep mechanics (scale to the event — a one-folder archive needs one grep;
a history rewrite needs the hash sweep):

```bash
# hashes: list memories citing any 7-40 hex string, then check each cited
# hash against the rewritten repo with `git cat-file -t <hash>`
grep -rlnE '\b[0-9a-f]{7,40}\b' ~/vault/20-surface/claude-memory/ --include='*.md' -l
# paths: memories citing the moved path
grep -rln '<old-path-fragment>' ~/vault/20-surface/claude-memory/ --include='*.md'
```

Correct each hit (prefer a dated scope note over deletion when the lesson
has residual value), then regenerate the index:
`bash ~/.claude/cc-memory-index-regen.sh`. If the sweep is too large to
finish at close, record the debt: write the grep hit-list to the session's
task folder and emit a `blocker`-severity event to your parent rather than
dropping it.

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
1. Find the transcript path. Claude Code encodes the session's **full cwd**
   into the project directory (`/` → `-`), so a worktree session's
   transcript is NOT under `-home-mhurt`. (Repaired 2026-09-03, INFRA-48:
   the hardcoded `-home-mhurt` path only ever matched sessions launched
   from `$HOME`.) The current session's transcript is the newest JSONL in
   the encoded-cwd directory:
   ```bash
   transcript=$(ls -t ~/.claude/projects/"$(pwd | tr '/' '-')"/*.jsonl 2>/dev/null | head -1)
   echo "$transcript"
   ```
2. Render to markdown using the helper:
   ```bash
   slug=$(echo "$session_goal" | tr -cs 'A-Za-z0-9' '-' | tr A-Z a-z | sed 's/^-//;s/-$//')
   ~/.claude/skills/end-conversation/render-transcript.sh \
     "$transcript" \
     ~/vault/20-surface/claude-transcripts/$(date +%Y-%m-%d)-${slug}.md \
     "$session_goal"
   ```

If no: nothing — the JSONL stays in `~/.claude/projects/` (purgeable
when you next clean up).

## Step 4: Memory index reconciliation

(Repaired 2026-09-03, INFRA-48: this step used to `cp` from the empty
default memory location into the vault — a structural no-op, since the
location override means memories are written straight to the vault. There
is nothing to sync; what needs keeping true is the INDEX.)

If Step 1 found any new, renamed, or re-described memory files, regenerate
the compacted index so every memory has a current one-line entry:

```bash
bash ~/.claude/cc-memory-index-regen.sh
```

The regenerator derives each line from the memory file's frontmatter
`description:`, so fixing a description IS fixing the index. Never
hand-write essays into MEMORY.md — it is injected into every session by the
`cc-memory-inject.sh` SessionStart hook, and its size is a per-session
context tax (AI_ST-69 compacted it 65K → ~14K tokens).

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
