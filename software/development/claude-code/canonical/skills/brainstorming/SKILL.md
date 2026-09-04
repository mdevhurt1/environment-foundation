---
name: brainstorming
description: Turn an idea into a written spec through a short structured dialogue. Use before any creative work — new features, new components, modified behavior. Stops at spec-approved; does not invoke writing-plans.
---

# brainstorming — turn an idea into a written spec

A short structured dialogue that ends with an approved spec at
`~/vault/20-surface/company/tasks/<task_id>/spec.md` and a single
`spec-written` event in this session's events directory.

**Hard rule: do not write code, scaffold files, or invoke implementation
skills until the spec is approved.**

## Checklist (you MUST complete each item, in order)

- [ ] Step 1: Explore context
- [ ] Step 2: Ask clarifying questions
- [ ] Step 3: Propose 2-3 approaches
- [ ] Step 4: Present design sections
- [ ] Step 5: Write spec and self-review
- [ ] Step 6: Approval and exit

## Step 1: Explore context

Read `.cc-mode` walking up from cwd. Derive `task_id` per
`~/.claude/CLAUDE.md`: a Plane issue ID if `.cc-mode` carries one,
otherwise the `slug`. Extract `session_id`. Ensure the task directory
exists.

```bash
mode_file=$(d="$PWD"; while [ "$d" != / ]; do [ -f "$d/.cc-mode" ] && echo "$d/.cc-mode" && break; d=$(dirname "$d"); done)
[ -z "$mode_file" ] && { echo "no .cc-mode — cannot derive task_id; abort"; exit 1; }
slug=$(grep '^slug=' "$mode_file" | cut -d= -f2-)
session_id=$(grep '^session_id=' "$mode_file" | cut -d= -f2-)
plane_issue=$( { grep '^plane_issue=' "$mode_file" || true; } | cut -d= -f2-)
task_id="${plane_issue:-$slug}"
task_dir="$HOME/vault/20-surface/company/tasks/$task_id"
mkdir -p "$task_dir"
echo "task_id=$task_id  session_id=$session_id  task_dir=$task_dir"
```

If `$task_dir/spec.md` already exists, ask the operator: **amend**,
**replace**, or **cancel**. Do not overwrite silently.

Skim recent commits (`git log --oneline -10`) and
`~/vault/10-middle/projects/<repo>/_about.md` if it exists. No deep
exploration — task-bounded only. The point is enough context to ask
intelligent questions, not to map the codebase.

## Step 2: Ask clarifying questions

One at a time. Prefer `AskUserQuestion` (2-4 options, one marked
`(Recommended)`) over open-ended prose. Open-ended only when the
choice space is genuinely unbounded.

First check scope: if the request describes multiple independent
subsystems, flag and decompose before refining details. Help the
operator pick the first sub-project; the rest get their own brainstorms.

Question budget: aim for under 6. If you reach 7, you are refining
when you should be proposing — move to Step 3.

## Step 3: Propose 2-3 approaches

Lead with the recommended one. One-line tradeoff per alternative. Wait
for the operator to pick. If they invent a fourth, take it.

## Step 4: Present design sections

Each section scaled to its complexity — a few sentences for the simple
parts, up to ~300 words for the nuanced parts. Get explicit approval
after each section before moving on. Don't pad. Don't manufacture
symmetry between sections.

Typical sections: problem statement, the design itself (subsections as
needed), open questions, scope fence. Topic dictates structure; no
fixed order.

## Step 5: Write spec and self-review

Write to `$task_dir/spec.md` using the template below. Substitute
today's date (`date +%Y-%m-%d`) for `YYYY-MM-DD`.

Self-review inline immediately after writing:

1. **Placeholders** — any `TBD`, `TODO`, `<...>`, or vague phrasing.
2. **Contradictions** — sections that disagree with each other.
3. **Scope drift** — content that belongs in a different spec.
4. **Ambiguity** — requirements with two plausible readings.

Fix in place. No re-review loop.

## Step 6: Approval and exit

Tell the operator the spec is written, give the path, ask them to
review:

> "Spec written to `<path>`. Review it and let me know if you want
> changes before we exit the brainstorm."

On change request: edit, re-review inline, ask again.

On approval: append exactly one `spec-written` event to this session's
events directory, then print a one-line confirmation and exit. Do not
invoke `writing-plans`. Do not write code. The CEO decides what comes
next.

Emit it with the stamping helper — never hand-author the file (AI_ST-65).
The helper stamps `emitted_at` from the clock and names the event
`max(epoch, highest-existing-number + 1)`, which is what keeps the
parent's `.read-up-to` cursor monotonic. The sequential `NNNN-` name and
hand-typed `ts:` this step used to write did neither: a `NNNN-` event
landing in a directory that already holds an epoch-named one compares
below the marker and is unread forever.

```bash
emit=~/.claude/skills/../shell/cc-event-emit.sh
[ -f "$emit" ] || { echo "cc-event-emit.sh not found — run cc-doctor; do NOT hand-write the event"; exit 1; }
# --to-session and --session-id are the SAME id here: the event is
# self-addressed (it lands in this session's own events dir) and this
# session is its emitter. Pass --session-id explicitly rather than letting
# the helper fall back to $CC_SESSION_ID — Step 1 already read the
# authoritative value out of .cc-mode, and an ambient variable can belong
# to a different session than the spec does.
bash "$emit" \
  --to-session "$session_id" --session-id "$session_id" \
  --verb spec-written --severity info \
  --title "spec approved: <the spec's title>" \
  --body "$(cat <<EOF
Spec written and approved: $task_dir/spec.md
<one line — what the spec decides>
EOF
)"
rc=$?
# Do NOT let the confirmation echo mask a failed emit: the spec would be on
# disk while the parent never learns it exists, which reads as "still
# brainstorming" from outside.
if [ "$rc" -ne 0 ]; then
  echo "spec-written event NOT emitted (cc-event-emit.sh exit $rc) — the spec is written but the tree will not show it"
  exit "$rc"
fi
echo "spec: $task_dir/spec.md"
```

Replace both `<...>` placeholders with the real title and decision line
before running this. The helper prints the path of the event it wrote.

If it exits 4 (`events dir does not exist`), the session's tree slot was
never written — the `session-start` bookend did not run. Say so and run
`bash ~/.claude/cc-tree-slot-write.sh`; do not `mkdir` the events
directory, because a missing one means the address is wrong.

## Spec template

```markdown
---
created: YYYY-MM-DD
source: <one line: who or what triggered it>
type: <feature | workflow-improvement | refactor | research | ...>
---

# <Title>

<one-paragraph problem statement>

## Why
<the constraint or pain that earned this work>

## What to do
<the design itself — subsections as needed>

## Open questions
<things deferred to the implementer or the next session>

## What this is NOT
<scope fence — included only when ambiguity exists>
```

`## What this is NOT` is optional; include only when scope ambiguity
would otherwise leak. Other headers are the convention. No `(n/a)`
placeholders. Topic-specific subheadings live under `## What to do`
when prose alone would be hard to skim.

## Voice and prose conventions

- **ASCII only.** No emoji, no smart quotes, no decorative unicode.
  Em-dash used sparingly.
- **Terse and declarative.** State the rule or the action. No
  "Let me...", "I'll go ahead and...", "Great question!", "I think we
  should...". No restating the operator's request. No performative
  reassurance.
- **Address the operator as "you" or by role** (CEO, EA). No "the
  user", no "the AI assistant".
- **Multiple choice over open-ended.** Default to `AskUserQuestion`
  with 2-4 options and a `(Recommended)` marker. Open-ended only
  when the choice space is genuinely unbounded.
- **No TaskCreate per checklist item.** TaskCreate is a tool the
  operator may use if the brainstorm gets long enough to warrant
  progress tracking. The skill does not mandate it.
- **Trust the operator.** The hard rule above is the only gate. No
  HARD-GATE walls, no anti-pattern paragraphs arguing against
  positions the operator did not take.
