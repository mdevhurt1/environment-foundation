---
name: session-start
description: Bookend skill that runs at session front. Verifies launch mode, surfaces relevant vault context for the declared goal, and locks in the session metadata used by end-conversation. Loaded automatically via SessionStart hook; can also be invoked manually with /start to re-orient mid-session.
---

# session-start — front-of-session bookend

This skill makes every session deterministic by establishing four things
before substantive work begins:

1. **Mode** — exploration, build, continue, or bare
2. **Goal** — one sentence, taken from the dispatched brief when there is
   one, asked of the user only when there is not
3. **Context** — relevant vault hits surfaced as compact pointers
4. **Statusline** — reflects mode and goal-slug

## Checklist (you MUST complete each item)

- [ ] Step 1: Detect launch context
- [ ] Step 2: Verify mode against `.cc-mode`
- [ ] Step 3: Write the session's tree slot
- [ ] Step 4: Manager-decides on resume (read unread subtree events)
- [ ] Step 5: Surface relevant vault context
- [ ] Step 6: Establish one-sentence session goal (ask only if not already supplied)
- [ ] Step 7: Remind user about /end and the CTX-WARN trigger

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
| `mode=branched` | cwd is a per-task worktree (`<repo>-branch-<task>`); `parent_id` is set |
| `mode=command-center` | cwd is `~/vault/20-surface/company/_command-center/`; this is the EA / root |
| missing | session was launched bare; treat as exploration but warn user |

If a mode is declared but the sanity check fails (e.g. `mode=build` but
no plan), tell the user clearly and ask whether to abort or proceed.

## Step 3: Write the session's tree slot

Every session writes a slot file to the vault tree topology. This is
how parents discover children and the EA observes the company.

Run **this exact single command** — do not split it into parts:

```bash
bash ~/.claude/cc-tree-slot-write.sh
```

The helper reads `.cc-mode` (walking up from cwd) and writes
`~/vault/20-surface/company/tree/sessions/{session_id}.md` plus its
adjacent `.events/` directory. If `parent_id` is present and the
parent's events directory exists, the helper also appends a `spawned`
event there.

The helper is a no-op (prints a WARN and exits 0) if `.cc-mode` is
missing or has no `session_id` — that covers older sessions predating
Phase 1 and bare launches. Treat any non-zero exit as a real failure
to surface to the user; otherwise echo the helper's output as-is.

## Step 4: Manager-decides on resume

If this session has **children** (other slot files in
`~/vault/20-surface/company/tree/sessions/` whose `parent_id` matches
your own `session_id`), scan **your own** events directory for
unread events and surface them.

Run this exact Bash block:

```bash
mode_file=$(dir=$(pwd); while [ "$dir" != / ]; do [ -f "$dir/.cc-mode" ] && echo "$dir/.cc-mode" && break; dir=$(dirname "$dir"); done)
[ -z "$mode_file" ] && exit 0

my_session_id=$(grep '^session_id=' "$mode_file" | cut -d= -f2-)
[ -z "$my_session_id" ] && exit 0

events_dir=~/vault/20-surface/company/tree/sessions/${my_session_id}.events
[ ! -d "$events_dir" ] && exit 0

marker="$events_dir/.read-up-to"
last_read=0
[ -f "$marker" ] && last_read=$(cat "$marker")

# List unread event files, sorted (filenames are zero-padded so lexical = chronological).
unread=$(find "$events_dir" -maxdepth 1 -name '[0-9]*-*.md' -type f 2>/dev/null | sort | awk -v threshold="$last_read" -F'/' '{
    fname=$NF
    # Extract leading number from filename (e.g., "0007-completion.md" -> 7)
    n=fname; sub(/-.*$/, "", n); gsub(/^0+/, "", n); if (n=="") n="0"
    if (n+0 > threshold+0) print $0
}')

if [ -z "$unread" ]; then
    echo "no unread events"
else
    echo "unread events:"
    while IFS= read -r f; do
        echo "  --- $f ---"
        head -20 "$f"
        echo
    done <<< "$unread"

    # Determine highest event_id present (read or unread); we'll bump marker
    # only after the agent has actually processed them.
    highest=$(find "$events_dir" -maxdepth 1 -name '[0-9]*-*.md' -type f 2>/dev/null \
        | awk -F'/' '{fname=$NF; n=fname; sub(/-.*$/, "", n); gsub(/^0+/, "", n); if (n=="") n="0"; print n+0}' \
        | sort -n | tail -1)
    echo "(after deciding on each event, mark them read with:"
    echo "  echo $highest > '$marker' )"
fi
```

For each unread event, decide one of:

- **Solve** — handle it inline (e.g., the CEO can deal with it now,
  or you take the action yourself). Log a `decision` event in your
  own events dir summarizing what you did.
- **Ignore** — discard. Log a `decision` event with verb=`decision`
  and severity=`info`, explaining why ignored.
- **Escalate** — if you have a parent (look up `parent_id` in your
  `.cc-mode`), write an event of the same severity to the parent's
  events dir; otherwise, surface it to the CEO in the orientation
  output for direct handling.

After processing all unread events, update the `.read-up-to` marker
with the bash one-liner the snippet above printed.

If the session is the root (the EA) and there are unread events for
you, this step is exactly where you compose your status orientation
to the CEO.

If the session has no children and no events, this step is a no-op
and you can move on.

## Step 5: Surface relevant vault context

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

## Step 6: Establish the one-sentence session goal

The goal must be **established**, not necessarily **asked for**. Decide
which branch you are on by evaluating this condition, in order:

**A goal is already available if EITHER:**

1. `.cc-mode` contains a non-empty `goal=` line — check with:
   ```bash
   grep '^goal=' "$mode_file" | cut -d= -f2-
   ```
   (`$mode_file` is the path resolved in Step 2. No such line is written
   today — see "Why the goal is not passed in `.cc-mode`" below — so this
   check normally returns empty. It is here so that if a future dispatcher
   does write one, this skill already honours it.)

2. **OR** the session's first user message already states what the session
   is for — a dispatched brief, a task assignment, a plan reference, or any
   opening message that names the objective. This is the case that actually
   fires today.

### Branch 1 — goal already available (autonomous / briefed session)

**Do NOT ask. Do NOT wait.** Declare the goal back in one sentence and
proceed immediately to Step 7:

> "Goal (from the dispatched brief, not prompted): <one sentence>."

Say explicitly that it came from the brief rather than from a prompt, so a
human reading the transcript later can see the prompt was skipped by design
and not lost.

A branched session has nobody watching its pane. Asking a question there
does not get an answer — it produces a session that idles at a prompt while
still reporting as spawned-and-healthy. Treat "the brief already told me
what to do" as sufficient. If the brief states the objective but is vague on
detail, still do not block: state the goal at the confidence you have, note
the ambiguity, and resolve it as you work.

### Branch 2 — no goal available (interactive human launch)

Ask the user, and wait for the answer:
> "In one sentence, what is this session for?"

Then echo it back as confirmation.

### Both branches

Store the resulting goal for use in:
- The eventual `end-conversation` summary (did we accomplish it?)
- Naming a kept transcript (slug-ified)

### Why the goal is not passed in `.cc-mode`

`cc-branch` deliberately does **not** write a `goal=` line, and should not
be changed to. Two reasons:

1. `cc-branch <task-id> [<repo-path>]` has no goal to write. It receives a
   task **identifier** (`INFRA-40`), not an objective sentence, and launches
   a bare `claude`. The brief arrives afterwards, as the child's first user
   message. Adding a goal parameter would make the caller pass the objective
   twice.
2. `statusline-command.sh` **sources** `.cc-mode` (`. "$dir/.cc-mode"`). A
   goal is a free-text English sentence; an unquoted `goal=fix the parser`
   line makes that source fail with `the: command not found`. The existing
   `__cc_write_mode_file` scrubbing (newlines and `=`) does not address
   spaces, because every other field is a single token.

Reading the first user message costs nothing, needs no signature change and
no new quoting rules, and works for every dispatch path — `cc-branch`,
subagent dispatch, or a human who simply opens with what they want.

## Step 7: Remind user about /end

End with this exact one-liner:
> "Ready. When you wrap up, run `/end` to walk the closing ritual.
>  If you see `CTX-WARN` on the statusline, propose `/end` before continuing
>  substantive work — that means context is at 80% and compaction is near."

## Special cases

**Vault sessions** (cwd is `~/vault/` or under): The rings are two-tier.
`00-core/` and `40-journal/` are closed absolutely — never write there,
regardless of what the user asks; no approval path exists. `10-middle/` is
not written as a matter of course; the sole exception is the
`ring-maintenance` skill's Phase 2, which writes one CEO-approved note at a
time, per item, from the command-center session. State this guardrail
explicitly at the end of Step 6 when in vault context. Reads of all paths
are fine.

**No vault present**: If `~/vault/` doesn't exist, skip Step 3 entirely
and warn the user once: "vault not mounted — context surfacing skipped;
end-conversation imports will queue to `~/.claude/queue/`."

**Subagent dispatch**: If you were dispatched as a subagent (the system
reminder will say so), skip this skill entirely. The parent session
already ran it.
