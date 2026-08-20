#!/usr/bin/env bash
# Description: Acceptance test for the obsidian module. Proves this device
#              actually replicates the vault: it FAILS on the Self-hosted
#              LiveSync silent-freeze configuration (every auto-sync trigger
#              off, or replication suspended), which is fully "configured",
#              raises no error in the app, and once froze a machine for a month.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: python3, Obsidian, the Self-hosted LiveSync community plugin
#              (install.sh installs Obsidian; the plugin is installed in-app)

set -uo pipefail   # NOTE: no -e — we want every check to run and report.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

usage() {
  cat <<'EOF'
Usage: bash scripts/verify.sh [--data-json PATH] [--vault DIR]

Checks that Obsidian is installed and that Self-hosted LiveSync on this device
is in a configuration that actually replicates.

  --data-json PATH  Read this LiveSync data.json instead of the live one.
                    Used to exercise the checks against the fixtures in
                    ../fixtures/ without touching the real vault.
  --vault DIR       Vault root (default: $HOME/vault).

Environment overrides: VAULT_DIR, LIVESYNC_DATA_JSON, MEMORY_DIR, COUCHDB_PORT.

Exit 0 = this device replicates. Exit 1 = it does not, or cannot be shown to.
EOF
}

VAULT_DIR="${VAULT_DIR:-$HOME/vault}"
DATA_JSON="${LIVESYNC_DATA_JSON:-}"
COUCHDB_PORT="${COUCHDB_PORT:-6984}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --data-json) DATA_JSON="${2:-}"; shift 2 || true ;;
    --vault)     VAULT_DIR="${2:-}"; shift 2 || true ;;
    -h|--help)   usage; exit 0 ;;
    *)           log_error "unknown argument: $1 (try --help)"; exit 2 ;;
  esac
done

[ -n "$DATA_JSON" ] || DATA_JSON="$VAULT_DIR/.obsidian/plugins/obsidian-livesync/data.json"
PLUGIN_DIR="$(dirname "$DATA_JSON")"
MEMORY_DIR="${MEMORY_DIR:-$VAULT_DIR/20-surface/claude-memory}"

fails=0
warns=0

check() {
  # check "<label>" <command...>
  local label="$1"; shift
  if "$@" &>/dev/null; then
    log_ok "$label"
  else
    log_error "$label"
    fails=$((fails + 1))
  fi
}
failed()  { log_error "$*"; fails=$((fails + 1)); }
skipped() { log_warn  "$*"; warns=$((warns + 1)); }
note()    { printf '[NOTE]  %s\n' "$*"; }

# The six settings that can make LiveSync replicate without being asked. If
# every one of them is off, the plugin only moves data when a human presses
# Replicate — and stops forever the moment nobody does.
TRIGGER_KEYS=(liveSync periodicReplication syncOnSave syncOnStart syncOnFileOpen syncOnEditorSave)

# Settings that halt replication while every trigger above still reads "on".
SUSPEND_KEYS=(suspendFileWatching suspendParseReplicationResult)

# Reads DATA_JSON and prints "key=1|0|absent" lines for the settings we judge.
# Exit 3 means the file is not parseable JSON; the reason is on stdout.
read_config() {
  python3 - "$1" "${TRIGGER_KEYS[@]}" "${SUSPEND_KEYS[@]}" \
      isConfigured disableMarkdownAutoMerge writeDocumentsIfConflicted <<'PY'
import json, sys

path, keys = sys.argv[1], sys.argv[2:]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except Exception as exc:
    print("PARSE_ERROR=%s" % str(exc).replace("\n", " "))
    sys.exit(3)
if not isinstance(data, dict):
    print("PARSE_ERROR=top-level JSON value is %s, expected an object"
          % type(data).__name__)
    sys.exit(3)

for key in keys:
    value = data.get(key, "__absent__")
    # Only a real boolean counts. A string "true" is not a setting LiveSync
    # would honour, and must not be read as one here either.
    if value is True:
        print("%s=1" % key)
    elif value is False:
        print("%s=0" % key)
    else:
        print("%s=absent" % key)
PY
}

log_info "Verifying Obsidian module install..."
log_info "vault:     $VAULT_DIR"
log_info "data.json: $DATA_JSON"
echo

# --- 1. The application --------------------------------------------------------
echo "-- Obsidian --"
obsidian_present() {
  [ -x /opt/Obsidian/obsidian ] && return 0
  flatpak info md.obsidian.Obsidian &>/dev/null && return 0
  snap list obsidian &>/dev/null && return 0
  command -v obsidian &>/dev/null && return 0
  return 1
}
check "Obsidian application present" obsidian_present

# --- 2. The vault and the plugin -----------------------------------------------
echo
echo "-- Self-hosted LiveSync --"

# A machine with no vault, no Obsidian data, or no plugin is not a broken
# install of this module — it is a machine where Obsidian has not been set up.
# Warn and skip (docs/module-contract.md: state that may legitimately be
# absent warns rather than fails).
config_readable=0
if [ ! -d "$VAULT_DIR" ]; then
  skipped "no vault at $VAULT_DIR — Obsidian is not set up on this machine; sync checks skipped"
elif [ ! -d "$PLUGIN_DIR" ]; then
  skipped "Self-hosted LiveSync is not installed ($PLUGIN_DIR absent) — sync checks skipped"
  note "install it in-app: Settings -> Community plugins -> Browse -> Self-hosted LiveSync"
elif [ ! -f "$DATA_JSON" ]; then
  skipped "plugin present but never configured ($DATA_JSON absent) — sync checks skipped"
  note "apply your setup URI in LiveSync's settings, then re-run this script"
elif [ ! -r "$DATA_JSON" ]; then
  failed "$DATA_JSON exists but is not readable — cannot judge whether this device replicates"
else
  config_readable=1
fi

if [ -f "$PLUGIN_DIR/manifest.json" ]; then
  plugin_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version","?"))' "$PLUGIN_DIR/manifest.json" 2>/dev/null)"
  [ -n "$plugin_version" ] || plugin_version="?"
  note "plugin version: $plugin_version"
fi

# --- 3. The freeze checks ------------------------------------------------------
if [ "$config_readable" -eq 1 ]; then
  cfg_out="$(mktemp)"
  read_config "$DATA_JSON" >"$cfg_out" 2>/dev/null
  parse_rc=$?

  if [ "$parse_rc" -ne 0 ]; then
    failed "LiveSync data.json is not valid JSON — $(sed -n 's/^PARSE_ERROR=//p' "$cfg_out" | head -1)"
    note "a corrupt data.json means the plugin falls back to defaults: no remote, no replication"
  else
    declare -A CFG=()
    while IFS='=' read -r key value; do
      [ -n "$key" ] && CFG["$key"]="$value"
    done < "$cfg_out"

    # 3a. Configured at all.
    if [ "${CFG[isConfigured]:-absent}" = "1" ]; then
      log_ok "LiveSync reports isConfigured"
    else
      failed "LiveSync is not configured (isConfigured=${CFG[isConfigured]:-absent})"
      note "apply your setup URI in LiveSync's settings — it is never stored in this repo"
    fi

    # 3b. THE CHECK. At least one auto-sync trigger must be enabled.
    #     This is the whole reason the module exists: the state below is what
    #     froze a machine's vault for roughly a month with no error anywhere.
    enabled=()
    present=0
    for key in "${TRIGGER_KEYS[@]}"; do
      case "${CFG[$key]:-absent}" in
        1) enabled+=("$key"); present=$((present + 1)) ;;
        0) present=$((present + 1)) ;;
      esac
    done

    if [ "$present" -eq 0 ]; then
      # Every trigger key is missing. We cannot see the state we exist to
      # judge, so we must not report success: an unreadable instrument is a
      # failure, not a pass.
      failed "no auto-sync trigger setting is present in data.json — cannot determine whether this device replicates"
      note "expected at least one of: ${TRIGGER_KEYS[*]}"
      note "this data.json may come from an incompatible plugin version"
    elif [ "${#enabled[@]}" -gt 0 ]; then
      log_ok "LiveSync replicates automatically (enabled: ${enabled[*]})"
    else
      failed "SILENT FREEZE: every LiveSync auto-sync trigger is disabled"
      for key in "${TRIGGER_KEYS[@]}"; do
        note "  $key = ${CFG[$key]:-absent}"
      done
      note "This device is fully configured and replicates NOTHING unless a human"
      note "presses Replicate by hand. The app shows no error, and the vault on disk"
      note "looks current while being arbitrarily stale — a laptop sat like this for"
      note "roughly a month. Fix: Settings -> Self-hosted LiveSync -> Sync Settings,"
      note "and enable LiveSync (or Periodic replication / Sync on save)."
    fi

    # 3c. Suspension. These halt replication while the triggers still read on.
    for key in "${SUSPEND_KEYS[@]}"; do
      if [ "${CFG[$key]:-absent}" = "1" ]; then
        failed "replication is suspended: $key is true"
        note "a trigger being enabled means nothing while this is set"
      else
        log_ok "not suspended ($key=${CFG[$key]:-absent})"
      fi
    done

    # 3d. Conflict-handling posture. Advisory, not pass/fail — see README.
    if [ "${CFG[disableMarkdownAutoMerge]:-absent}" != "1" ]; then
      skipped "markdown auto-merge is enabled (disableMarkdownAutoMerge=${CFG[disableMarkdownAutoMerge]:-absent})"
      note "measured 2026-08-20: auto-merging MEMORY.md fused tokens across entries"
      note "and the damage passed a clean structural check. Turning this on routes"
      note "conflicts to the dialog instead. Vault-wide behaviour change — CEO call."
    else
      log_ok "markdown auto-merge is disabled (conflicts go to the dialog)"
    fi
    if [ "${CFG[writeDocumentsIfConflicted]:-absent}" != "1" ]; then
      note "writeDocumentsIfConflicted is off: a conflicted document is never written"
      note "to disk, so NO filesystem scan can find a conflict. Use the plugin UI."
    fi
  fi
  rm -f "$cfg_out"
fi

# --- 4. Live corroboration ------------------------------------------------------
# Informational by design. A laptop that is off the home network has no socket
# and is not misconfigured, so this cannot be a failing check — the config
# checks above are the ones with teeth.
echo
echo "-- Live replication (informational) --"
if ! pgrep -x obsidian >/dev/null 2>&1; then
  note "Obsidian is not running — live replication cannot be observed from here"
elif command -v ss >/dev/null 2>&1 && ss -tn 2>/dev/null | grep -q ":$COUCHDB_PORT[[:space:]]*$"; then
  note "Obsidian holds an established connection on :$COUCHDB_PORT (replicating now)"
elif command -v ss >/dev/null 2>&1; then
  skipped "Obsidian is running but holds no established socket on :$COUCHDB_PORT"
  note "expected while off the home network; investigate if you are on it"
else
  note "ss(8) not available — skipping the socket observation"
fi

# Greps MEMORY.md for the fused tokens the 2026-08-20 auto-merge produced.
# Inline-code spans are stripped first. Without that this fails on a HEALTHY
# index: the memory entry that *documents* the corruption quotes all four
# tokens, so the detector matched its own documentation (measured, not
# hypothetical). Corruption puts these tokens in running prose; a citation of
# them belongs in backticks. Calibrated both ways against ../fixtures/memory-index/.
no_corruption_tokens() {
  ! sed 's/`[^`]*`//g' "$1" \
    | grep -qE 'seeheck|shippeds|declareOn|thisreference_'
}

# --- 5. Memory index integrity --------------------------------------------------
# MEMORY.md is the vault's most conflict-prone file: one append-style index
# written by every agent session on every device. It is also the file LiveSync's
# auto-merge is known to have corrupted, which is why this lives here.
echo
echo "-- Vault memory index --"
if [ ! -d "$MEMORY_DIR" ]; then
  skipped "no memory index at $MEMORY_DIR — skipping index checks"
elif [ ! -f "$MEMORY_DIR/MEMORY.md" ]; then
  skipped "$MEMORY_DIR exists but has no MEMORY.md — skipping index checks"
else
  check "MEMORY.md is a 1:1 index of the memory files beside it" \
    python3 "$SCRIPT_DIR/verify-memory-index.py" "$MEMORY_DIR"
  if ! python3 "$SCRIPT_DIR/verify-memory-index.py" "$MEMORY_DIR" >/dev/null 2>&1; then
    note "re-run for detail: python3 $SCRIPT_DIR/verify-memory-index.py $MEMORY_DIR"
  fi

  # The structural check above passed the 2026-08-20 corruption unchanged. This
  # is the paired content check for it. Read the README before trusting it: it
  # recognises the tokens that corruption produced and nothing else.
  #
  # Inline-code spans are stripped first. Without that, this check fails on a
  # healthy index: the memory entry that *documents* the corruption quotes all
  # four tokens, so the detector matched its own documentation. Corruption
  # produces these tokens in running prose; a citation of them belongs in
  # backticks. Calibrated both ways against ../fixtures/memory-index/.
  check "no known auto-merge corruption tokens in MEMORY.md" \
    no_corruption_tokens "$MEMORY_DIR/MEMORY.md"
fi

# --- Summary --------------------------------------------------------------------
echo
if [ "$fails" -eq 0 ]; then
  if [ "$warns" -gt 0 ]; then
    log_ok "All checks passed ($warns warning(s) — see above)."
  else
    log_ok "All checks passed."
  fi
  exit 0
fi
log_error "$fails check(s) failed."
log_warn "A failed trigger check means this device is NOT replicating the vault."
log_warn "Do not trust anything you read from it until the check is green."
exit 1
