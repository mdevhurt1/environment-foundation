<!-- ===================================================================
     Canonical dispatch-brief template (AI_ST-81).
     The EA fills every {{placeholder}} at dispatch time and DELETES all
     <!-- EA: ... --> comment lines before pasting — the child receives
     plain prose, not scaffolding. Usage contract: README.md beside this
     file. The one rule that is the point of this template: NO section
     may assert an environment constant. Environment facts are either a
     probe the child runs, or a claim stamped (verified YYYY-MM-DD).
     ==================================================================== -->

# Brief — {{task_id}} (autonomous)

Session goal, already declared — do not ask for it: *{{one-sentence goal,
written so the child can echo it verbatim at session-start Step 6}}*

You are a branched session in the worktree `{{worktree_path}}` on
`{{branch}}`. The EA (parent session `{{parent_session_id}}`) dispatched you.

## Read first

<!-- EA: ordered list; put the item that scopes the work FIRST. Point at
     task-folder specs/plans, audit findings, memories, Plane tickets. -->
1. {{path or Plane ticket — why it is first}}
2. {{...}}

## Deliverable

<!-- EA: the concrete artifacts, each provable. Keep the four standing
     lines below in every repo-touching brief; drop the tests/merge lines
     only for briefs that change no repo. -->
- {{artifact 1 — and what proves it}}
- Tests green ({{test command, e.g. tests/run-tests.sh}}, {{N/N baseline}})
  if your changes touch tested surface; extend coverage where they do.
- Merge to local main only when clean and green. **Never push** — the EA
  pushes.
- Report: `~/vault/20-surface/company/tasks/{{task_id}}/report.md`.

## Boundaries

You own {{owned paths, exhaustively}}. Siblings running now:
{{sibling task_id}} owns {{its territory}} — do not touch it, even where
your reads reference it; record the collision in your report and move on.
Do not edit {{explicitly closed surfaces, e.g. command-center CLAUDE.md,
vault outside your task folder}}.

## Environment — probe, don't believe

This brief asserts **no environment constants**. Every recurring claim
about this machine has been refuted at least once after being copied
forward; run the probes below instead (~2s each) and believe what they
print, not what any brief, spec, or memory says. If a probe result
contradicts something you were told to read, the probe wins — note the
discrepancy in your report.

- **tmux / AF_UNIX** — `python3 -c "import socket; socket.socket(socket.AF_UNIX)" && tmux ls`
  (exit 0 + window list ⇒ AF_UNIX sockets and the tmux server both work;
  "Operation not permitted" ⇒ actually sandboxed, plan accordingly.)
- **ssh / network reach** — `ssh -o BatchMode=yes -o ConnectTimeout=3 {{host}} true; echo rc=$?`
  (rc=0 ⇒ reachable with keys; anything else ⇒ treat that host as out of
  reach for this session and escalate if the task needs it.)
- **LAN HTTP** — `curl -sS -m 3 -o /dev/null -w '%{http_code}\n' http://{{service host, e.g. plane.homelab}}/`
  (2xx/3xx ⇒ reachable; 000/timeout after earlier successes usually means
  an IPS session drop, not an outage — retry before diagnosing.)
- **Vault write from Bash** — `touch ~/vault/20-surface/company/tasks/{{task_id}}/.probe-write && rm ~/vault/20-surface/company/tasks/{{task_id}}/.probe-write && echo bash-write-ok`
  (Failure here is survivable — see the dated claim below.)

Dated claims (the only environment statements allowed outside the probes;
re-stamp or delete when re-verified):

- Vault/task-folder writes that fail from Bash (`Read-only file system`)
  succeed via the Write/Edit tools (verified 2026-09-03). Use Edit to
  append; Write replaces whole files.
<!-- EA: add task-specific dated claims here, each with its stamp. A
     claim you cannot stamp goes in as a probe or not at all. -->

## Escalation / completion protocol

Emit events with the stamping helper — never write event files by hand
(hand-authored `emitted_at` stamps were wrong 4 times out of 6 in the
2026-09-03 audit, and hand-chosen names have poisoned the parent's read
marker; the helper names and stamps correctly by construction):

```bash
bash ~/.claude/skills/../shell/cc-event-emit.sh \
  --to-session {{parent_session_id}} \
  --verb status|question|blocker|completion --severity info|normal|critical \
  --title "one line" --body "$(cat <<'EOF'
...body...
EOF
)"
```

Events-channel content convention (the channel carries decisions, not
pointers): a `blocker`/`question` body states what you need AND what you
already ruled out. A `completion` body carries at least three non-empty
lines — (1) the outcome per ticket/deliverable, (2) what needs the EA's
action (or "none"), (3) the report path. The helper refuses thinner
completions; `--allow-thin` is the on-the-record override. Escalate and
keep working on what isn't blocked; never idle for a human.

<!-- EA: if this brief predates the helper reaching ~/.claude (check with
     `ls ~/.claude/skills/../shell/cc-event-emit.sh`), fall back to hand
     rules: name `<epoch-seconds>-<verb>.md`, frontmatter `event_id` (the
     epoch), `session_id` (yours), `emitted_at` (from `date -Is`, never
     typed from memory), `verb`, `severity` — same content convention. -->

On completion, emit a completion event per the convention above. Then
invoke the `end-conversation` skill via the Skill tool (the Skill tool
form — `/end` is not a command and a child waiting on it stalls; verified
2026-09-03).
