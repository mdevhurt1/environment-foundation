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
protocol, and the Skill-tool `end-conversation` close (`/end` does not
exist).
