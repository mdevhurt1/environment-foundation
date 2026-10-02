#!/usr/bin/env bash
# ritual-check.sh — session-start Step 4b (AI_ST-102): flag recurring rituals
# that are overdue. Prints a "Rituals overdue:" block only when something is
# overdue and nothing at all otherwise. Read-only; never fails the session:
# a missing input (no vault, no marker, no network) is skipped silently.
#
# Checks:
#   ring     newest state/ring-health-YYYY-MM-DD.md older than 7 days (weekly ring-maintenance)
#   verify   agents verify.sh last-run marker older than 7 days (marker absent -> skipped)
#   node     running Node major past its upstream end-of-life date (AI_ST-121)
#   gitea    INFRA-93 (monthly Gitea update check) target date in the past
#
# Overrides (tests, or a non-default layout):
#   RITUAL_TODAY=YYYY-MM-DD       today's date
#   RITUAL_STATE_DIR=<dir>        ring-health dir (default: the vault's _command-center/state)
#   RITUAL_VERIFY_MARKER=<file>   verify.sh marker (default: ~/.local/state/harness/verify-last.json);
#                                 its date is a "date": "YYYY-MM-DD" field, else the file's mtime
#   RITUAL_NODE_VERSION=vNN.x.y   instead of `node -v`
#   RITUAL_INFRA93_TARGET=YYYY-MM-DD|none   instead of a Plane GET (none = skip)
# Dependencies: bash, GNU date; curl and jq for the Plane check.

set -uo pipefail

today="${RITUAL_TODAY:-$(date +%F)}"
state_dir="${RITUAL_STATE_DIR:-$HOME/vault/20-surface/company/_command-center/state}"
verify_marker="${RITUAL_VERIFY_MARKER:-$HOME/.local/state/harness/verify-last.json}"
weekly=7

days_since() { # days_since YYYY-MM-DD -> whole days from that date to $today
    local a b
    a=$(date -d "$1" +%s 2>/dev/null) || return 1
    b=$(date -d "$today" +%s) || return 1
    echo $(( (b - a) / 86400 ))
}

out=()

# ring-maintenance: newest ring-health report by the date in its filename
if [ -d "$state_dir" ]; then
    newest=$(find "$state_dir" -maxdepth 1 -name 'ring-health-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md' -printf '%f\n' 2>/dev/null | sort | tail -n1)
    if [ -z "$newest" ]; then
        out+=("ring-maintenance: no state/ring-health-*.md found (weekly; run /ring-maintenance)")
    else
        d=${newest#ring-health-}; d=${d%.md}
        if n=$(days_since "$d") && [ "$n" -gt "$weekly" ]; then
            out+=("ring-maintenance: last run $d, $n days ago (weekly; run /ring-maintenance)")
        fi
    fi
fi

# verify.sh: only once verify.sh records a run (see AI_ST-102 follow-up); absent marker -> silent
if [ -f "$verify_marker" ]; then
    d=$(grep -oE '"date"[[:space:]]*:[[:space:]]*"[0-9]{4}-[0-9]{2}-[0-9]{2}' "$verify_marker" 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}$' | head -n1)
    [ -n "$d" ] || d=$(date -r "$verify_marker" +%F 2>/dev/null)
    if [ -n "$d" ] && n=$(days_since "$d") && [ "$n" -gt "$weekly" ]; then
        out+=("verify.sh: last run $d, $n days ago (weekly; run bash ~/environment-foundation/software/development/agents/scripts/verify.sh)")
    fi
fi

# Node: running major past upstream EOL (nodejs.org release schedule). Odd majors are
# short-lived non-LTS lines and absent from the table, so they flag as unknown.
node_v="${RITUAL_NODE_VERSION:-$(node -v 2>/dev/null || true)}"
if [ -n "$node_v" ]; then
    major=${node_v#v}; major=${major%%.*}
    case "$major" in
        18) eol=2025-04-30 ;;
        20) eol=2026-04-30 ;;
        22) eol=2027-04-30 ;;
        24) eol=2028-04-30 ;;
        *)  eol="" ;;
    esac
    if [ -z "$eol" ]; then
        out+=("node: $node_v is not in ritual-check.sh's LTS table (non-LTS or newer; update the table)")
    elif n=$(days_since "$eol") && [ "$n" -gt 0 ]; then
        out+=("node: $node_v is past end-of-life ($eol); move to a supported LTS major")
    fi
fi

# INFRA-93: the standing monthly Gitea update check rolls its target date forward each month
target="${RITUAL_INFRA93_TARGET:-}"
if [ -z "$target" ] && [ -n "${PLANE_API_KEY:-}" ] && command -v curl >/dev/null && command -v jq >/dev/null; then
    target=$(curl -s -m 4 -H "X-Api-Key: $PLANE_API_KEY" \
        "http://plane.homelab/api/v1/workspaces/homelab/issues/INFRA-93/" 2>/dev/null | jq -r '.target_date // empty' 2>/dev/null)
fi
if [ -n "$target" ] && [ "$target" != none ] && n=$(days_since "$target") && [ "$n" -gt 0 ]; then
    out+=("gitea (INFRA-93): monthly update check was due $target, $n days ago")
fi

if [ "${#out[@]}" -gt 0 ]; then
    echo "Rituals overdue:"
    printf '  - %s\n' "${out[@]}"
fi
exit 0
