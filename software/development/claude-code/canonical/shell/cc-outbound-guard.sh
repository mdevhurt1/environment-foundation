#!/usr/bin/env bash
# cc-outbound-guard.sh — PreToolUse hook. Blocks agent-initiated publication
# under the CEO's identity; leaves reads, clones, fetches and pushes alone.
#
# Why this exists (outbound-posting-gate; CEO standing rule 2026-09-04):
#
#   Every public-facing PR, issue, comment or post goes out MANUALLY, by the
#   CEO. An agent's job ends at a staged, swept, ready-to-paste draft. That
#   rule first existed as a memory, and a rule that depends on being
#   remembered fails OPEN the one time it is forgotten, while publication
#   under the CEO's name is irreversible — GitHub keeps edit history visible.
#   So the rule is enforced here instead, where forgetting it changes nothing.
#
# Why a hook and not only permissions.deny globs. Measured 2026-09-04 against
# Claude Code 2.1.236 with the deny rule `Bash(zzzgh issue create:*)` live:
#
#   zzzgh issue create --title x     DENIED
#   zzzgh  issue create --title x    DENIED   (the matcher collapses whitespace)
#   cd /tmp && zzzgh issue create    DENIED   (it splits compound commands)
#   bash -c 'zzzgh issue create …'   not denied by the rule
#   zzzgh issue "create" --title x   PERMITTED    <-- one pair of quotes
#
# Quoting a single word walks through a glob deny rule. This guard matches on a
# NORMALISED command — quotes stripped, whitespace collapsed, case folded — so
# both of those spellings land on the same string as the plain one.
#
# And the hole no glob can express at all: `gh api` is a read or a write
# depending on flags that carry no verb. Any -f/-F/--field/--raw-field/--input
# makes `gh api` default to POST. `Bash(gh api:*)` would break every read;
# omitting it leaves the widest hole on the surface. Telling them apart needs
# code, and this is the code.
#
# WHAT THIS DOES NOT STOP, stated plainly so nobody mistakes it for a sandbox:
# a determined caller can still reach the network through a python one-liner,
# an indirected command name, or a base64'd payload. The threat model here is
# an agent that FORGOT the rule and typed the obvious command — not one working
# to defeat the gate. Removing the capability (a fine-grained PAT without
# issues/PR write) is the layer that makes posting impossible rather than
# forbidden; see the task report. This layer makes it hard to do by accident.
#
# There is deliberately NO environment-variable override. Any escape hatch is
# reachable by the very session being gated, which would make the gate
# advisory again. The way out is a human at their own terminal.
#
# Contract (Claude Code PreToolUse): a JSON payload on stdin; exit 0 permits
# the call, exit 2 blocks it and feeds this script's stderr back to the model.
#
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, coreutils, grep; jq optional (there is a no-jq path)
# Idempotent. Read-only: inspects, never executes.

set -uo pipefail

payload=$(cat)

# --- extract the command -------------------------------------------------
#
# jq gives the command field exactly. Without jq — or on a payload shape this
# does not recognise — fall back to scanning the WHOLE raw stdin. That is
# deliberately over-broad: it can block on a posting verb that appears only in
# a description. A false block costs one message; a false allow costs a
# published post that cannot be unpublished, so the fallback errs toward the
# recoverable failure.

cmd=""
if command -v jq >/dev/null 2>&1 \
   && tool=$(printf '%s' "$payload" | jq -re '.tool_name // empty' 2>/dev/null); then
    # A parsed payload for any other tool is none of this guard's business.
    [ "$tool" = "Bash" ] || exit 0
    cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)
else
    cmd="$payload"
fi

# --- normalise -----------------------------------------------------------
#
# nq  quotes removed, line continuations and whitespace collapsed, case KEPT.
#     Used where case is load-bearing: curl's -F (form POST) and -f (fail
#     silently) are different flags, and folding case would conflate them.
# n   nq, lowercased. Used for subcommand words, so `GH ISSUE CREATE` and
#     `gh issue create` are one string.

nq=$(printf '%s' "$cmd" \
    | tr -d '"'"'" \
    | tr '\n\t' '  ' \
    | sed -e 's/\\ / /g' -e 's/  */ /g')
n=$(printf '%s' "$nq" | tr '[:upper:]' '[:lower:]')

# has <extended-regex> [subject] -- match against $n unless a subject is given.
#
# A here-string, NOT `printf … | grep -Eq`. grep -q stops at the first match
# without draining stdin, which is the early-exit pipe-consumer shape doctor.sh
# check 9 rejects in a pipefail script: the writer can take SIGPIPE and
# `pipefail` then surfaces 141, which `has` would read as NO MATCH — a guard
# failing OPEN on long input. Measured here, the pipeline form did NOT actually
# fail: bash's *builtin* printf survives the closed pipe and the pipeline still
# returned 0 at 500K. The here-string is used anyway, because the safety of
# that shape rests on which printf bash happens to run, and a gate should not
# rest on that.
has() { grep -Eq "$1" <<<"${2-$n}"; }

# A leading boundary that a shell operator satisfies: `| gh issue create` and
# `&& gh issue create` must match, `zzzgh issue create` must not. `:` and `,`
# are in the set for the no-jq fallback, which scans raw stdin where the verb
# arrives as `"command":"gh issue create …"` with the quotes already stripped.
B='(^| |;|&|\||\(|`|=|:|,)'

reason=""

# --- gh: the verbs that publish -----------------------------------------
#
# The allowed side of each pair is the one the daily loop runs constantly:
# list, view, checkout, diff, clone, search, auth status. Blocking those would
# get the gate switched off, and a gate that is off protects nothing.

if   has "${B}gh issue (create|comment|edit|close|reopen|delete|lock|unlock|pin|unpin|transfer)\b"; then
    reason="gh issue subcommand that writes to a public tracker"
elif has "${B}gh pr (create|comment|edit|review|merge|close|reopen|ready)\b"; then
    reason="gh pr subcommand that writes to a public repository"
elif has "${B}gh (release|gist|repo|secret|workflow|label|milestone|project) (create|edit|delete|upload|set|run|clone-noop)\b" \
     && ! has "${B}gh repo (clone|view|list|fork|sync)\b"; then
    reason="gh subcommand that creates or edits public content"
elif has "${B}gh alias (set|delete)\b"; then
    # `gh alias set pc 'pr create'` renames the forbidden verb into one no
    # name-based rule knows about, and every later `gh pc` posts. Defining the
    # alias is the posting-shaped act; `gh alias list` is not.
    reason="gh alias definition (an alias can rename a posting verb past this gate)"

# --- gh api: read or write, decided by flags that carry no verb -----------
elif has "${B}gh api\b" && {
        has ' (-x|--method) (post|put|patch|delete)\b' \
        || has ' (--field|--raw-field|--input)\b' \
        || has ' -[fF] ' "$nq" \
        || { has 'graphql' && has 'mutation'; }
     }; then
    reason="gh api call that mutates (explicit verb, a field flag, or a graphql mutation)"

# --- raw HTTP under the keyring token ------------------------------------
#
# Host-scoped on purpose: a POST to an internal service is ordinary work, and
# blocking every POST on the machine would be a different (and wrong) policy.
elif has '(api\.|uploads\.|gist\.)?github\.com' && {
        has ' -X (POST|PUT|PATCH|DELETE)\b' "$nq" \
        || has ' --request (POST|PUT|PATCH|DELETE)\b' "$nq" \
        || has ' (-d|--data|--data-raw|--data-binary|--data-urlencode|--json|-T|--upload-file) ' "$nq" \
        || has ' -F ' "$nq" \
        || has ' --(post-data|post-file|method=(POST|PUT|PATCH|DELETE))' "$nq"
     }; then
    reason="HTTP request that writes to github.com under the CEO's credentials"

# --- the interpreter detour ----------------------------------------------
#
# Blocked because it is the OBVIOUS next move, not because it is clever. An
# agent that hits the gh refusal and still believes it must file the issue
# reaches for the language already on the box, and urllib posts as well as gh
# does. The other red-team evasions (variable indirection, base64, write-then-
# run) all require deciding to defeat the gate; this one only requires wanting
# to finish the task, which is precisely the failure this gate exists for.
elif has "${B}(python3?|node|perl|ruby|php) " \
     && has 'github\.com' \
     && has '(post|put|patch|delete|urlopen|requests\.|http\.client|fetch\()'; then
    reason="interpreter code reaching github.com with a write-shaped call"

# --- other forges, for the day one of these gets installed ---------------
elif has "${B}(glab|hub|tea) (issue|mr|pr|release) (create|comment|note|update|close)\b"; then
    reason="forge CLI subcommand that publishes"
fi

[ -n "$reason" ] || exit 0

# --- refuse, and route ---------------------------------------------------
#
# A refusal that does not say what to do instead gets worked around, so this
# names the rule, the next action, and the absence of an override.

cat >&2 <<'MSG'
BLOCKED by cc-outbound-guard: this command posts publicly under the CEO's identity.

CEO standing rule (2026-09-04): every public-facing PR, issue, comment or post
is published MANUALLY, by the CEO. Your job ends at a staged, swept,
ready-to-paste draft — even when the CEO has already approved the content.

Do this instead:
  1. Write the draft to the task folder, one file per field:
       ~/vault/20-surface/company/tasks/<task_id>/outbound/<slug>.title
       ~/vault/20-surface/company/tasks/<task_id>/outbound/<slug>.body.md
       ~/vault/20-surface/company/tasks/<task_id>/outbound/<slug>.target
  2. Sweep the body BEFORE handing it over — both classes:
       F1 disclosure (IPs, home directories, session ids, internal hostnames)
       AI register (em-dashes, curly quotes, AI-isms)
  3. Record the duplicate/prior-art search you ran, in the draft file.
  4. Hand off one line in your report: "ready to post: <path> -> <target URL>".

Pushing a branch to the CEO's own fork or to internal Gitea is NOT posting and
is not blocked. What is blocked is anything that renders as content under the
CEO's identity on an external service.

There is no environment variable, flag or retry that turns this off — an
override an agent can reach is not a gate. If posting is genuinely required,
say so in your report and stop; the CEO posts it from their own terminal.
MSG

exit 2
