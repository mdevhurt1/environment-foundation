# Harness freeze

**From:** 2026-09-19  **To:** 2026-10-03, **ended early 2026-10-01** by operator ruling (Marcus)

No changes to agent tooling in this window: no new hooks, skills, wrappers, scripts, instruction text, or memory-index tooling. The only exception is outright breakage (a runtime cannot start, a secret cannot be read).

Friction goes in `~/vault/20-surface/inbox/harness-friction.md` as one dated line each. On 2026-10-03 the log is reviewed and only what was missed gets restored from `software/development/claude-code/parked/`.

State before the reset: git tag `pre-reset-2026-09-19`; local snapshot `~/.local/state/harness-reset/2026-09-19/`.

## Closed 2026-10-01

The log was reviewed and drained to zero on 2026-10-01 (Plane AI_ST-105..124, label `stack:harness`). The freeze ends into release v2.0.0, the first harness release under the release-driven model ruled 2026-09-25: scope is Plane module `harness v2.0.0` (AI_ST-107, 108, 110, 115, 116, 118, 120, 123), shipped when `agents/scripts/verify.sh` passes in full. Friction keeps going to the same log, which the Friday review drains into Plane.
