---
name: session-start
description: Bookend skill that runs at session front. Verifies launch mode, surfaces relevant vault context for the declared goal, and locks in the session metadata used by end-conversation. Loaded automatically via SessionStart hook; can also be invoked manually with /start to re-orient mid-session.
---

# session-start — front-of-session bookend

This skill makes every session deterministic by establishing four things
before substantive work begins:

1. **Mode** — exploration, build, continue, or bare
2. **Goal** — one sentence stated by the user
3. **Context** — relevant vault hits surfaced as compact pointers
4. **Statusline** — reflects mode and goal-slug

## Checklist (you MUST complete each item)

- [ ] Step 1: Detect launch context
- [ ] Step 2: Verify mode against `.cc-mode`
- [ ] Step 3: Write the session's tree slot
- [ ] Step 4: Surface relevant vault context
- [ ] Step 5: Solicit one-sentence session goal
- [ ] Step 6: Remind user about /end and the CTX-WARN trigger

## Step 1: Detect launch context

Run:
```bash
pwd
git rev-parse --show-toplevel 2>/dev/null || echo "(not in a repo)"
test -f CLAUDE.md && echo "found per-project CLAUDE.md"
test -f .cc-mode && cat .cc-mode || echo "(no .cc-mode in cwd)"
```

You now know: the cwd, the repo (if any), whether project instructions
are loaded, and the launch mode (if any).

## Step 2: Verify mode against `.cc-mode`

Walk upward from cwd looking for `.cc-mode`. If found, source it:
```bash
mode_file=$(while [ "$PWD" != / ]; do [ -f .cc-mode ] && echo "$PWD/.cc-mode" && break; cd ..; done)
```

Then validate consistency:

| `.cc-mode` says | Sanity check |
|---|---|
| `mode=exploration` | cwd should be a worktree (`git worktree list` shows it) |
| `mode=build` | cwd is the main worktree; a plan exists in `~/.claude/plans/` or in `<repo>/docs/superpowers/plans/` |
| missing | session was launched bare; treat as exploration but warn user |

If a mode is declared but the sanity check fails (e.g. `mode=build` but
no plan), tell the user clearly and ask whether to abort or proceed.

## Step 3: Write the session's tree slot

Every session writes a slot file to the vault tree topology. This is
how parents discover children and the EA observes the company.

Read the session's identity fields from `.cc-mode`. If the file has
no `session_id` (older session predating Phase 1, or a bare launch),
log a warning and skip the rest of this step.

Run this exact Bash block to write the slot:

```bash
mode_file=$(dir=$(pwd); while [ "$dir" != / ]; do [ -f "$dir/.cc-mode" ] && echo "$dir/.cc-mode" && break; dir=$(dirname "$dir"); done)
[ -z "$mode_file" ] && { echo "no .cc-mode found — skipping tree slot"; exit 0; }

session_id=$(grep '^session_id=' "$mode_file" | cut -d= -f2-)
[ -z "$session_id" ] && { echo "WARN: .cc-mode has no session_id; skipping tree slot"; exit 0; }

parent_id=$(grep '^parent_id=' "$mode_file" | cut -d= -f2-)
slug=$(grep '^slug=' "$mode_file" | cut -d= -f2-)
mode=$(grep '^mode=' "$mode_file" | cut -d= -f2-)
started_at=$(grep '^started_at=' "$mode_file" | cut -d= -f2-)
parent_repo=$(grep '^parent_repo=' "$mode_file" | cut -d= -f2-)

# task_id: prefer the session goal slug; if a Plane issue is in play, the
# user can update this later via the skill's tree-slot edit affordance.
task_id="$slug"

slot=~/vault/20-surface/company/tree/sessions/${session_id}.md
mkdir -p "$(dirname "$slot")"
mkdir -p "${slot%.md}.events"

cat > "$slot" <<EOF
---
session_id: $session_id
parent_id: $parent_id
task_id: $task_id
slug: $slug
mode: $mode
status: running
started_at: $started_at
ended_at:
worktree: $(dirname "$mode_file")
parent_repo: $parent_repo
---

# Session $session_id

Started: $started_at
Mode: $mode
EOF

echo "tree slot: $slot"
```

If `parent_id` is non-empty, also append a `spawned` event to the
**parent's** events directory:

```bash
if [ -n "$parent_id" ]; then
    parent_events=~/vault/20-surface/company/tree/sessions/${parent_id}.events
    if [ -d "$parent_events" ]; then
        # Find next event number
        next=$(printf "%04d" $(( $(find "$parent_events" -name '*.md' 2>/dev/null | wc -l) + 1 )))
        cat > "$parent_events/${next}-spawned.md" <<EOF
---
event_id: $next
session_id: $parent_id
emitted_at: $(date -Iseconds)
verb: spawned
severity: info
---

# Child session spawned: $session_id

slug=$slug mode=$mode
EOF
    fi
fi
```

If the parent's events directory does not exist (e.g., the parent
predated Phase 1), do not create it; the child still tracks its own
slot.

## Step 4: Surface relevant vault context

Skip if `~/vault/` does not exist (queue this step for after vault setup).

Otherwise, search for hits relevant to the working repo or area:
```bash
repo_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
rg -l --max-count 1 "$repo_name" ~/vault/20-surface/claude-memory/ 2>/dev/null
ls ~/vault/10-middle/projects/$repo_name/ 2>/dev/null
```

If hits exist, surface as one-line pointers (do not paste contents):
```
Relevant vault context:
  ~/vault/20-surface/claude-memory/<file>.md (memory: <one-line desc from frontmatter>)
  ~/vault/10-middle/projects/<repo>/_about.md (project notes)
```

If no hits, say "no prior vault context for this repo" — that's useful info too.

## Step 5: Solicit one-sentence session goal

Ask the user:
> "In one sentence, what is this session for?"

Wait for the answer. Then echo it back as confirmation and store it
mentally for use in:
- The eventual `end-conversation` summary (did we accomplish it?)
- Naming a kept transcript (slug-ified)

## Step 6: Remind user about /end

End with this exact one-liner:
> "Ready. When you wrap up, run `/end` to walk the closing ritual.
>  If you see `CTX-WARN` on the statusline, propose `/end` before continuing
>  substantive work — that means context is at 80% and compaction is near."

## Special cases

**Vault sessions** (cwd is `~/vault/` or under): The model is forbidden
from writing to `00-core/`, `10-middle/`, or `40-journal/` regardless
of what the user asks. State this guardrail explicitly at the end of
Step 6 when in vault context. Reads of all paths are fine.

**No vault present**: If `~/vault/` doesn't exist, skip Step 3 entirely
and warn the user once: "vault not mounted — context surfacing skipped;
end-conversation imports will queue to `~/.claude/queue/`."

**Subagent dispatch**: If you were dispatched as a subagent (the system
reminder will say so), skip this skill entirely. The parent session
already ran it.
