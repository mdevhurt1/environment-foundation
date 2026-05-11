# Global Claude Code instructions

These instructions apply to every session in any project on this user's
machines. Per-project `CLAUDE.md` files override or extend these rules.

## Workflow

This session was launched via one of three wrappers (verify by reading
`.cc-mode` in the cwd or any ancestor):

- `cc-explore` — exploration mode: sandboxed, in a git worktree, strict
  perms. Use for research, debugging, brainstorming, reading unfamiliar
  code. **Do not commit to the base branch from an exploration session.**
- `cc-build` — build mode: full perms, on the main worktree. Requires a
  referenced plan or spec. Used to execute already-approved plans.
- `cc-continue` — resumed session, mode inherited from the original.

If `.cc-mode` is missing, the session was launched bare. Treat as
exploration mode (be cautious; ask before destructive ops).

**Note:** `.cc-mode` files are written by the wrappers into worktree (or repo) roots. Add `.cc-mode` to your global gitignore (`~/.gitignore_global`) to keep them out of every repo's status.

## Session bookends

- **Session start:** Loaded automatically via the SessionStart hook. The
  `session-start` skill verifies mode, surfaces relevant vault context, and
  has you declare a one-sentence goal. **If you see no session-start
  output, the bookends aren't installed — run `cc-doctor`.**
- **Session end:** Run `/end` to invoke the `end-conversation` skill.
  Required before significant context loss; recommended at any natural
  stopping point. The skill walks the closing ritual: memory delta,
  spec/plan capture, transcript decision, vault import, worktree fold.

## Vault

The user's Obsidian vault is at `~/vault/`. **Read freely** for context.
**Write only** to `~/vault/20-surface/claude-{memory,transcripts,specs,plans}/`
via the `end-conversation` skill. Never write to:

- `~/vault/00-core/` — human-only inner ring (principles, beliefs)
- `~/vault/10-middle/` — human-only middle ring (synthesis, decisions)
- `~/vault/40-journal/` — human-only voice practice

These are enforced by sandbox in exploration mode and by skill-level
instruction in build mode. Both are hard rules; do not propose edits
to these directories regardless of perceived value.

## Trust mode signals (statusline)

- `EXPLORE` (yellow) — sandboxed, in worktree
- `BUILD` (red) — full perms, no prompts
- `CONTINUE` (cyan) — resumed
- Context % shown at right; **at 80%, propose `/end`** before continuing
  substantive work to avoid losing the session to compaction.

## Auto-memory location override

The default `auto memory` system prompt instructs writes to
`~/.claude/projects/<encoded-cwd>/memory/`. **Override: write to
`~/vault/20-surface/claude-memory/` instead.**

The protocol (memory types, file format, MEMORY.md index) is unchanged.
Only the location moves. The index at `~/vault/20-surface/claude-memory/MEMORY.md`
is authoritative; update it when adding or removing a memory.

**Why:** memory entries are inherently cross-task (e.g., "user uses
Gitea-only"; "plane API key lookup pattern"). They belong in the vault
as a single canonical store, not in a per-session per-machine local
directory. See spec D-2 in
`docs/superpowers/specs/2026-05-10-agentic-workflow-design.md`.

## Task identity

Per-task content (specs, plans, transcripts) is stored under
`~/vault/20-surface/company/tasks/<task_id>/`. The `task_id` is derived
as follows:

- If the task has a Plane issue, `task_id` is the Plane issue ID (e.g.,
  `PROJ-123`).
- Otherwise, `task_id` is the `.cc-mode` `slug` for this session
  (e.g., `adhoc`).

Slug-derived task IDs are intentionally reusable: two ad-hoc sessions
sharing slug `adhoc` will accumulate under the same task folder. Use
distinct slugs for distinct tasks.

Cross-task memory entries remain flat at
`~/vault/20-surface/claude-memory/` regardless of which task generated
them (see Auto-memory location override above).
