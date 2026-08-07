---
name: ring-maintenance
description: Manual weekly bookend that maintains the Obsidian vault's rings. Garbage-collects the surface ring (memory index, tree slots, task folders, command-center state) via a read-only subagent, then walks the promotion backlog with the CEO. Invoked with /ring-maintenance from the EA session. Complements end-conversation, which handles per-session hygiene only.
---

# ring-maintenance — weekly ring maintenance

`end-conversation` handles per-session hygiene. This skill handles the
periodic, cross-cutting drift a single session structurally cannot see.
There is no overlap between them.

Run weekly from the EA (command-center) session.

## Checklist (you MUST complete each item, in order)

- [ ] Step 1: Preflight — mode, vault, Obsidian
- [ ] Step 2: Run the scan
- [ ] Step 3: Phase 1 — dispatch the read-only GC subagent
- [ ] Step 4: Phase 1 — execute auto fixes, confirm proposals
- [ ] Step 5: Phase 2 — walk the promotion queue with the CEO
- [ ] Step 6: Write the health report
- [ ] Step 7: Stamp the last-run marker

## Step 1: Preflight

Run:
```bash
dir=$(pwd); while [ "$dir" != / ]; do [ -f "$dir/.cc-mode" ] && grep '^mode=' "$dir/.cc-mode" && break; dir=$(dirname "$dir"); done
[ -d ~/vault ] && echo "vault: ok" || echo "vault: MISSING"
pgrep -x obsidian >/dev/null && echo "obsidian: running" || echo "obsidian: CLOSED"
```

Three gates, each of which must halt the pass:

1. **Mode.** If `mode` is not `command-center`, Phase 2's canon writes are
   unavailable. Say so and ask whether to run Phase 1 only.
2. **Vault.** If missing, abort. Unlike `end-conversation` there is nothing
   to queue — the vault is the entire subject.
3. **Obsidian.** If closed, run the scan and auto-apply the index fixes, but
   **refuse every archive move**. LiveSync (CouchDB) reverts vault deletes
   made while Obsidian is closed, and a move is a delete-plus-create to the
   sync layer — archiving hundreds of slots with Obsidian closed risks
   CouchDB resurrecting all of them. See
   `claude-memory/reference_obsidian_livesync_deletes.md`.

Use `pgrep -x`, never `pgrep -f`. `pgrep -f obsidian` matches the calling
shell's own command line and reports a false positive; see
`claude-memory/feedback_pgrep_substring_match.md`.

## Step 2: Run the scan

Run:
```bash
bash ~/.claude/cc-ring-scan.sh
```

The script is strictly read-only, takes no arguments, and exits 2 with
`FAIL: vault not mounted` on stderr if the vault gate in Step 1 was somehow
missed. Otherwise it prints exactly 13 sections, in this fixed order, to
stdout: `## metrics`, `## auto.index_add`, `## auto.index_drop`,
`## report.no_description`, `## propose.slots`, `## propose.tasks`,
`## auto.promotion_fold`, `## propose.state`, `## propose.markers`,
`## report.dead_links`, `## report.orphans`, `## report.canon_leak`,
`## anomalies`.

`## metrics` is `key=value` lines — keep this output; it is the "before"
half of Step 6's before-→-after table. Every other section is rows of
tab-separated fields, one finding per line, empty when there is nothing to
report.

Default thresholds are `SLOT_AGE_DAYS=14`, `TASK_AGE_DAYS=30`,
`BRIEF_AGE_DAYS=30`, `HEALTH_KEEP=8`. All four are environment overrides on
the same invocation if a one-off pass needs different windows; leave them
unset for the normal weekly run.

Rows report bare filenames or IDs, not full paths. Their base directories,
all under `~/vault/20-surface/`, are: memory files in `claude-memory/`,
tree slots in `company/tree/sessions/`, task folders in `company/tasks/`,
and `state/` is `company/_command-center/state/`. Every source path and
every `_archive/` destination in Step 4 is relative to these.

## Step 3: Phase 1 — dispatch the read-only GC subagent

Dispatch **one** in-process subagent via the Agent tool. Give it the full
scan output from Step 2 and have it classify the findings against the seven
remits below, returning a structured report (metrics / auto / propose /
report-only / anomalies) rather than prose — this is what lets you act on it
deterministically in Step 4. It also keeps the (often long) raw scan output
out of your own context.

**The subagent is read-only and holds no write tools.** Do not grant it
Edit, Write, or a Bash with write access — it must not be able to run `mv`,
`rm`, `mkdir`, or edit any file. The EA is the sole writer: every mutation
this pass makes, including AUTO-tier ones, is executed by the EA in this
session afterward, never by the subagent. This is the load-bearing
invariant of the whole skill: one writer is auditable, a read-only surveyor
cannot cause damage by misreading its remit, and the write boundary is
enforced in exactly one place instead of two.

Seven remits, each mapped to the scanner section(s) that carry its findings
and its action tier:

| # | Remit | Sections | Tier |
|---|---|---|---|
| 1 | Index sync | `auto.index_add`, `auto.index_drop`, `report.no_description` | AUTO |
| 2 | Tree-slot GC | `propose.slots` | PROPOSE |
| 3 | Task-folder archival | `propose.tasks` | PROPOSE |
| 4 | `state/` hygiene | `propose.state` | PROPOSE |
| 5 | Promotion backlog assembly | `auto.promotion_fold`, `propose.markers` | AUTO + PROPOSE |
| 6 | Dead-link / orphan | `report.dead_links`, `report.orphans` | REPORT-ONLY |
| 7 | Canon-leak spot-check | `report.canon_leak` | REPORT-ONLY |

## Step 4: Phase 1 — execute auto fixes, confirm proposals

For each remit, the criterion the scanner already applied and the action
you take on its findings:

1. **Index sync.** `auto.index_add` rows are `<filename><TAB><description>`
   for a memory file with no line in `MEMORY.md` mentioning its basename —
   append `- [file](file) — description` in existing order (the index has
   no sort order and none is imposed). `auto.index_drop` rows are a bare
   `<path>` whose link target no longer exists on disk — drop that line.
   `report.no_description` rows are files missing `description:`
   frontmatter — never auto-add these; nothing synthesizes a description.
   `metrics.memory.separator_legacy` counts `--` vs `—` separator drift;
   it is reported, never rewritten — auto-apply fixes correctness, not
   style.
2. **Tree-slot GC.** `propose.slots` rows are
   `<slot_id><TAB><status><TAB><age_days><TAB><has_events:yes/no>`. The
   scanner has already excluded `running` slots, applied the
   `SLOT_AGE_DAYS` threshold against `ended_at` (falling back to file
   mtime when absent), and diverted any terminal slot that is the
   `parent_id` of a still-`running` slot into `anomalies` instead —
   archiving a live child's parent would silently break its event
   delivery. Present the list; on confirmation, move the slot `.md` **and**
   its `.events/` directory together (when `has_events=yes`) to
   `tree/sessions/_archive/`. Never move one without the other.
3. **Task-folder archival.** `propose.tasks` rows are
   `<task_id><TAB><age_days><TAB><bytes>` — no file modified within
   `TASK_AGE_DAYS` and no `running` slot claims that `task_id`. Present the
   list with bytes; on confirmation, move each folder to `tasks/_archive/`
   and report total bytes reclaimed.
4. **`state/` hygiene.** `propose.state` rows are
   `<filename><TAB><brief|health-report><TAB><age_days>`: `*-brief.md`
   files older than `BRIEF_AGE_DAYS`, and `ring-health-*.md` files beyond
   the most recent `HEALTH_KEEP` (ranked by the `YYYY-MM-DD` in the
   filename, not mtime, since LiveSync can touch mtimes). Never propose
   `promotion-queue.md`, `.ring-maintenance-last-run`, `netmon/`, or this
   run's own outputs — the scanner already excludes them. On confirmation,
   move to `state/_archive/`.
5. **Promotion backlog assembly.** `auto.promotion_fold` rows are a bare
   `<filename>` under `state/promotion-*.md` (excluding `promotion-queue.md`
   itself and anything ending `-brief.md`, which belongs to remit 4
   instead) — fold its entries into `promotion-queue.md`, deduplicating by
   entry text, then archive the original file to `state/_archive/`. This is
   AUTO. `propose.markers` rows are
   `<file><TAB><line><TAB><snippet>` grep hits for a promotion marker in
   `claude-memory/` or `tasks/` — grep is noisy, so each hit is a candidate
   the CEO must confirm before it becomes a `promotion-queue.md` entry;
   never auto-write these.
6. **Dead-link / orphan.** `report.dead_links` rows are
   `<source_file><TAB><link_text><TAB><near_match><TAB><distance>` — the
   scanner has already filtered out every unresolved `[[link]]` except
   near-matches (case-insensitive exact, or Levenshtein distance ≤ 2
   against an existing note basename), because an unresolved link is a
   deliberate future-memory marker by design, not an error. `report.orphans`
   rows are a bare `<basename>` for a memory file no other memory file
   links to. REPORT-ONLY — surface both lists, take no action.
7. **Canon-leak spot-check.** `report.canon_leak` rows are
   `<vault_relative_path><TAB><mtime>` for files under `00-core/`,
   `10-middle/`, or `40-journal/` newer than
   `.ring-maintenance-last-run`. Cross-reference each path against the
   canon-writes log in prior `state/ring-health-*.md` reports (Step 6):
   a path that appears there is an approved Phase 2 write, not a leak.
   Anything left over is unexplained — eyeball it, never treat it as an
   alarm, since LiveSync can also touch mtimes. On the first run (no
   marker yet) this section is empty by construction; that is the
   baseline, not a clean bill of health.

Tier rules, restated for execution:

- **AUTO** — apply without asking: `auto.index_add`, `auto.index_drop`,
  `auto.promotion_fold`.
- **PROPOSE** — present the list, get CEO confirmation, then execute as
  **moves into `_archive/`**: `propose.slots`, `propose.tasks`,
  `propose.state`, `propose.markers`.
- **REPORT-ONLY** — never act: every `report.*` section.
- `## anomalies` is always surfaced to the CEO. Never skip it silently — a
  quiet skip is how a GC pass reports "all clean" while stepping over the
  one real problem.

If Step 1's Obsidian gate reported `CLOSED`, apply the AUTO index edits
only and refuse every PROPOSE move this run — re-run once Obsidian is open
to clear the backlog.

Archive destinations, all three created on first use — none exist on a
fresh vault:

- `tree/sessions/_archive/` — tree-slot GC
- `tasks/_archive/` — task-folder archival
- `state/_archive/` — state/ hygiene, and the originals folded by
  promotion backlog assembly

Nothing is ever hard-deleted, at any tier, anywhere. Every "removal" this
skill performs is a move into an `_archive/` and is recoverable.

## Step 5: Phase 2 — walk the promotion queue with the CEO

**Input:** `promotion-queue.md` as Phase 1 left it — the migrated entries,
plus folded ad-hoc files, plus any marker finds the CEO confirmed in
Step 4.

Four dispositions: **promote-to-canon**, **keep-surface**, **drop**,
**defer**. For each candidate, propose one with a one-line rationale.

**Two gates, not one.** Approving the *disposition* is not approving the
*content*. On `promote`, draft the exact note, show it to the CEO in full,
and propose a path (`10-middle/decisions/`, `areas/`, or `projects/`, keyed
off content type). Only after the CEO approves that specific draft does the
write happen. No "approve all". No batching. The seam opens once per note and
closes behind it.

**Write boundary.**
- `20-surface/**` — free.
- `10-middle/**` — only here, only per-item, only after the CEO has seen the
  exact content and approved that specific item, and only in
  `mode=command-center`.
- `00-core/**` and `40-journal/**` — never. No approval path exists. If a
  candidate belongs in `00-core`, draft to
  `state/canon-drafts-YYYY-MM-DD/<slug>.md` and let the CEO place it. The
  tier with no write path still gets a draft; the CEO performs the last
  step.

**Drop drops the candidate, not the content.** The underlying memory file
stays where it is; the entry itself is preserved in the processed archive,
so even a drop is recoverable.

**Group before proposing.** Merge thematically related candidates into one
note rather than atomizing entries one-to-one. Canon stays curated by
consolidating on the way in; a queue drained one line per note merely
relocates the log.

**Retirement.** Processed entries move out of `promotion-queue.md` into
`state/_archive/promotion-processed-YYYY-MM-DD.md`, stamped with disposition
and, for promotions, the path they landed at.

The pass is **resumable**. The queue is the state; deferred and unreached
entries simply remain. Criterion 4 of a completed pass (Step 6) does not
require the queue to reach zero.

## Step 6: Write the health report

Write `state/ring-health-YYYY-MM-DD.md` with these sections, in order:

1. Metrics — before (Step 2's `## metrics`) → after
2. Auto-applied actions
3. Proposed actions with the CEO's decisions
4. **Canon writes log** — path per note written to `10-middle` this pass
5. Promotion: `processed / deferred / remaining` counts
6. Report-only findings
7. Anomalies

The canon-writes log is load-bearing: it is what next week's canon-leak
check (`report.canon_leak`, remit 7) reads to tell an approved write from a
real leak. Log every `10-middle` write this pass made, with its exact path
— including the case where Step 5 made none, so the section is present but
empty rather than absent.

## Step 7: Stamp the last-run marker

Only after the health report in Step 6 is written:

```bash
date -Iseconds > ~/vault/20-surface/company/_command-center/state/.ring-maintenance-last-run
```

Stamping last means an aborted pass leaves the marker where it was, so the
next run's canon-leak window still covers the gap instead of silently
losing it.

## Special cases

**LiveSync can undo the entire pass.** Obsidian LiveSync (CouchDB) reverts
vault deletes made while Obsidian was closed. A move is a
delete-plus-create to the sync layer, so archiving hundreds of slots with
Obsidian closed risks CouchDB resurrecting all of them. Step 1's Obsidian
gate exists for exactly this: verify Obsidian is running before executing
any move, and refuse every archive step if it is not. Auto-applied index
edits are unaffected — they are in-place writes, not moves. See
`claude-memory/reference_obsidian_livesync_deletes.md`.

**Not the EA session.** The `10-middle` seam in Step 5 opens only when
`.cc-mode` declares `mode=command-center`. Anywhere else, Phase 2's canon
writes are unavailable and the skill says so. The license is contextual,
not ambient.

**First run.** No `.ring-maintenance-last-run` marker exists yet, so the
canon-leak check establishes a baseline and reports nothing. The proposal
list can be large; offer to triage in batches rather than presenting it
whole.

**Concurrent sessions.** Other sessions write slots and tasks while the
pass runs. `running` slots are never eligible, and — the concurrency rule
— **re-stat every file between proposal and execution; skip anything that
changed.** A file that changed in that interval is left alone this run, not
archived.

**Aborted pass.** The marker is unstamped (Step 7 runs last), so canon-leak
coverage is not lost. Index fixes are idempotent. Already-moved archives
stay moved and remain recoverable. The next run resumes; the queue's
remaining entries pick up where Step 5 left off.

**Vault not mounted.** Abort. Unlike `end-conversation` there is nothing to
queue — the vault is the entire subject of this skill.
