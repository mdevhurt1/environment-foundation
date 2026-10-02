---
name: model-tiers
owner: Marcus (operator)
as-of: 2026-10-02
---

# Reviewer capability tiers

**Operator-owned. Dated 2026-10-02.** Model lists go stale. Re-check this table against
what each runtime actually serves before you seat a panel, and update `as-of` when you
change it. `tools/assemble_prompts.py` reads the rows between the markers. Tier 1 is
the most capable tier. A reviewer's tier number must be less than or equal to the
producer's tier number (US-8: no reviewer below the producing model's capability).

Matching rules: the `model pattern` column is a shell glob (`fnmatch`), matched
case-insensitively against the model id you pass to `--producer` or `--reviewer`. **The
first matching row wins**, so narrower patterns (`*-mini`, `*-flash*`) must come before
the broad family patterns. A model that matches no row is refused, so add a row before
using a new model. Bracketed context suffixes such as `[1m]` are stripped before
matching.

<!-- BEGIN TIERS -->
| model pattern | tier | reached through | note |
|---|---|---|---|
| `claude-haiku-*` | 3 | Claude Code | small model |
| `claude-sonnet-*` | 2 | Claude Code | e.g. claude-sonnet-5-5 |
| `claude-fable-*` | 1 | Claude Code | claude-fable-5-1 is in the account roster (2026-10-01) |
| `claude-mythos*` | 1 | Claude Code | when available on the account |
| `claude-opus-5*` | 1 | Claude Code | e.g. claude-opus-5-5 |
| `gpt-5*-mini*` | 2 | Codex | small variant; must sit above the gpt-5 row |
| `gpt-5*-nano*` | 3 | Codex | small variant; must sit above the gpt-5 row |
| `gpt-5*` | 1 | Codex | family classification; verify the actual model before seating |
| `gpt-6-sol` | 1 | Codex | verified in ~/.codex/config.toml on 2026-10-02 |
| `gpt-oss*120b*` | 2 | Antigravity CLI (agy) | Marcus ruled tier 2; live agy roster still needs verification |
| `gemini-3*-flash*` | 2 | Antigravity CLI (agy) | must sit above the gemini-3 row |
| `gemini-3*` | 1 | Antigravity CLI (agy) | record the id agy reports |
| `qwen*` | 3 | Pi (local, marcus-desktop) | Pi's default model is qwen3.6:35b (~/.pi/agent/settings.json, 2026-10-01) |
| `llama*` | 3 | Ollama, local | |
<!-- END TIERS -->

A runtime is not a reviewer. A runtime earns a seat only through the model it serves.
Pi on its default local model is tier 3, so it cannot sit on a panel reviewing work
produced by a tier 1 or tier 2 model, however many runtimes that leaves unused.

## Changelog

- 2026-10-02: Added verified local Codex model and Marcus's tier-2 ruling for GPT-OSS 120B; agy roster still unverified.
- 2026-10-01: First table (AI_ST-112). The Claude rows come from the account roster and
  the session model ids. The GPT and Gemini rows are family patterns, because neither
  runtime pins a model id in its config on this machine.
