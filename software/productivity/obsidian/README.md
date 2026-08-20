# Obsidian + Self-hosted LiveSync

> **Profiles:** `[workstation]`
> **Platforms:** ubuntu-24.04 (primary)

Obsidian is the vault application. **Self-hosted LiveSync** is the community
plugin that replicates the vault between devices through a CouchDB server.

This module is unusual: its centre of gravity is `verify.sh`, not `install.sh`.
Installing Obsidian is a one-liner. The thing that has actually cost this
company data-visibility is a *sync configuration that looks completely fine*,
and that is what this module turns into a failing check.

## The failure this module exists to catch

A LiveSync device can be fully configured — `isConfigured: true`, encrypted
connection string present, remote reachable — and still replicate **nothing**,
if every auto-sync trigger is off:

| Setting | Meaning when true |
|---|---|
| `liveSync` | continuous replication while the app is open |
| `periodicReplication` | replicate every `periodicReplicationInterval` seconds |
| `syncOnSave` | replicate when a note is saved |
| `syncOnStart` | replicate when Obsidian launches |
| `syncOnFileOpen` | replicate when a note is opened |
| `syncOnEditorSave` | replicate on editor save |

With all six `false`, data moves only when a human presses **Replicate** by
hand. The plugin raises no error, shows no warning, and reports no unhealthy
state — because from its point of view nothing is wrong. You told it not to
sync automatically, and it is not syncing automatically.

The laptop sat in exactly this state for roughly a month (2026-07-12 →
2026-08-09). The symptom is a vault-file **mtime flatline** while other channels
show ongoing work. The danger is not the staleness itself but the reading of it:
a fresh session opens the on-disk vault, sees a coherent, complete, plausible
vault, and concludes it is current. It may go on to conclude "nothing here is
precious." When sync was re-enabled, ~681 files landed and that reading
inverted completely.

**A month of silence produced no error message anywhere. It now produces
`exit 1`.**

There is a second route to the same place, which a triggers-only check would
call healthy: `suspendFileWatching` or `suspendParseReplicationResult` set true
halts replication while all six triggers still read "on". `verify.sh` fails on
that too.

## Why this module verifies configuration instead of deploying it

The canonical-config principle is that version-controlled configuration holds
**portable intent only**; per-device mutable state stays out of the repo.
LiveSync's `data.json` is per-device mutable state on every axis:

- It carries **secrets** — the CouchDB endpoint and credentials
  (`encryptedCouchDBConnection`) and the E2E `encryptedPassphrase`. These belong
  in `environment-secrets`, never here. **No credential, endpoint, hostname or
  passphrase may ever be committed to this module**, including in the fixtures.
- It carries genuinely per-device values: `deviceAndVaultName`, chunk and
  batching tuning, `lastReadUpdates`, `doctorProcessedVersion`.
- `syncInternalFiles` is `false`, so `.obsidian/` does not replicate. Each
  device's settings drift independently *by design*, and a canonical baseline
  deployed over them would be fighting the plugin.

So the module ships **no canonical `data.json` and no partial key baseline**.
Setup is done in-app from a setup URI kept in your password manager. What the
repo owns is the *assertion* about that config — one portable, secret-free
sentence: **at least one auto-sync trigger must be on, and replication must not
be suspended.**

## What `verify.sh` checks

| # | Check | On failure |
|---|---|---|
| 1 | An Obsidian application is present (deb, flatpak, snap, or on `PATH`) | fail |
| 2 | Vault / plugin / `data.json` present | **warn and skip** — see below |
| 3 | `data.json` parses as JSON | fail |
| 4 | `isConfigured` is true | fail |
| 5 | **At least one of the six auto-sync triggers is true** | **fail** |
| 6 | Neither suspend setting is true | fail |
| 7 | An established socket on `:6984` while Obsidian runs | informational |
| 8 | `MEMORY.md` is a 1:1 index of the memory files beside it | fail |
| 9 | No known auto-merge corruption tokens in `MEMORY.md` | fail |

**Check 2 warns rather than fails** because a machine with no vault, no plugin,
or no `data.json` is a machine where Obsidian was never set up — not a broken
install of this module. This follows the contract's convention for state that
may legitimately be absent (the streamdeck module verifies with no device
plugged in). A `data.json` that exists but is *unreadable* or *malformed* does
fail: that is a defect, not an absence.

**Check 5 fails when all six keys are missing**, not just when all are false. If
the instrument cannot see the state it exists to judge, it must not report
success — an unreadable gauge is a failure, never a pass.

**Check 7 cannot fail by design.** A laptop off the home network legitimately
has no socket, so making this fatal would redden `verify.sh` for a reason that
is not a misconfiguration. It corroborates; checks 5 and 6 are the ones with
teeth. Stated here because a check that can never go red should never be
mistaken for one that can.

### Advisories (reported, not fatal)

- `disableMarkdownAutoMerge` is `false` → **warn**. On 2026-08-20, taking
  *Merge* on a `MEMORY.md` conflict corrupted the file: drifted line offsets
  made the plugin align non-corresponding entries and character-diff them,
  splicing one entry's text into the middle of another's words (`declareOn`,
  `seeheck`, `shippeds`, `thisreference_`). Four of five changed lines were
  damaged. Setting this true routes conflicts to the dialog instead. It is a
  **vault-wide behaviour change**, so the module warns rather than enforcing —
  pending a decision.
- `writeDocumentsIfConflicted` is `false` → **note**. A conflicted document is
  never written to disk, and with `usePathObfuscation` both CouchDB and the
  local PouchDB key on hashed ids. **No filesystem scan can find a LiveSync
  conflict.** Use the plugin UI.

## On the memory-index checks, and what they cannot say

`MEMORY.md` is the vault's most conflict-prone file: a single append-style index
written by every agent session on every device. Two devices appending between
replications is a genuine document conflict, inherent to the design rather than
a misconfiguration. It lives in *this* module's checks because it is the file
LiveSync's own auto-merge is known to have damaged.

`scripts/verify-memory-index.py` validates **structure**: every pointer line
resolves to a file, every file has exactly one pointer, no duplicates, nothing
orphaned.

**Its green is narrow, and this is measured, not theoretical.** The 2026-08-20
corruption passed it completely: 380 pointer lines ↔ 380 files, 1:1, zero
dangling, zero orphans, line count unchanged at 400 — `CLEAN` — while four
entries carried garbled prose. Only the byte size moved. A structure check
cannot see corrupted content. It is a floor, not a guarantee.
`fixtures/memory-index/corrupted/` reproduces exactly that: structurally clean,
textually corrupt.

Check 9 is the paired content check, and its reach is narrower still: it
recognises **the four fused tokens the 2026-08-20 merge happened to produce**
and nothing else. A different auto-merge would fuse different tokens and pass.
Treat check 9 as a regression test for one known event, not as corruption
detection.

It strips inline-code spans before matching. Without that it fails on a
*healthy* index — the memory entry that documents the corruption quotes all four
tokens, so the detector matched its own documentation. That happened on the
first run here; the fixtures below now pin both directions.

## Install

```bash
bash scripts/install.sh
```

Installs the Obsidian desktop app from the official `.deb` release, or reports
and skips if any Obsidian (deb, flatpak, snap, `PATH`) is already present.
Idempotent: it never upgrades in place and never stacks one packaging on
another. It deploys **no** vault or plugin configuration.

Finishing setup on a new device is manual and deliberate:

1. Open the vault → Settings → Community plugins → Browse → **Self-hosted
   LiveSync** → Install → Enable.
2. Apply the setup URI from your password manager. Never paste it into this
   repo, a commit message, or an issue.
3. **Enable at least one auto-sync trigger.**
4. Run `verify.sh`.

## Verify

```bash
bash scripts/verify.sh                              # the live config
bash scripts/verify.sh --data-json fixtures/frozen.json   # watch it go red
```

Exit 0 means this device replicates. Exit 1 means it does not, or cannot be
shown to.

Overrides, for testing and for non-default layouts: `--data-json PATH`,
`--vault DIR`, and the environment variables `VAULT_DIR`,
`LIVESYNC_DATA_JSON`, `MEMORY_DIR`, `COUCHDB_PORT`.

### Fixtures

A check nobody has watched go red is not a check. `fixtures/` holds the inputs
that make each failure fire, so the red is reproducible rather than asserted.
All are synthetic — no endpoint, credential or passphrase appears in any of
them, and none may ever be added.

| Fixture | Expected |
|---|---|
| `healthy.json` | exit 0 |
| `frozen.json` | exit 1 — every trigger off (the month-long freeze) |
| `suspended.json` | exit 1 — triggers on, file watching suspended |
| `unconfigured.json` | exit 1 — `isConfigured: false` |
| `no-trigger-keys.json` | exit 1 — state not expressible; must not pass |
| `malformed.json` | exit 1 — not valid JSON |
| `memory-index/clean/` | exit 0 |
| `memory-index/corrupted/` | exit 1 — structurally clean, textually corrupt |
| `memory-index/orphan/` | exit 1 — a memory file with no pointer |

## Uninstall

```bash
bash scripts/uninstall.sh          # dry run: prints what it would do, changes nothing
bash scripts/uninstall.sh --yes    # actually remove Obsidian
```

Removes only the Obsidian package. It never touches the vault, `.obsidian/`, the
LiveSync settings (which hold the encrypted connection and E2E passphrase — the
setup URI, not a preference), or `~/.config/obsidian/`.

Note that **nothing replicates while Obsidian is uninstalled**: LiveSync runs
inside the app. A vault edit made from the shell in the meantime does not sync,
and may be reverted when Obsidian next opens.
