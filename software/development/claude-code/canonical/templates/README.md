# Templates

## dispatch-brief.md — canonical autonomous-branch brief (AI_ST-81)

**Who instantiates it:** the EA, at dispatch time, when spawning an
autonomous branch (`cc-branch` + tmux paste-buffer first message). It is
not consumed by any script — the EA copies it, fills it, and pastes the
result as the child's first message. CEO-driven branches skip briefs
entirely, as before.

**What gets filled per task:** every `{{placeholder}}` — task_id, the
one-sentence goal, worktree/branch, parent session id, the ordered reads,
the deliverable artifacts with their proofs, the exhaustive
owned-vs-sibling path boundary, the probe hosts, and the completion-event
payload. Every `<!-- EA: ... -->` comment line is deleted before pasting;
the child receives finished prose.

**The rule this template exists to enforce:** any environment claim in a
brief must be **either a probe the child runs, or a claim carrying a dated
`(verified YYYY-MM-DD)` stamp**. Never a copied constant. The probe block
ships one-line, ~2s probes for the four claims with a track record of
propagating after refutation (tmux/AF_UNIX, ssh reach, LAN HTTP, Bash
vault writes); the child runs them and believes the output. Background:
seven recorded instances of refuted environment claims being copied from
brief to spec to child briefs — see
`~/vault/20-surface/company/tasks/workflow-audit/harness.md` F0 and
`knowledge.md` §0a. When a dated claim is re-verified, re-stamp it; when
it fails re-verification, delete it or convert it to a probe. A brief is
not a cache for environment facts.

**Standing structure the template already carries** (do not strip when
instantiating): goal-already-declared wording (keeps session-start Step 6
on its no-ask branch), report path under the task folder, tests/merge/
never-push lines, sibling-collision boundary, the escalation-event
protocol, the Skill-tool `end-conversation` close (`/end` does not
exist), the fork/subagent negative-scope clause (no writes, no memory
edits, no event emission, no dispatcher identity; AI_ST-101), and the
staged-commands pointer (AI_ST-100) below.

## staged-commands.md — host-guard preamble for staged `!` commands (AI_ST-100)

**Who instantiates it:** whoever stages shell commands for a human to
run via the `!` prefix (or by paste) — normally the EA staging a deploy
for the CEO. Not consumed by any script; the block is filled and handed
over as plain shell.

**When it is mandatory:** the staged sequence mutates state (deploy,
restart, overwrite, delete) or copies files across machines. Read-only
sequences need no guard. dispatch-brief.md's "Staged commands" section
makes instantiating this preamble a standing requirement for any brief
that stages such commands.

**What gets filled per staging:** the expected hostname (probed on the
machine the commands must run on), one `sha256sum -c` line per source
file with the hash probed **at staging time** against the exact file
being shipped, and the both-ends checksum echo around every
cross-machine copy. The dispatch-brief rule applies here at staging
time: a hostname or hash is a probe result, never a remembered or
reused constant, and a guard failure (`WRONG-MACHINE` /
`STALE-OR-WRONG-FILE`) means re-stage, never override.

**The incident it encodes:** 2026-09-11 wrong-host run of staged deploy
commands (AI_ST-100 / MONIT-17) — stale file shipped to production,
every command exit 0. See the template's worked example for the shape.
