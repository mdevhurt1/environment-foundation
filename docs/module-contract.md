# Software module contract

Every directory at `software/<category>/<name>/` is a **module** and must
satisfy this contract. `scripts/doctor.sh` at the repo root enforces it and
exits non-zero on any violation.

## Required files

| Path | Purpose |
|---|---|
| `README.md` | Profiles and Platforms header, why-this-approach, install/verify/uninstall usage |
| `scripts/install.sh` | Idempotent install. Re-running is safe and cheap. |
| `scripts/verify.sh` | Post-install acceptance test. Exit 0 means working. |
| `scripts/uninstall.sh` | Remove the software. Requires `--yes`. |

Optional, present when the module needs them:

| Path | Purpose |
|---|---|
| `scripts/configure.sh` | Post-install settings deployment |
| `scripts/doctor.sh` | Drift detection against a deployed state |
| `platform-notes/<os-version>.md` | Per-OS deviations |
| `canonical/` | Payload files the module deploys |

Every module must be reachable from at least one file in `profiles/`.

## Script conventions

These apply to every file under a module's `scripts/`, required or optional.

- **Executable bit set**, in the working tree *and* in the git index (mode
  `100755`). Both `bash scripts/x.sh` and `./scripts/x.sh` must work on a
  fresh clone.
- **Header comment block** carrying all four fields, within the first 20
  lines:

  ```bash
  # Description: <one line, or wrapped continuation lines>
  # Profiles:    <comma-separated profile names>
  # Platforms:   <comma-separated os-versions>
  # Dependencies: <what must already be present>
  ```

  Add `# Idempotent.` where it holds.
- **Source `shared/logging.sh`** via the `SCRIPT_DIR`/`REPO_ROOT` pattern:

  ```bash
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
  source "$REPO_ROOT/shared/logging.sh"
  ```

- **Call `require_not_root`.** Scripts use `sudo` internally where needed;
  they are never invoked with `sudo`.
- **`set -euo pipefail`**, with one exception:

  **Reporters — `verify.sh` and `doctor.sh` — use `set -uo pipefail`.**
  Deliberately no `-e`, so every check runs and reports rather than aborting
  at the first failure. A reporter that stopped early would hide the second
  and subsequent problems, which is the opposite of its job.

`verify.sh` follows the `check "<label>" <command...>` helper and `fails`
counter pattern established in `software/peripherals/razer/scripts/verify.sh`,
and exits non-zero if any check failed. A check for hardware or state that may
legitimately be absent **warns and skips** rather than failing — e.g. the
streamdeck module verifies correctly with no device plugged in.

`verify.sh` tests *capability*, not provenance. Check that the software works
(`command -v`, a `--version`, a service being active, a real no-op call), not
that a specific package name is installed — the same software can arrive from
a vendor repo, a distro archive, or a flatpak.

## Uninstall semantics

`uninstall.sh` removes the software and the configuration the module itself
created. It never removes user data.

**Removes:** the package, flatpak, or PPA/apt-source entry; symlinks and
config files the module created; udev rules and systemd units it installed.

**Never touches:** user data and application state; credentials and secrets,
including `~/.claude/settings.local.json`; Docker volumes and images; the
vault at `~/vault/`.

**Invocation:** running with no arguments prints what would be removed and
what is deliberately kept, then exits 0 **without changing anything**.
`--yes` is required to proceed. Any other argument exits 2. This follows the
non-interactive direction of INFRA-20 — an explicit flag, not a `read -p`
prompt.

Shared dependencies installed *alongside* the module's own software (ffmpeg,
the flathub remote, the i386 architecture) are listed as deliberately kept,
not removed — other software depends on them.

## Exclusions

The contract does **not** reach these, and the linter does not scan them:

| Path | Why |
|---|---|
| `shared/logging.sh` | Sourced library, not an executable. Must stay mode `100644`. |
| `software/*/*/canonical/**` | Deployed payload, not module scripts. Includes `claude-code/canonical/shell/cc-functions.sh`, which is a sourced library and must stay mode `100644`. |
| `software/*/*/platform-notes/**` | Documentation. |
| `platforms/**` | Platform baseline, not modules. Open question — see below. |
| `software/development/claude-code/integrations/**` | Has a `configure.sh` outside `scripts/`. Open question — see below. |

## Open questions (deferred — do not resolve here)

Tracked in `env-foundation-review`'s spec, § "Open questions":

1. Whether `platforms/<os>/scripts/` should be held to these script
   conventions. They already meet the header and `set -euo pipefail` rules;
   the linter can cover them in a later pass.
2. Whether to wire `scripts/doctor.sh` into a pre-commit hook or CI, and
   whether to add shellcheck alongside it. **Tracked as INFRA-22**; deferred
   so the linter can prove itself first.
3. Whether `software/development/claude-code/integrations/` should become a
   first-class module shape or stay a sub-directory.

## Running the linter

```bash
bash scripts/doctor.sh                        # lint the whole repo
bash scripts/doctor.sh --dry-run-uninstall    # also execute each uninstall.sh with no args
```

`--dry-run-uninstall` actually *runs* every `uninstall.sh` with no arguments to
prove each one exits 0 without changing anything. It is opt-in because it
executes scripts whose `--yes` path is destructive. Without the flag the
`--yes` guard is checked statically.
