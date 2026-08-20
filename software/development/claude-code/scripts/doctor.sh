#!/usr/bin/env bash
# Description: cc-doctor — drift detection for the Claude Code SOP install.
#              Checks the ~/.claude symlinks against canonical/, that canonical/
#              carries no secrets or absolute home paths, and that the shell
#              wrappers are wired up. Prints OK/WARN/FAIL per check and exits
#              non-zero if any FAIL.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: claude installed and configured (install.sh, configure.sh)
# Idempotent.

set -uo pipefail   # NOT -e: doctor must run all checks even if some fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

CANONICAL="$REPO_ROOT/software/development/claude-code/canonical"
CLAUDE_DIR="$HOME/.claude"

OK=0 WARN=0 FAIL=0

# Local reporters, not shared/logging.sh's log_*: these add ANSI colour and
# maintain the three counters the summary needs. Sourcing the shared library
# above is additive — log_*, require_command and require_not_root do not
# collide with ok/warn/fail/heading.
ok()   { printf '\033[01;32m[OK]\033[00m   %s\n' "$*"; OK=$((OK+1)); }
warn() { printf '\033[01;33m[WARN]\033[00m %s\n' "$*"; WARN=$((WARN+1)); }
fail() { printf '\033[01;31m[FAIL]\033[00m %s\n' "$*"; FAIL=$((FAIL+1)); }

heading() { printf '\n\033[01;34m== %s ==\033[00m\n' "$*"; }

# ---- 1. Symlinks point to canonical ----
heading "Symlinks"
check_symlink() {
    local link="$1" expect="$2"
    if [ ! -e "$link" ]; then fail "$link missing"; return; fi
    if [ ! -L "$link" ]; then warn "$link exists but is not a symlink (drift)"; return; fi
    actual=$(readlink "$link")
    if [ "$actual" = "$expect" ]; then
        ok "$link -> $expect"
    else
        fail "$link -> $actual (expected $expect)"
    fi
}
check_symlink "$CLAUDE_DIR/CLAUDE.md"             "$CANONICAL/CLAUDE.md"
check_symlink "$CLAUDE_DIR/settings.json"         "$CANONICAL/settings.json"
check_symlink "$CLAUDE_DIR/statusline-command.sh" "$CANONICAL/statusline-command.sh"
check_symlink "$CLAUDE_DIR/skills"                "$CANONICAL/skills"
check_symlink "$CLAUDE_DIR/cc-functions.sh"       "$CANONICAL/shell/cc-functions.sh"
check_symlink "$CLAUDE_DIR/model-policy.json"     "$CANONICAL/model-policy.json"

# ---- 2. canonical/ contains no secrets, no /home/<user>/ paths ----
heading "Canonical safety"
# Match secret VALUES, not variable-name references. Documentation that mentions
# "$PLANE_API_KEY" or describes which env vars to set is not a leak; an actual
# secret string in canonical is. Add new value-shape patterns here as new
# services are integrated.
secret_pattern='(sk-[a-zA-Z0-9]{20,}|sk-ant-[a-zA-Z0-9_-]{20,}|plane_api_[a-f0-9]{16,}|gh[ps]_[a-zA-Z0-9]{30,}|AKIA[0-9A-Z]{16})'
if grep -rE "$secret_pattern" "$CANONICAL" 2>/dev/null; then
    fail "secret-shaped string found in canonical/ (above)"
else
    ok "no secret-shaped strings in canonical/"
fi

# Allow ~ and $HOME but not absolute /home/<user>/ paths
if grep -rE '/home/[a-z][a-z0-9_-]*/' "$CANONICAL" 2>/dev/null \
        | grep -v '#'; then
    fail "absolute /home/<user>/ path found in canonical/ (above)"
else
    ok "no hardcoded user home paths in canonical/"
fi

# ---- 3. ~/.bashrc sources cc-functions.sh ----
heading "Shell integration"
if grep -Fq 'cc-functions.sh' "$HOME/.bashrc" 2>/dev/null; then
    ok "$HOME/.bashrc sources cc-functions.sh"
else
    fail "$HOME/.bashrc does not source cc-functions.sh (cc-* commands unavailable)"
fi

# ---- 4. settings.local.json (secrets) ----
heading "Secrets"
if [ -f "$CLAUDE_DIR/settings.local.json" ]; then
    perms=$(stat -c '%a' "$CLAUDE_DIR/settings.local.json")
    if [ "$perms" = "600" ]; then
        ok "settings.local.json present (chmod 600)"
    else
        warn "settings.local.json present but chmod $perms (expected 600)"
    fi
    if jq -e '.env.PLANE_API_KEY // empty' "$CLAUDE_DIR/settings.local.json" >/dev/null; then
        ok "settings.local.json contains PLANE_API_KEY"
    else
        warn "settings.local.json missing PLANE_API_KEY (Plane integration disabled)"
    fi
else
    fail "settings.local.json missing — run environment-secrets/install.sh"
fi

# ---- 5. age key ----
heading "sops + age"
if [ -r "$HOME/.config/sops/age/keys.txt" ]; then
    perms=$(stat -c '%a' "$HOME/.config/sops/age/keys.txt")
    if [ "$perms" = "600" ]; then
        ok "age key present (chmod 600)"
    else
        warn "age key present but chmod $perms (expected 600)"
    fi
else
    warn "age key missing — sops decrypt won't work; needed for environment-secrets"
fi

# ---- 6. Vault ----
heading "Vault"
if [ -d "$HOME/vault" ]; then
    ok "$HOME/vault exists"
    for d in 00-core 10-middle 20-surface 40-journal 60-resources 90-archive; do
        if [ -d "$HOME/vault/$d" ]; then
            ok "  $HOME/vault/$d"
        else
            warn "  $HOME/vault/$d missing"
        fi
    done
    for sub in claude-memory claude-transcripts claude-specs claude-plans inbox; do
        if [ -d "$HOME/vault/20-surface/$sub" ]; then
            ok "  $HOME/vault/20-surface/$sub"
        else
            warn "  $HOME/vault/20-surface/$sub missing"
        fi
    done
else
    warn "$HOME/vault missing — end-conversation will queue artifacts to $HOME/.claude/queue/"
fi

# ---- 7. Repo cleanliness ----
heading "Repos"
for repo in "$REPO_ROOT" "$HOME/environment-secrets"; do
    if [ -d "$repo/.git" ]; then
        if [ -z "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then
            ok "$repo is clean"
        else
            warn "$repo has uncommitted changes"
        fi
    else
        warn "$repo is not a git repo (or missing)"
    fi
done

# ---- 8. Shell-snapshot safety of cc-* helper names ----
heading "Shell snapshot safety"
# Claude Code's Bash tool does not re-run your rc files. It restores shell state
# from ~/.claude/shell-snapshots/snapshot-<shell>-*.sh, which is generated with:
#
#     typeset +f | grep -vE '^_[^_]' | while read func; do typeset -f "$func"; done
#
# That filter exists to drop zsh completion functions (conventionally named
# `_command`), and it explicitly keeps double-underscore helpers. By the same
# rule it silently drops OUR single-underscore helpers. The public cc-* function
# is captured, its `_cc_*` callees are not, and because cc-branch has no `set -e`
# it half-runs: worktree + tmux window get created, but no .cc-mode, no
# session_id, no tree slot and no spawned event. Enforce `__cc_*` naming.
ccf="$CANONICAL/shell/cc-functions.sh"
if [ ! -f "$ccf" ]; then
    fail "canonical/shell/cc-functions.sh missing — cannot check snapshot safety"
else
    # Scan code only: strip whole-line comments first, so the explanatory prose
    # in cc-functions.sh (which necessarily spells out the old `_cc_*` names)
    # cannot trip the check. Require at least one character after the prefix so
    # a bare `_cc_` in a trailing comment is not mistaken for an identifier.
    code=$(grep -vE '^[[:space:]]*#' "$ccf")
    hostile_defs=$(printf '%s\n' "$code" | grep -oE '^_[^_][A-Za-z0-9_]*\(\)' \
                   | tr -d '()' | sort -u)
    hostile_calls=$(printf '%s\n' "$code" | grep -oE '(^|[^A-Za-z0-9_])_cc_[A-Za-z0-9][A-Za-z0-9_]*' \
                    | grep -oE '_cc_[A-Za-z0-9_]*' | sort -u)
    if [ -n "$hostile_defs" ] || [ -n "$hostile_calls" ]; then
        fail "cc-functions.sh uses helper names the shell snapshot drops (single '_' prefix)"
        printf '       offending names:\n'
        printf '         %s\n' $(printf '%s\n%s\n' "$hostile_defs" "$hostile_calls" | sort -u)
        printf '       fix: rename to __cc_* (the snapshot filter keeps double underscores)\n'
    else
        ok "cc-* helper names survive the shell-snapshot filter (no single-underscore helpers)"
    fi
fi

# ---- 9. SIGPIPE-safe pipelines in pipefail scripts ----
heading "Pipeline SIGPIPE safety"
# A consumer that stops reading early -- head, grep -q, sed -n Nq, read, or an
# awk with a bare `exit` -- closes the pipe while its producer is still
# writing. The producer dies of SIGPIPE (exit 141), pipefail promotes that to
# the pipeline status, and errexit turns it into a silent abort that prints
# nothing at all. It only starts firing once the producer outgrows one read
# block (~8 KiB, about 400 lines of `find` output), so a script works for
# months and then stops working because the DATA grew, not the code. That is
# exactly how cc-ring-scan.sh died on tasks/ENPM808-87 on 2026-08-20.
#
# Only files that actually set pipefail are scanned: `uuidgen | tr -d - |
# head -c 22` is harmless in cc-functions.sh, which sets no pipefail and whose
# producers are bounded anyway. Add a trailing `# sigpipe-ok` to a line whose
# producer is provably smaller than a read block to silence it.
sigpipe_hits=""
while IFS= read -r f; do
    grep -qE '^[[:space:]]*set -[a-zA-Z]*o pipefail' "$f" || continue
    rel="${f#"$REPO_ROOT"/}"

    # (a) line-based early-exit consumers sitting on the right of a pipe
    hits_a=$(grep -nE '\|[[:space:]]*(head([[:space:]]|$)|grep [^|]*-[a-zA-Z]*q|sed -n [^|]*[0-9]q|read([[:space:]]|$))' "$f" \
             | grep -vE ':[[:space:]]*#' | grep -v 'sigpipe-ok')
    [ -n "$hits_a" ] && sigpipe_hits="$sigpipe_hits$(printf '%s\n' "$hits_a" | sed "s|^|$rel:|")
"

    # (b) awk programs on the right of a pipe that can `exit` before EOF. The
    # program body is single-quoted and may span many lines, so track it.
    hits_b=$(awk -v rel="$rel" '
        { line = $0; sub(/^[[:space:]]*#.*/, "", line) }
        !inprog && line ~ /\|[[:space:]]*awk/ {
            inprog = 1; start = FNR
            rest = line; sub(/.*\|[[:space:]]*awk/, "", rest); body = rest
            if (rest ~ /\047[^\047]*\047[[:space:]]*[)|]?[[:space:]]*$/ || rest !~ /\047/) { check(); inprog = 0 }
            next
        }
        inprog {
            # Accumulate the RAW line: the comment strip above would erase an
            # awk-level `# sigpipe-ok` before check() could see it.
            body = body "\n" $0
            if (line ~ /^[[:space:]]*\047/) { check(); inprog = 0 }
            next
        }
        END { if (inprog) check() }
        function check(   b) {
            # Test the opt-out BEFORE stripping awk comments -- the marker
            # lives in a comment, so the order matters.
            if (body ~ /sigpipe-ok/) return
            b = body; gsub(/#[^\n]*/, "", b)
            if (b ~ /(^|[^A-Za-z0-9_])exit([^A-Za-z0-9_]|$)/)
                printf "%s:%d: awk consumer can exit before EOF\n", rel, start
        }
    ' "$f")
    [ -n "$hits_b" ] && sigpipe_hits="$sigpipe_hits$hits_b
"
done < <(find "$CANONICAL" -name '*.sh' | sort)

if [ -n "$sigpipe_hits" ]; then
    fail "early-exit pipe consumer in a pipefail script (SIGPIPE-aborts on large input)"
    printf '%s' "$sigpipe_hits" | sed 's|^|       |'
    printf '       fix: use a consumer that reads to EOF (awk max instead of\n'
    printf '            sort|head), or mark the line # sigpipe-ok if bounded\n'
else
    ok "no early-exit pipe consumers in pipefail scripts under canonical/"
fi

# ---- 10. Model policy ----
heading "Model policy"
# Claude Code's "Default" is a MOVING REFERENT: it resolves to the most capable
# model on the account, so a newly-released model captures every unpinned
# session with no diff, no event and no line of output. On 2026-08-20 that
# moved the EA session Opus 5 -> Fable 5 unnoticed; it had already moved
# Opus 4.8 -> Opus 5 before that. The point of the policy file is not to ban
# Default -- "track-latest" is a legal, deliberate value -- but to make the
# choice exist somewhere a human signed off on.
POLICY="$CANONICAL/model-policy.json"

# -- 10a. canonical/settings.json must carry nothing model-related ----------
# ~/.claude/settings.json is a SYMLINK INTO THIS REPO, so anything the running
# app writes back lands in a version-controlled file as a diff that reads like
# a human edit and is not one. `model` has been observed drifting in as both
# "opus" and "claude-fable-5[1m]"; commit 7057e79 removed those pins by hand
# and later merges are annotated "settings.json kept from main". That is a
# convention being defended manually, over and over -- which is the definition
# of one that needs a mechanism instead.
settings_json="$CANONICAL/settings.json"
if [ ! -f "$settings_json" ]; then
    fail "canonical/settings.json missing"
else
    model_keys=$(jq -r '[paths(scalars) as $p | $p | join(".")]
                         | map(select(test("(^|\\.)(model|availableModels|enforceAvailableModels|fallbackModel)($|\\.)")))
                         | .[]' "$settings_json" 2>/dev/null)
    if [ -n "$model_keys" ]; then
        fail "canonical/settings.json carries model-related key(s) - phantom-diff trap"
        printf '       %s\n' $model_keys
        printf '       these are machine/session-local: move them to ~/.claude/settings.local.json\n'
        printf '       (the ROLE->model mapping is portable intent and belongs in model-policy.json)\n'
    else
        ok "canonical/settings.json carries no model-related keys"
    fi
fi

# -- 10b. the policy artifact itself ---------------------------------------
# FAIL, not WARN: a policy that cannot be read is indistinguishable from no
# policy at all, which is exactly the pre-work state this check exists to end.
# The wrappers refuse to launch in the same situation (__cc_resolve_model).
policy_ok=0
if [ ! -f "$POLICY" ]; then
    fail "model-policy.json missing at $POLICY"
elif ! jq -e . "$POLICY" >/dev/null 2>&1; then
    fail "model-policy.json is not valid JSON"
elif ! jq -e '.policy_version | numbers' "$POLICY" >/dev/null 2>&1; then
    fail "model-policy.json has no numeric policy_version"
elif ! jq -e '.roles | objects | length > 0' "$POLICY" >/dev/null 2>&1; then
    fail "model-policy.json has no roles object"
else
    # Value grammar. THE authoritative implementation -- cc-functions.sh
    # deliberately does not duplicate it (one implementation, everything else
    # delegates). Legal: track-latest | tier alias | exact claude-* id.
    bad_roles=$(jq -r '
        .roles | to_entries[]
        | select((.value.model // "") |
                 test("^(track-latest|opus|sonnet|fable|haiku|claude-[A-Za-z0-9._-]+(\\[1m\\])?)$") | not)
        | "\(.key)=\(.value.model // "<missing>")"' "$POLICY" 2>/dev/null)
    if [ -n "$bad_roles" ]; then
        fail "model-policy.json has role value(s) outside the legal grammar"
        printf '       %s\n' $bad_roles
        printf '       legal: "track-latest" | opus|sonnet|fable|haiku | claude-<id>[1m]\n'
    else
        n_roles=$(jq -r '.roles | length' "$POLICY")
        n_pinned=$(jq -r '[.roles[] | select(.model != "track-latest")] | length' "$POLICY")
        ok "model-policy.json valid (v$(jq -r .policy_version "$POLICY"), $n_roles roles, $n_pinned pinned)"
        policy_ok=1
    fi
fi

# -- 10c. account model roster vs the acknowledged baseline ----------------
# This is the change-detection half. WARN, never FAIL: a new model on the
# account is not an error, it is an ITEM REQUIRING A DECISION. The warning
# persists on every run until a human edits known_models in a tracked file --
# and making that edit IS the decision, so there is no separate approval
# artifact to forget about.
if [ "$policy_ok" -eq 1 ]; then
    roster_file="$HOME/.claude.json"
    if [ ! -r "$roster_file" ]; then
        warn "cannot read the account config - model roster change detection unavailable"
    else
        roster=$(jq -r '(.additionalModelOptionsCache // []) | .[].value' "$roster_file" 2>/dev/null)
        if [ -z "$roster" ]; then
            ok "account model roster is empty (nothing to acknowledge)"
        else
            unknown=""
            while IFS= read -r m; do
                [ -z "$m" ] && continue
                if ! jq -e --arg m "$m" '(.known_models // []) | index($m)' "$POLICY" >/dev/null 2>&1; then
                    unknown="$unknown $m"
                fi
            done <<< "$roster"
            if [ -n "$unknown" ]; then
                warn "new model(s) in the account roster not acknowledged by model-policy.json:"
                printf '       %s\n' $unknown
                printf '       Default may have silently moved. Decide, then record the decision:\n'
                printf '         - pin the affected roles in model-policy.json, or\n'
                printf '         - add the model to known_models to record that track-latest still applies\n'
                printf '       cost of the tier at stake: check /cost and the account usage page\n'
            else
                ok "account model roster fully acknowledged in known_models"
            fi
        fi
    fi
fi

# ---- summary ----
heading "Summary"
printf 'OK: %d  WARN: %d  FAIL: %d\n' "$OK" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
