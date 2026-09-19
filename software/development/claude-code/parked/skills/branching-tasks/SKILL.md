---
name: branching-tasks
description: EA-only. Use when spawning a branched session with cc-branch (task-id, repo-path, parent linkage from cwd), sending an autonomous first-message brief via tmux paste-buffer, or teleporting into a branch with cc-teleport. Migrated from the command-center CLAUDE.md by /doctor on 2026-09-16.
---

# Branching tasks (command-center)

## Branching tasks

When the CEO approves a plan that needs its own session, branch it:

```bash
cc-branch <task-id> [<repo-path>]
```

- `task-id` is the Plane issue ID (e.g., `PROJ-123`) if one exists,
  otherwise a slug like `vault-graph-groups`.
- `repo-path` **must be a real git repo** — `cc-branch` creates a per-task
  git worktree, so there is no `$HOME` fallback. Omitted, it defaults to the
  current repo's root and fails with "not in a git repo" if there isn't one.
  From command-center (not a repo) you must always pass it explicitly. For
  tasks with no code repo of their own, branch off `~/environment-foundation`.

The child opens in its own tmux window and writes its own tree slot + a
`spawned` event to your events directory.

**Parent linkage comes from the cwd, not the environment.** `cc-branch`
walks up from the current directory for a `.cc-mode` and takes its
`session_id` as the child's `parent_id`. So invoke it **from
command-center** and pass the repo as an argument — never `cd` into the
repo first, or the child is created with an empty `parent_id` and is
detached from your tree. `CC_PARENT_ID` is consulted only as a fallback
when no `.cc-mode` is found. cc-branch now warns when the parent resolves
empty, or to a session with no tree slot (a stale `.cc-mode`); read that
output rather than assuming linkage worked.

### Autonomous branches: send a first-message brief

`cc-branch` opens the worktree, the tmux window, and starts `claude` —
but it stops at the first-message prompt. For branches the CEO will
drive personally, that's fine; the CEO teleports in and shapes scope
live. For branches meant to run autonomously, idle = wasted time.

**Rule:** when you spawn an autonomous branch, immediately pipe a
scoped first-message brief into the child:

```bash
tmux load-buffer -b <name> <brief-file>
tmux paste-buffer -b <name> -t company:<task-id>
sleep 5
tmux send-keys -t company:<task-id> Enter
```

Why this pattern and not `send-keys -l`: tmux's `paste-buffer` uses
bracketed-paste markers when the terminal supports them, which the
Claude TUI does. The paste is treated as a single multi-line unit,
not as individual keystrokes, so newlines in the brief stay newlines
inside the input buffer rather than submitting prematurely. `send-keys
-l` sends raw characters with no bracketed-paste wrapper, so a
multi-line brief would submit at every newline.

The race the older pattern occasionally hit: Enter arriving while the
TUI was still ingesting the paste and being swallowed, leaving the
brief unsent silently. Mitigation is a generous `sleep` (5 seconds is
a safe baseline) between `paste-buffer` and `send-keys Enter`, plus
verifying with `capture-pane` before assuming the brief took:

```bash
tmux capture-pane -t company:<task-id> -p | tail -3
# expect to see the prompt advancing past "[Pasted text...]" placeholder
```

If the verification shows the paste is still queued at the prompt,
the Enter was swallowed and you should re-send a single `Enter`.

Instantiate autonomous briefs from the canonical template at
`~/environment-foundation/software/development/claude-code/canonical/templates/dispatch-brief.md`
(usage: its sibling README). Environment claims must be probes or carry a
dated verification — never copied constants. The template carries the full
required structure; in short, every brief must:
- state the deliverable and its report path
- list any vault context the child should read first (memory files, specs)
- name parallel sessions and their non-overlapping scope, to prevent
  merge collisions
- close with "invoke the `end-conversation` skill via the Skill tool when
  done" — never "/end", which does not resolve in branched worktrees

For CEO-driven branches, skip the brief. Confirm with the CEO which
mode applies before spawning when it's ambiguous.

## Teleporting

When the CEO wants to drop into a branched session directly:

```bash
cc-teleport <task-id>
```

This selects the matching tmux window. Window names are the
`task-id`s used at `cc-branch` time.

To list all in-flight windows:

```bash
tmux list-windows -t company -F '#{window_index}: #{window_name}'
```
