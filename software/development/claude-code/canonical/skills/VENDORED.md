# Vendored skills

Twelve skills in this directory are vendored from the **superpowers** plugin
(<https://github.com/obra/superpowers>, MIT, © Jesse Vincent), taken from
version **6.3.0**, git sha `6efe32c9e2dd002d0c394e861e0529675d1ab32e`:

    dispatching-parallel-agents      systematic-debugging
    executing-plans                  test-driven-development
    finishing-a-development-branch   using-git-worktrees
    receiving-code-review            using-superpowers
    requesting-code-review           verification-before-completion
    subagent-driven-development      writing-skills

## Why they are vendored rather than installed as a plugin

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

## Local modifications

1. The `superpowers:` prefix was stripped from all cross-references, so they
   resolve to the vendored (unprefixed) skills. This also repoints the routing
   line in `using-superpowers/SKILL.md` to our canonical `brainstorming`.
2. `brainstorming` and `writing-plans` were not vendored; ours are canonical.
3. The plugin's SessionStart injection is replaced by
   `../shell/cc-skills-inject.sh`, registered in `../settings.json`.

## Updating

There is no automatic update path now. To take a newer upstream release,
re-copy the twelve directories, re-run the prefix strip, and re-check that
upstream has not added a skill whose name collides with ours.
