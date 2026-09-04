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
# Scope (widened by INFRA-67, after the INFRA-66 audit): the raw-HTTP branch
# was once scoped to github.com, on the sound reasoning that a POST to an
# internal service is ordinary work. But that denylisted one host instead of
# allowlisting the internal ones, so Slack webhooks, pastebins, GitLab,
# Discord, Telegram and public file-drop services were all wide open — public
# posting and vault exfiltration alike, none of it needing a GitHub credential.
# The host test is now an allowlist (INTERNAL, below), which is the policy
# itself rather than an approximation of it.
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

# --- the internal allowlist ----------------------------------------------
#
# The policy, as canonical/settings.json's own autoMode.environment block
# states it: posting beyond this machine is the CEO's act, while a request to
# an internal service is ordinary work.
#
# Until INFRA-67 the raw-HTTP branch approximated that policy with a single
# hostname — it fired only when the command contained `github.com`, and exited
# 0 on everything else. The reasoning ("a POST to an internal service is
# ordinary work") was right; the implementation inverted the wrong way round.
# INFRA-66 §3.2 measured the cost: unprompted POSTs to Slack webhooks,
# pastebin, gitlab.com, Discord, Telegram and api.githubcopilot.com all passed,
# as did a file upload of any vault path to a public drop service. None of
# those needs a GitHub credential, so the whole middle of the policy was
# uncovered.
#
# So the test is an ALLOWLIST now. Adding an internal service is a one-line
# edit here, which is the point: the list is the policy, written down.
INTERNAL='(plane\.homelab|git-docs\.homelab|localhost|127\.0\.0\.1|192\.168\.1\.[0-9]{1,3})'

reason=""

# url_targets <text> -- the hosts <text> names, one per line: scheme, userinfo,
# port and trailing dot stripped. Only `scheme://host` spellings count. A bare
# dotted token is far more often a filename than a host, and treating every one
# as a target would block `curl -d @body.json http://plane.homelab/…` on the
# strength of `body.json`.
#
# The authority token must stop at every character RFC 3986 uses to END the
# authority, or the userinfo strip below reads the WRONG host. RFC 3986 ends the
# authority at `/` (path), `?` (query), `#` (fragment), or the end of input.
# `[^ /]+` stopped only at `/` and whitespace, so `?` and `#` fell inside the
# token — and then `s/^[^@]*@//` turned the exploit's own suffix into a host
# swap (INFRA-80): a real client parses `http://evil.example?@plane.homelab` as
# host=evil.example (the `?` opens a query), but this extractor grabbed
# `evil.example?@plane.homelab` and the `@` strip left `plane.homelab`, an
# allowlisted host that was never contacted. Measured 2026-09-04 against curl
# 8.5.0 and python3 urllib: both resolve the `?@`/`#@` spellings to the host
# BEFORE the delimiter, so terminating the token at `?` and `#` realigns the
# guard with what actually gets dialled. Backslash needs no handling — curl and
# urllib both read `evil\@plane.homelab` as userinfo `evil\` + host
# plane.homelab, the same host this extractor derives, so guard and client
# already agree; and a `\` with no `@` leaves a token that matches no internal
# name and so fails closed as outbound. Stopping at `?`/`#` also fixes a latent
# false BLOCK: a legitimate internal query URL (`http://plane.homelab/x?y=1`)
# used to carry its query into the host token and miss the allowlist.
url_targets() {
    grep -oE 'https?://[^ /?#]+' <<<"$1" \
        | sed -e 's|https\?://||' -e 's/^[^@]*@//' -e 's/:[0-9]*$//' -e 's/\.$//'
}

# outbound_target -- true when this request should be treated as leaving the
# LAN: it names a host that is not on the allowlist, OR it names no internal
# host at all.
#
# That second clause is what makes the branch fail CLOSED. `curl -K post.conf`
# keeps its URL and its body in a file this guard never reads, so there is
# nothing to allowlist against; INFRA-66 §3.3 notes the config forms are
# unfixable by string matching in principle. Same for a URL hidden in a shell
# variable. The guard's standing trade applies — a false block costs one
# message, a false allow costs a post that cannot be unpublished.
outbound_target() {
    local h internal=0
    while IFS= read -r h; do
        [ -n "$h" ] || continue
        grep -qE "^${INTERNAL}$" <<<"$h" || return 0
        internal=1
    done <<<"$(url_targets "$1")"
    [ "$internal" -eq 1 ] && return 1
    return 0
}

# write_shaped_http -- curl/wget flags that carry a body or name a method.
#
# Every pattern accepts the ATTACHED and `=` spellings alongside the spaced
# one. Until INFRA-67 they required a leading AND a trailing space, so ordinary
# valid curl walked straight through (INFRA-66 §3.3): `-XPOST`, `-d@b.json`,
# `-Fa=b`, `-Tb.json`, `--request=POST`, `--data={…}` and `--json=@b.json`. The
# audit confirmed curl parses the attached form rather than rejecting it —
# `curl -XPOST -d@/dev/null --max-time 2 http://127.0.0.1:1/` returns rc=7
# (connection refused, flags parsed), not rc=2 (unknown option).
#
# --form, --form-string and --data-ascii were missing from the set outright and
# passed even spaced. -K/--config are write-shaped by default, since the guard
# cannot see what the config file asks for.
#
# The subject is a segment of $nq, NOT the lowercased $n: case is load-bearing
# here, because curl's -F (form POST) and -f (fail silently) are different
# flags and folding case would conflate them.
write_shaped_http() {
    has ' -X ?(POST|PUT|PATCH|DELETE)\b' "$1" \
    || has ' --request[= ](POST|PUT|PATCH|DELETE)\b' "$1" \
    || has ' (-d|-F|-T)[ =]?[^ -]' "$1" \
    || has ' --(data|data-raw|data-binary|data-ascii|data-urlencode|json|form|form-string|upload-file)[= ]' "$1" \
    || has ' (-K|--config)[= ]?[^ -]' "$1" \
    || has ' --(post-data|post-file|method=(POST|PUT|PATCH|DELETE))' "$1"
}

# raw_http_write -- true when some pipeline segment invokes curl or wget with a
# write-shaped flag against a target outside the allowlist.
#
# Everywhere else this guard matches the WHOLE normalised command, deliberately
# over-broad. Here that breadth has a concrete cost, found by probing this
# change rather than by predicting it: flags belong to the command that owns
# them, and ` -F ` is a form POST to curl but a fixed-string match to grep. On
# the whole string, `curl -s https://example.com/x | grep -F needle` — a plain
# fetch and filter — read as a write to an external host and was refused.
#
# So the flag and host tests run per segment, on the segments that actually
# invoke a client. This is not a loophole: a body piped INTO curl still lands
# in curl's own segment, and a posting segment after a harmless one is still
# its own segment. Splitting on the shell operators keeps both.
raw_http_write() {
    local seg
    while IFS= read -r seg; do
        grep -qE "${B}(curl|wget)\b" <<<"$seg" || continue
        write_shaped_http "$seg" || continue
        outbound_target "$(tr '[:upper:]' '[:lower:]' <<<"$seg")" && return 0
    done <<<"$(tr '|;&' '\n' <<<"$nq")"
    return 1
}

# scripted_http_write -- true when interpreter code on the command line
# carries an EXPLICIT HTTP-write shape whose visible targets are not all
# internal (INFRA-86; the interpreter analogue of INFRA-67's curl inversion).
#
# The shapes are tighter than the legacy github branch's loose substrings, on
# purpose. `put` matches inside `--input`, `requests\.` matches a read, and
# `fetch(` alone is a GET — loose matching is only safe while scoped to one
# hostname, and this function is not. Each alternative here names a write
# unambiguously:
#
#   .post(/.put(/.patch(/.delete(     library method calls (requests, axios…)
#   ->post( …                         perl/php arrow calls (LWP, Guzzle)
#   method= / method: naming a verb   fetch options, urllib Request(method=…)
#   request(POST …                    http.client / requests.request
#   urlopen( together with data=      urlopen only writes when it has a body
#
# The `\\?` in the method/request patterns tolerates the backslash that quote
# stripping leaves behind: `{method: \"POST\"}` normalises to `method: \post\`.
# The arrow pattern spells its dash as `[-]` because `has` hands the pattern to
# grep as its first word, and a pattern starting with `-` reads as an option.
#
# The host test is outbound_target, same as the curl branch, and its fail-
# closed clause is load-bearing here: an explicit write call whose URL lives
# in a variable or an environment lookup names no host this guard can check,
# and is refused rather than guessed at — the `curl -K` stance. Reads stay
# untouched: a call with none of these shapes never reaches the host test.
scripted_http_write() {
    { has '\.(post|put|patch|delete)\(' \
      || has '[-]>(post|put|patch|delete)\(' \
      || has '\bmethod ?[:=] ?\\?(post|put|patch|delete)\b' \
      || has 'request\( ?\\?(post|put|patch|delete)\b' \
      || { has '\burlopen\(' && has '\bdata='; }
    } || return 1
    outbound_target "$n"
}

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
        || has ' -[fF] ?[^ -]' "$nq" \
        || { has 'graphql' && has 'mutation'; }
     }; then
    reason="gh api call that mutates (explicit verb, a field flag, or a graphql mutation)"

# --- raw HTTP leaving the LAN --------------------------------------------
#
# Scoped to an actual HTTP client, not to the flags alone: ` -F ` means a form
# POST to curl and a fixed-string match to grep, and blocking `grep -F` would
# be a different (and absurd) policy. The host test is the allowlist above, so
# internal work stays ordinary and everything beyond it is publication.
elif raw_http_write; then
    reason="HTTP request that writes to a host outside the internal allowlist"

# --- the interpreter detour ----------------------------------------------
#
# Blocked because it is the OBVIOUS next move, not because it is clever. An
# agent that hits the gh refusal and still believes it must file the issue
# reaches for the language already on the box, and urllib posts as well as gh
# does. The other red-team evasions (variable indirection, base64, write-then-
# run) all require deciding to defeat the gate; this one only requires wanting
# to finish the task, which is precisely the failure this gate exists for.
#
# Two branches since INFRA-86. The general one matches explicit write shapes
# against the internal allowlist — a scripted POST to a webhook or pastebin is
# the same act as the curl spelling the raw-HTTP branch refuses, and until
# INFRA-86 it walked through because only github.com was matched here. The
# legacy github branch is kept beneath it with its original loose substrings:
# they catch sloppier github spellings than the explicit shapes do, they are
# safe only while scoped to that one host, and keeping them means this change
# strictly widens what is refused.
elif has "${B}(python3?|node|perl|ruby|php) " && scripted_http_write; then
    reason="interpreter code making an HTTP write to a host outside the internal allowlist (or one it never names)"
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

THIS IS NOT ONLY ABOUT GITHUB. The gate covers every host outside the internal
allowlist, because a Slack webhook, a pastebin, a GitLab issue, a Discord or
Telegram message and a file drop are all publication in exactly the sense the
standing rule means — and an upload of a vault path to one of them is
exfiltration besides. None of them needs a GitHub credential, so none of them
is covered by anything else.

Requests to internal services are ordinary work and are NOT blocked:
  plane.homelab, git-docs.homelab, 192.168.1.*, 127.0.0.1 / localhost
If your request was refused and its target IS internal, name the host in the
URL on the command line. A request whose URL the guard cannot see — `curl -K` /
`--config` reads both URL and body from a file, and a URL held in a shell
variable is the same shape — is refused rather than guessed at.

There is no environment variable, flag or retry that turns this off — an
override an agent can reach is not a gate. If posting is genuinely required,
say so in your report and stop; the CEO posts it from their own terminal.
MSG

exit 2
