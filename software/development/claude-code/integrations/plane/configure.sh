#!/usr/bin/env bash
# Description: Verifies Plane API access for Claude Code — canonical skill present,
#              credential readable from settings.local.json, instance reachable.
# Profiles:    workstation
# Platforms:   ubuntu-24.04, ubuntu-22.04
# Dependencies: claude (install.sh), configure.sh (symlinks canonical skills)
# Idempotent. Read-only — installs nothing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
# shellcheck source=../../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root
require_command claude "install Claude Code first: bash $REPO_ROOT/software/development/claude-code/scripts/install.sh"
require_command python3

PLANE_HOST="${PLANE_HOST:-plane.homelab}"
SETTINGS="$HOME/.claude/settings.local.json"
SKILL="$HOME/.claude/skills/plane-api/SKILL.md"

fail=0

# ---- 1. canonical skill must already be deployed ----
# The plane-api skill is canonical (canonical/skills/plane-api/). It arrives via
# claude-code/scripts/configure.sh, which symlinks ~/.claude/skills -> canonical/skills.
# This script deliberately does NOT copy a skill into place: doing so would create a
# real ~/.claude/skills directory and block that symlink.
log_info "Checking canonical plane-api skill..."
if [ -f "$SKILL" ]; then
    log_ok "plane-api skill present at $SKILL"
else
    log_error "plane-api skill missing — run: bash $REPO_ROOT/software/development/claude-code/scripts/configure.sh"
    fail=1
fi

# ---- 2. credential must be readable from settings.local.json ----
# Not an env var, and not in ~/.bashrc or ~/.zshrc. Provisioned by environment-secrets.
log_info "Checking PLANE_API_KEY in $SETTINGS..."
if [ ! -f "$SETTINGS" ]; then
    log_error "$SETTINGS not found"
    log_info "clone environment-secrets and run its install.sh:"
    log_info "  git clone <gitea>/mhurt/environment-secrets ~/environment-secrets"
    log_info "  ~/environment-secrets/install.sh"
    fail=1
else
    if api_key=$(python3 -c \
        "import json,os;print(json.load(open(os.path.expanduser('$SETTINGS')))['env']['PLANE_API_KEY'])" \
        2>/dev/null) && [ -n "$api_key" ]; then
        log_ok "PLANE_API_KEY readable (${#api_key} chars)"
    else
        log_error "PLANE_API_KEY not present under .env in $SETTINGS"
        log_info "re-run ~/environment-secrets/install.sh to provision it"
        fail=1
        api_key=""
    fi
fi

# ---- 3. instance must be reachable and the key accepted ----
if [ -n "${api_key:-}" ]; then
    log_info "Checking $PLANE_HOST reachability..."
    # curl already writes 000 to stdout when it cannot connect, so do not add a
    # fallback echo here — it would concatenate into 000000 and miss the case below.
    code=$(no_proxy="" NO_PROXY="" curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        -H "X-Api-Key: $api_key" \
        "http://$PLANE_HOST/api/v1/workspaces/homelab/projects/" 2>/dev/null) || true
    [ -z "$code" ] && code="000"
    case "$code" in
        200) log_ok "Plane API reachable at $PLANE_HOST and key accepted" ;;
        401|403) log_error "$PLANE_HOST reachable but key rejected (HTTP $code) — rotate or re-provision"; fail=1 ;;
        000) log_error "cannot reach $PLANE_HOST — check DNS, the VM, and UDM IPS inter-VLAN rules"; fail=1 ;;
        *) log_warn "unexpected HTTP $code from $PLANE_HOST"; fail=1 ;;
    esac
fi

if [ "$fail" -eq 0 ]; then
    log_ok "Plane integration verified — the plane-api skill is ready to use"
else
    log_error "Plane integration incomplete — resolve the errors above"
    exit 1
fi
