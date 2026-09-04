# Vendored skills

Twelve skills in this directory were vendored from the **superpowers** plugin
(<https://github.com/obra/superpowers>, MIT, © Jesse Vincent), taken from
version **6.3.0**, git sha `6efe32c9e2dd002d0c394e861e0529675d1ab32e`.

**Nine remain vendored.** Three have been rewritten as company-native skills
and no longer track upstream at all (AI_ST-45/46/47, 2026-09-03):

| Still vendored | | Company-native (was vendored) |
|---|---|---|
| `dispatching-parallel-agents` | `test-driven-development` | `systematic-debugging` |
| `finishing-a-development-branch` | `using-git-worktrees` | `subagent-driven-development` |
| `receiving-code-review` | `using-superpowers` | `executing-plans` |
| `requesting-code-review` | `verification-before-completion` | |
| `writing-skills` | | |

## Why they were vendored rather than installed as a plugin

The plugin also ships `brainstorming` and `writing-plans`, whose names collide
with our own skills of the same name. Plugin enable/disable in Claude Code is
per-plugin only — there is no per-skill toggle — so the two colliding skills
could not be dropped while keeping the other twelve.

The collision was not cosmetic. The plugin's `using-superpowers` skill is
injected into every session by the plugin's own SessionStart hook, and it
routes creative work to `superpowers:brainstorming`. That version writes specs
to `docs/superpowers/specs/` **and commits them**, instead of writing to
`~/vault/20-surface/company/tasks/<task_id>/spec.md` and emitting a
`spec-written` tree event. Specs were landing in the wrong place, and in at
least one repo (`sentinel`) that path is deliberately suppressed, so they were
being lost outright.

## Local modifications to the nine that remain vendored

1. The `superpowers:` prefix was stripped from all cross-references, so they
   resolve to the vendored (unprefixed) skills. This also repoints the routing
   line in `using-superpowers/SKILL.md` to our canonical `brainstorming`.
2. `brainstorming` and `writing-plans` were not vendored; ours are canonical.
3. The plugin's SessionStart injection is replaced by
   `../shell/cc-skills-inject.sh`, registered in `../settings.json`.
4. `finishing-a-development-branch` carries our push doctrine (INFRA-50): the
   merge is not finished until the base branch leaves the machine, public
   remotes get the disclosure review first, and a branched session hands the
   push to its parent.

## The three company-native rewrites

`systematic-debugging`, `subagent-driven-development` and `executing-plans`
keep their **names and their frontmatter triggers** — the routing surface into
them is unchanged, so cross-references from the vendored nine still resolve —
but their bodies are ours. They are no longer subject to the update path
below: an upstream bump does **not** re-copy them, and a diff against upstream
6.3.0 is expected to be total.

What changed, in one line each:

- **`systematic-debugging`** — same Iron Law and four phases; examples moved
  from macOS codesigning and TypeScript to this company's machinery (the
  `cc-*` helper chain, tree events, the sandbox/proxy path, the shell traps
  that hide evidence). Phase 1 now opens by checking the host and the
  instrument, because this company's most expensive "defects" were
  self-inflicted false signals. Upstream's authoring artifacts
  (`CREATION-LOG.md`, `test-academic.md`, `test-pressure-{1,2,3}.md`) and the
  TypeScript example were removed: they are `writing-skills` development
  output, not shipped skill content, and their `skills/debugging/…` paths do
  not exist here. `find-polluter.sh` no longer hardcodes `npm test`.
- **`subagent-driven-development`** — same controller/implementer/reviewer
  loop, fix-round cap and breaker; escalation is now a tree event to the
  parent rather than a question into an unwatched pane, Model Selection is
  bound to `canonical/model-policy.json`'s roles, the plan workspace moved
  from `.superpowers/sdd/` to `.cc/sdd/`, and the two graphviz diagrams were
  replaced by tables in the house style.
- **`executing-plans`** — rewritten around this company's plan homes (the
  vault task folder, `docs/superpowers/plans/`, `~/.claude/plans/`) and
  `.cc-mode` modes; checkpoints now distinguish an interactive session (ask)
  from a branched one (rule, ledger, emit, keep working). The upstream note
  advertising Superpowers and listing other vendors' CLIs is gone.

## Updating the nine

There is no automatic update path. To take a newer upstream release, re-copy
those **nine** directories, re-run the prefix strip, re-apply the local
modifications above, and re-check that upstream has not added a skill whose
name collides with ours — including the three now-company-native names, which
must **not** be overwritten.
