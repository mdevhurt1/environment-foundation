---
name: writing-plans
description: Turn a spec into an exhaustive, ordered task plan a branched session can execute. Use when a spec exists at ~/vault/20-surface/company/tasks/<task_id>/spec.md and the work is large enough that the executor shouldn't make decomposition decisions mid-flight. Stops at plan-approved; does not dispatch execution.
---

# writing-plans — turn an approved spec into an executable plan

A short structured pass that ends with an approved plan at
`~/vault/20-surface/company/tasks/<task_id>/plan.md` and a single
`plan-written` event in this session's events directory. The plan is
the input to a branched executor; treat it as a subagent execution
script, not a design doc.

**Hard rule: do not write code, scaffold files, or invoke execution
skills until the plan is approved.**

## Checklist (you MUST complete each item, in order)

- [ ] Step 1: Load context
- [ ] Step 2: Scope check
- [ ] Step 3: Propose file structure
- [ ] Step 4: Propose task decomposition
- [ ] Step 5: Write the plan and self-review
- [ ] Step 6: Approval and exit

## Step 1: Load context

Read `.cc-mode` walking up from cwd. Derive `task_id` per
`~/.claude/CLAUDE.md`: a Plane issue ID if `.cc-mode` carries one,
otherwise the `slug`. Extract `session_id`. Read the spec at
`$HOME/vault/20-surface/company/tasks/$task_id/spec.md`.

```bash
mode_file=$(d="$PWD"; while [ "$d" != / ]; do [ -f "$d/.cc-mode" ] && echo "$d/.cc-mode" && break; d=$(dirname "$d"); done)
[ -z "$mode_file" ] && { echo "no .cc-mode — cannot derive task_id; abort"; exit 1; }
slug=$(grep '^slug=' "$mode_file" | cut -d= -f2-)
session_id=$(grep '^session_id=' "$mode_file" | cut -d= -f2-)
plane_issue=$( { grep '^plane_issue=' "$mode_file" || true; } | cut -d= -f2-)
task_id="${plane_issue:-$slug}"
task_dir="$HOME/vault/20-surface/company/tasks/$task_id"
spec_path="$task_dir/spec.md"
[ ! -f "$spec_path" ] && { echo "no spec at $spec_path — run brainstorming first"; exit 1; }
mkdir -p "$task_dir"
echo "task_id=$task_id  session_id=$session_id  spec=$spec_path"
```

If `$task_dir/plan.md` already exists, ask the operator: **amend**,
**replace**, or **cancel**. Do not overwrite silently.

Skim recent commits (`git log --oneline -10`) and
`~/vault/10-middle/projects/<repo>/_about.md` if it exists. No deep
exploration — task-bounded only. The point is enough context to
decompose the spec, not to map the codebase.

## Step 2: Scope check

Read the spec end-to-end. If it describes multiple independent
subsystems, abort:

> "this spec covers multiple subsystems; re-run brainstorming to
> decompose into sub-specs, then plan each separately"

Single-subsystem only. Brainstorming enforces this on the front end;
this is defense in depth.

## Step 3: Propose file structure

Map out which files will be created or modified and what each one
owns. Present as a compact bulleted list with one-line responsibilities
per file:

```
- Create: path/to/new/file.ext — <one-line responsibility>
- Modify: path/to/existing.ext — <what changes here>
- Test: tests/path/to/test.ext — <what this covers>
```

Decomposition decisions get locked in here. Operator approves before
continuing.

Design units with clear boundaries. Files that change together should
live together. In existing codebases, follow established patterns; do
not unilaterally restructure unless the spec calls for it.

## Step 4: Propose task decomposition

List the tasks as titles + one-line scope per task + the files each
touches. Order matters: dependencies between tasks should be visible
in the order. One commit per task, not per step.

Example shape:

```
Task 1: <Component> — <one-line scope>
  files: path/a.ext, tests/path/a_test.ext
Task 2: <Component> — <one-line scope>
  files: path/b.ext (depends on Task 1)
```

Operator approves before continuing. Renames or reorders happen here,
not in Step 5.

## Step 5: Write the plan and self-review

Write to `$task_dir/plan.md` using the artifact template below.
Substitute today's date (`date +%Y-%m-%d`) for `YYYY-MM-DD`. Expand
each task to its full step content per the step shapes. Pick the
shape per task based on whether the deliverable is code.

Self-review inline immediately after writing:

1. **Spec coverage** — point to a task for each requirement in the
   spec. Add a task for anything missing.
2. **Placeholder scan** — search for `TBD`, `TODO`, `<...>`,
   "implement later", "add error handling", "similar to Task N",
   prose-only steps without a command or code block. Fix in place.
3. **Type / method / path consistency** — names used in later tasks
   match what earlier tasks define. `clearLayers()` in Task 3 and
   `clearFullLayers()` in Task 7 is a bug, not a stylistic variant.

Fix in place. No re-review loop.

## Step 6: Approval and exit

Tell the operator the plan is written, give the path, ask them to
review:

> "Plan written to `<path>`. Review it and let me know if you want
> changes before we exit."

On change request: edit, re-review inline, ask again.

On approval: append exactly one `plan-written` event to this session's
events directory, print a one-line confirmation with the plan path,
and exit. Do not invoke `subagent-driven-development` or
`executing-plans`. Do not write code. The CEO decides what comes next.

```bash
events_dir="$HOME/vault/20-surface/company/tree/sessions/${session_id}.events"
mkdir -p "$events_dir"
next=$(printf "%04d" $(( $(find "$events_dir" -maxdepth 1 -name '[0-9]*-*.md' 2>/dev/null | wc -l) + 1 )))
cat > "$events_dir/${next}-plan-written.md" <<EOF
---
event_id: $next
verb: plan-written
severity: info
ts: $(date -Iseconds)
plan_path: $task_dir/plan.md
spec_path: $task_dir/spec.md
---

Implementation plan written and approved.

<one-line summary — the plan's title>
EOF
echo "plan: $task_dir/plan.md"
echo "event: $events_dir/${next}-plan-written.md"
```

Replace `<one-line summary — the plan's title>` with the actual title
before running the heredoc.

## Plan artifact template

```markdown
---
created: YYYY-MM-DD
source: spec at ~/vault/20-surface/company/tasks/<task_id>/spec.md
type: implementation-plan
---

# <Title> Implementation Plan

**Goal:** <one sentence>

**Architecture:** <2-3 sentences on approach>

> Execute task-by-task in a branched session via `cc-branch`. Each task = one commit.

## File Structure

- Create: `path/to/new/file.ext` — <one-line responsibility>
- Modify: `path/to/existing.ext` — <what changes here>
- Test: `tests/path/to/test.ext` — <what this covers>

## Task 1: <Component>

**Files:**
- Create: `exact/path/to/file.py`
- Modify: `exact/path/to/existing.py:123-145`
- Test: `tests/exact/path/to/test.py`

[step block — see step shapes below]

## Task 2: ...
```

## Step shapes

The planner picks per task based on whether the deliverable is code.
One commit per task, not per step.

### Code-task step shape (5 steps)

````markdown
- [ ] **Step 1: Write the failing test**

```python
def test_specific_behavior():
    result = function(input)
    assert result == expected
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/path/test.py::test_name -v`
Expected: FAIL with "function not defined"

- [ ] **Step 3: Write minimal implementation**

```python
def function(input):
    return expected
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/path/test.py::test_name -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add tests/path/test.py src/path/file.py
git commit -m "feat: add specific feature"
```
````

### Non-code-task step shape (3 steps)

````markdown
- [ ] **Step 1: Make the change**

<exact file edit, exact file content, or exact command. No prose-only steps.>

- [ ] **Step 2: Verify**

Run: `<exact verification command>`
Expected: `<expected output>`

Examples by work type:
- skill port: `grep -c '^## ' SKILL.md` against expected section count, or read-back of a key line
- doc work: render to terminal and confirm a specific phrase
- config rollout: dry-run command + expected stdout

- [ ] **Step 3: Commit**

```bash
git add path/to/changed/file
git commit -m "<type>(<scope>): <subject>"
```
````

## Hard rules for step content

- **Exact file paths always.** No "the relevant file."
- **Complete code in every code step.** No "implement the function"
  without showing it.
- **Exact commands with expected output.** No "run the tests."
- **No placeholders.** `TBD`, `TODO`, `<...>`, "implement later", "add
  error handling", "similar to Task N" — these are plan failures.
- **Type / method / path consistency across tasks.** `clearLayers()`
  in Task 3 and `clearFullLayers()` in Task 7 is a bug, not a
  stylistic variant.

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
  operator may use if the plan-writing session gets long enough to
  warrant progress tracking. The skill does not mandate it.
- **No announce-at-start ritual.** No "I'm using the writing-plans
  skill..." line. Invocation context already conveys this.
- **Trust the operator.** The hard rule above is the only gate. No
  HARD-GATE walls, no anti-pattern paragraphs arguing against
  positions the operator did not take.
