#!/usr/bin/env bash
# Description: Repo-level module contract linter. Checks every module under
#              software/<category>/<name>/ against docs/module-contract.md,
#              plus two repo-wide invariants. Exits non-zero on any violation.
# Profiles:    n/a — repo tooling, not a provisioning step
# Platforms:   ubuntu-24.04
# Dependencies: bash 4+, coreutils (incl. timeout), grep, find, git
#              (shellcheck NOT required — see INFRA-22)
# Idempotent.

# NOTE: no -e — the linter must run every check and report every violation.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

ok()      { log_ok    "$*"; OK_COUNT=$((OK_COUNT + 1)); }
warn()    { log_warn  "$*"; WARN_COUNT=$((WARN_COUNT + 1)); }
fail()    { log_error "$*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
section() { printf '\n== %s ==\n' "$*"; }

DRY_RUN_UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --dry-run-uninstall) DRY_RUN_UNINSTALL=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/doctor.sh [--dry-run-uninstall]

Lints every module under software/<category>/<name>/ against
docs/module-contract.md. Exits non-zero on any violation.

  --dry-run-uninstall  Additionally execute each module's uninstall.sh with no
                       arguments, asserting it exits 0. Opt-in because it runs
                       scripts whose --yes path is destructive.
EOF
      exit 0 ;;
    *) log_error "unknown argument: $arg (try --help)"; exit 2 ;;
  esac
done

# Required header fields, in the first 20 lines of every module script.
REQUIRED_HEADER_FIELDS=(Description Profiles Platforms Dependencies)

# ---------------------------------------------------------------------------
# Per-script checks. Emits one OK line for a clean script, or one FAIL line
# per problem — so a green run stays readable and a red run is actionable.
# ---------------------------------------------------------------------------
check_script() {
  local file="$1" rel="$2" base problems=() field missing="" mode

  base="$(basename "$file")"

  # 1. Exec bit in the working tree.
  [ -x "$file" ] || problems+=("not executable (chmod +x)")

  # 2. Exec bit in the git index — a chmod that was never committed still
  #    lands as 100644 in a fresh clone, which is what the repo is for.
  mode="$(git -C "$REPO_ROOT" ls-files -s -- "$rel" 2>/dev/null | awk '{print $1}')"
  if [ -n "$mode" ] && [ "$mode" != "100755" ]; then
    problems+=("git index mode is $mode, expected 100755 (git update-index --chmod=+x)")
  fi

  # 3. Header block: all four fields within the first 20 lines.
  for field in "${REQUIRED_HEADER_FIELDS[@]}"; do
    head -20 "$file" | grep -q "^# ${field}:" || missing="$missing $field"
  done
  [ -z "$missing" ] || problems+=("header missing:$missing")

  # 4. set line. Reporters (verify.sh, doctor.sh) run every check, so they
  #    deliberately omit -e. See docs/module-contract.md.
  case "$base" in
    verify.sh|doctor.sh)
      grep -qE '^set -uo pipefail' "$file" \
        || problems+=("expected 'set -uo pipefail' (reporters must not abort early)") ;;
    *)
      grep -qE '^set -euo pipefail' "$file" \
        || problems+=("expected 'set -euo pipefail'") ;;
  esac

  # 5. Sources the shared logging library.
  grep -q 'shared/logging.sh' "$file" || problems+=("does not source shared/logging.sh")

  # 6. Calls require_not_root.
  grep -q 'require_not_root' "$file" || problems+=("does not call require_not_root")

  # 7. uninstall.sh must refuse to act without --yes.
  if [ "$base" = "uninstall.sh" ]; then
    if ! { grep -q 'ASSUME_YES' "$file" && grep -q -- '--yes' "$file"; }; then
      problems+=("no --yes guard (must dry-run and exit 0 without --yes)")
    fi
    # Matches the -p flag in every spelling: `read -p`, `read -r -p`, and the
    # combined `read -rp` (where -p is not preceded by a literal `-`). Walks
    # whole tokens so intervening flags and their arguments are allowed.
    if grep -qE '^[[:space:]]*read[[:space:]]+([^[:space:]]+[[:space:]]+)*-[[:alnum:]]*p' "$file"; then
      problems+=("uses an interactive read -p prompt (use the --yes flag instead)")
    fi
    if [ "$DRY_RUN_UNINSTALL" -eq 1 ]; then
      # stdin from /dev/null so an interactive prompt fails instead of blocking
      # on a read whose prompt went to the swallowed stdout; timeout so any
      # other blocking call fails loudly rather than hanging the linter.
      if timeout 60 bash "$file" </dev/null >/dev/null 2>&1; then
        ok "$rel: dry run (no args) exited 0"
      else
        fail "$rel: dry run (no args) exited non-zero"
      fi
    fi
  fi

  if [ "${#problems[@]}" -eq 0 ]; then
    ok "$rel"
  else
    for field in "${problems[@]}"; do
      fail "$rel: $field"
    done
  fi
}

# ---------------------------------------------------------------------------
# Per-module checks.
# ---------------------------------------------------------------------------
check_module() {
  local dir="$1" rel="$2" required f script_rel

  # Required files.
  for required in README.md scripts/install.sh scripts/verify.sh scripts/uninstall.sh; do
    if [ -f "$dir/$required" ]; then
      ok "$rel/$required present"
    else
      fail "$rel/$required MISSING (required by the contract)"
    fi
  done

  # Every script under scripts/ — required and optional alike. Nothing under
  # canonical/, platform-notes/ or integrations/ is scanned: those are payload
  # and documentation, not module scripts (docs/module-contract.md § Exclusions).
  if [ -d "$dir/scripts" ]; then
    for f in "$dir"/scripts/*.sh; do
      [ -e "$f" ] || continue
      script_rel="${f#"$REPO_ROOT"/}"
      check_script "$f" "$script_rel"
    done
  fi

  # Reachable from at least one profile.
  if grep -rqF "$rel/" "$REPO_ROOT/profiles/" 2>/dev/null; then
    ok "$rel referenced by a profile"
  else
    fail "$rel is referenced by NO file in profiles/ — it would never be installed"
  fi
}

# ---------------------------------------------------------------------------
# Repo-wide invariants.
# ---------------------------------------------------------------------------
check_no_loose_root_scripts() {
  local loose
  loose="$(find "$REPO_ROOT" -maxdepth 1 -name '*.sh' -printf '%f\n' 2>/dev/null)"
  if [ -z "$loose" ]; then
    ok "no loose *.sh at the repo root"
  else
    while IFS= read -r f; do
      fail "loose script at the repo root: $f (belongs in a module's scripts/ or in scripts/)"
    done <<< "$loose"
  fi
}

check_profile_links() {
  local pf rel target abs broken total dir base
  for pf in "$REPO_ROOT"/profiles/*.md; do
    [ -e "$pf" ] || continue
    rel="profiles/$(basename "$pf")"
    broken=0
    total=0
    while IFS= read -r target; do
      case "$target" in
        http://*|https://*|mailto:*|'#'*) continue ;;
      esac
      target="${target%%#*}"
      [ -z "$target" ] && continue
      total=$((total + 1))
      dir="$(dirname "$target")"
      base="$(basename "$target")"
      abs="$(cd "$REPO_ROOT/profiles" && cd "$dir" 2>/dev/null && pwd)/$base"
      if [ -e "$abs" ]; then
        continue
      fi
      log_error "  broken link in $rel -> $target"
      broken=$((broken + 1))
    done < <(grep -oE '\]\([^)]+\)' "$pf" | sed -E 's/^\]\(//; s/\)$//')
    if [ "$broken" -eq 0 ]; then
      ok "$rel: all $total relative links resolve"
    else
      fail "$rel: $broken of $total relative links are broken"
    fi
  done
}

# Guardrail: the two sourced libraries must stay non-executable. They are
# libraries, not entry points; an exec bit on them invites direct invocation.
check_libraries_not_executable() {
  local lib mode bad
  for lib in \
    "shared/logging.sh" \
    "software/development/claude-code/canonical/shell/cc-functions.sh"; do

    # A missing file is not a pass. Without this, moving or renaming the
    # library would silently turn the only assertion protecting live
    # infrastructure into a green line about a path that is not there.
    if [ ! -e "$REPO_ROOT/$lib" ]; then
      fail "$lib is MISSING — cannot vouch for a sourced library that is not there"
      continue
    fi

    bad=0
    if [ -x "$REPO_ROOT/$lib" ]; then
      fail "$lib is executable in the working tree — it is a sourced library and must stay mode 100644"
      bad=1
    fi

    # The contract states the requirement as the git index mode: a chmod -x
    # that was never committed still lands as 100755 in a fresh clone.
    mode="$(git -C "$REPO_ROOT" ls-files -s -- "$lib" 2>/dev/null | awk '{print $1}')"
    if [ -n "$mode" ] && [ "$mode" != "100644" ]; then
      fail "$lib git index mode is $mode, expected 100644 for a sourced library (git update-index --chmod=-x)"
      bad=1
    fi

    if [ "$bad" -eq 0 ]; then
      ok "$lib is correctly non-executable (sourced library)"
    fi
  done
}

# ---------------------------------------------------------------------------
main() {
  local cat_dir mod_dir rel

  section "Modules"
  for cat_dir in "$REPO_ROOT"/software/*/; do
    [ -d "$cat_dir" ] || continue
    for mod_dir in "$cat_dir"*/; do
      [ -d "$mod_dir" ] || continue
      mod_dir="${mod_dir%/}"
      rel="${mod_dir#"$REPO_ROOT"/}"
      printf '\n-- %s --\n' "$rel"
      check_module "$mod_dir" "$rel"
    done
  done

  section "Repo-wide"
  check_no_loose_root_scripts
  check_libraries_not_executable
  check_profile_links

  printf '\n== Summary: %d OK, %d WARN, %d FAIL ==\n' "$OK_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
  if [ "$FAIL_COUNT" -eq 0 ]; then
    log_ok "Module contract satisfied."
    return 0
  fi
  log_error "$FAIL_COUNT contract violation(s). See docs/module-contract.md."
  return 1
}

main
