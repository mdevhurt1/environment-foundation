---
name: ring-maintenance
description: Manual weekly bookend that maintains the Obsidian vault's rings. Checks the memory index, reports stale task folders and board drift, then walks the promotion queue with the operator, drafting each approved promotion on the surface ring for the operator to place. Invoke by name (Claude Code slash form /ring-maintenance). Complements end-conversation, which handles per-session hygiene only.
---

# ring-maintenance — weekly ring maintenance

`end-conversation` handles per-session hygiene. This skill handles the
periodic, cross-cutting drift a single session structurally cannot see.
There is no overlap between them. Run it weekly, with the operator present.

**Write boundary, restated from AGENTS.md.** Agents write only under
`~/vault/20-surface/`. `00-core/`, `10-middle/` and `40-journal/` are never
written by an agent — no approval path exists. So this skill *drafts*
promotions on the surface and the operator places them; anything outside
`20-surface/` (including `~/vault/90-archive/`) is a command handed to the
operator, never run.

Paths below: `state/` is `~/vault/20-surface/company/_command-center/state/`.

## Checklist (you MUST complete each item, in order)

- [ ] Step 1: Preflight — vault, Obsidian
- [ ] Step 2: Memory index check
- [ ] Step 3: Stale task folders (report + operator commands)
- [ ] Step 4: Board health (read-only)
- [ ] Step 5: Walk the promotion queue with the operator
- [ ] Step 6: Canon-leak spot-check (read-only)
- [ ] Step 7: Write the health report
- [ ] Step 8: Stamp the last-run marker

## Step 1: Preflight

```bash
[ -d ~/vault ] && echo "vault: ok" || echo "vault: MISSING"
pgrep -x obsidian >/dev/null && echo "obsidian: running" || echo "obsidian: CLOSED"
```

- **Vault** missing → abort; the vault is the entire subject.
- **Obsidian** closed → note it. LiveSync (CouchDB) reverts vault deletes
  made while Obsidian is closed, and a move is a delete-plus-create to the
  sync layer, so any move the operator runs from Step 3 must wait for
  Obsidian to be open. See `claude-memory/reference_obsidian_livesync_deletes.md`.

Use `pgrep -x`, never `pgrep -f`: `pgrep -f obsidian` matches the calling
shell's own command line (`claude-memory/feedback_pgrep_substring_match.md`).

## Step 2: Memory index check

```bash
regen=~/.claude/cc-memory-index-regen.sh   # linked by environment-foundation agents/scripts/install.sh
if [ -f "$regen" ]; then bash "$regen" --check || { bash "$regen" && bash "$regen" --check; }
else echo "regen script not installed: check MEMORY.md against claude-memory/ per file, by hand"; fi
```

`--check` asserts the per-file invariant both ways (every memory file has
exactly one `MEMORY.md` line, every line has a file) and writes nothing.
On offenders, regenerate (an in-place, locked write) and check again.
Report offenders and the outcome. A file missing frontmatter `description:`
is never given a synthesized hook: `--check` lists it as an offender, and
regen indexes it as `(no description)` with a warning, replacing that
placeholder once the file has a description. Report each such file.

## Step 3: Stale task folders

Read-only listing of task folders with no file changed in 30 days:

```bash
cd ~/vault/20-surface/company/tasks
for d in */; do
  [ -z "$(find "$d" -type f -mtime -30 -print -quit)" ] && printf '%s\t%s\n' "${d%/}" "$(du -sh "$d" | cut -f1)"
done
```

mtime is not activity (`claude-memory/feedback_task_folder_mtime_is_not_activity.md`):
check each candidate for an open Plane issue or a live reference before
proposing it. Present the confirmed list with sizes. Archival is a move
into `~/vault/90-archive/company-tasks/`, outside the agent write ring, so
hand the operator the exact commands, one `mv` per folder, never a glob,
to run with Obsidian open:

```bash
mv ~/vault/20-surface/company/tasks/<task_id> ~/vault/90-archive/company-tasks/
```

Nothing is ever hard-deleted.

## Step 4: Board health (read-only)

Using the `plane-api` skill, list open issues per project and report:

1. **No active cycle** — a project with live work and no cycle spanning
   today has stopped tracking time.
2. **Started but quiet** — a `started` issue not updated in 7 days; a
   `backlog`/`unstarted` issue not updated in 21.

**Strictly read-only.** Never PATCH, close, create or comment here — a
staleness detector that closes things is how a backlog gets cancelled
instead of triaged. If the same warning stands week after week, the answer
is a triage pass, not a bigger checker.

## Step 5: Walk the promotion queue with the operator

**Input:** `state/promotion-queue.md`. Before proposing, cross-check each
entry against `state/_archive/promotion-processed-*.md`: a hit means it was
already walked — do not re-propose it (re-queueing a walked candidate can
silently reverse a ruling).

Four dispositions: **promote**, **keep-surface**, **drop**, **defer**. For
each candidate, propose one with a one-line rationale.

**Group before proposing.** Merge thematically related candidates into one
note rather than atomizing entries one-to-one; canon stays curated by
consolidating on the way in.

**Two gates, not one.** Approving the *disposition* is not approving the
*content*. On `promote`, draft the exact note, show it to the operator in
full, and propose its destination (`10-middle/decisions/`, `areas/`, or
`projects/`; or `00-core/`). After the operator approves that draft, write
it to `state/canon-drafts-YYYY-MM-DD/<slug>.md` with the proposed
destination in its frontmatter. **The operator moves it into place;** the
agent never writes the destination ring. No "approve all", no batching.

**Drop drops the candidate, not the content.** The underlying memory file
stays where it is.

**Retirement.** Processed entries move out of `promotion-queue.md` into
`state/_archive/promotion-processed-YYYY-MM-DD.md`, stamped with
disposition and, for promotions, the draft path and proposed destination.

**Stamp the source section (AI_ST-94).** When a processed entry carries a
`from <file>:<line>` source pointer under `20-surface/`, edit that heading
in place: `## Promotion candidates` becomes
`## Promotion candidates [WALKED YYYY-MM-DD]`. One heading per processed
entry, for every disposition. Source not found (archived or renamed) →
skip the stamp; the archive cross-check catches it next time.

The walk is **resumable**: the queue is the state, and deferred or
unreached entries simply remain. A completed pass does not require the
queue to reach zero.

## Step 6: Canon-leak spot-check (read-only)

```bash
marker=~/vault/20-surface/company/_command-center/state/.ring-maintenance-last-run
[ -f "$marker" ] && find ~/vault/00-core ~/vault/10-middle ~/vault/40-journal -type f -newer "$marker" 2>/dev/null
```

Every hit should be a note the operator placed from a draft (cross-check
the drafts log in prior `state/ring-health-*.md` reports) or the
operator's own writing. Report anything unexplained; never treat it as an
alarm, since LiveSync can touch mtimes. No marker yet → this run is the
baseline and reports nothing.

## Step 7: Write the health report

Write `state/ring-health-YYYY-MM-DD.md` with these sections, in order:

1. Memory index — offenders found, regenerated or not, final `--check` result
2. Stale task folders — the list, and the commands handed to the operator
3. Board health — one line per project plus findings
4. Promotion — `processed / deferred / remaining` counts
5. **Drafts log** — path and proposed destination per draft written this
   pass (present but empty when there were none). Next week's Step 6 reads
   it to tell a placed draft from an unexplained canon write.
6. Canon-leak findings
7. Anything anomalous — always surfaced, never silently skipped

## Step 8: Stamp the last-run marker

Only after the health report in Step 7 is written:

```bash
date -Iseconds > ~/vault/20-surface/company/_command-center/state/.ring-maintenance-last-run
```

Stamping last means an aborted pass leaves the marker where it was, so the
next run's canon-leak window still covers the gap.

## Special cases

**Concurrent sessions.** Other sessions write memories and task folders
while the pass runs. Re-check any file between proposal and action and skip
anything that changed. The index regenerator takes a lock, so Step 2 is
safe to run alongside other sessions.

**Aborted pass.** The marker is unstamped, so canon-leak coverage is not
lost; index regeneration is idempotent; the queue resumes where Step 5
left off.
