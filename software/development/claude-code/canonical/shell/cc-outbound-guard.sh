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
# So the test is an ALLOWLIST now: the list is the policy, written down.
#
# Where the list lives (AI_ST-133). Loopback is the only entry this file
# carries. Every other internal host is site data, not policy, and this repo is
# public: the list used to hard-code the home LAN range here and in the refusal
# text below. It now comes from AGENTS_INTERNAL_HOSTS in ~/.config/agents/env,
# the file environment-secrets/install.sh writes from the encrypted
# settings.local.json env block. Adding an internal service is a one-line edit
# THERE. The value is a space- or comma-separated list of entries:
#
#   a hostname          exact match, e.g. tracker.internal
#   an IPv4 prefix + *  e.g. 192.0.2.* : the * covers every remaining octet
#
# The file is grepped for that one key, never sourced: sourcing would run the
# file and pull every secret in it into this hook. The guard reads the FILE
# rather than its own environment, so the verdict does not depend on how the
# runtime that spawned the hook was launched.
#
# Fail closed. A missing file, a missing or empty key, and any entry that is
# neither shape all leave loopback as the only internal host, so every other
# write is refused. Such an entry is dropped rather than turned into a regex:
# a `.*` or a bare `*` in it would allowlist the internet.
#
# This file sits beside the secrets, so editing it is no easier for an agent
# than editing this script, which was always the other way to widen the gate.
internal_entries() {
    local line
    line=$(grep -m1 -E '^(export )?AGENTS_INTERNAL_HOSTS=' "$HOME/.config/agents/env" 2>/dev/null) || return 0
    line=${line#*=}
    tr -d "\"'" <<<"$line" | tr ', ' '\n\n' | tr '[:upper:]' '[:lower:]' | while IFS= read -r e; do
        if [[ "$e" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$ ]] \
           || [[ "$e" =~ ^([0-9]{1,3}\.){1,3}\*$ ]]; then
            printf '%s\n' "$e"
        fi
    done
}
entry_regex() {
    local e=$1 known rest
    if [[ "$e" == *'*' ]]; then
        known=$(tr -cd . <<<"$e"); rest=$((4 - ${#known}))
        e=${e%.\*}; e=${e//./\\.}
        printf '%s(\\.[0-9]{1,3}){%d}' "$e" "$rest"
    else
        printf '%s' "${e//./\\.}"
    fi
}
INTERNAL_ENTRIES=$(internal_entries)
INTERNAL='localhost|127\.0\.0\.1'
while IFS= read -r e; do
    [ -n "$e" ] && INTERNAL="$INTERNAL|$(entry_regex "$e")"
done <<<"$INTERNAL_ENTRIES"
INTERNAL="($INTERNAL)"
INTERNAL_RE="^${INTERNAL}\$"

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
    # Bash builtins into the global array TARGETS, not grep|sed and not a $(…)
    # fork: this runs once per client segment, and a large heredoc yields
    # thousands of those (AI_ST-126). Same extraction, same strips.
    local rest=$1 h
    TARGETS=()
    while [[ "$rest" =~ https?://([^ /?#]+) ]]; do
        rest=${rest#*"${BASH_REMATCH[0]}"}
        h=${BASH_REMATCH[1]}
        [[ "$h" == *@* ]] && h=${h#*@}
        [[ "$h" =~ ^(.*):[0-9]*$ ]] && h=${BASH_REMATCH[1]}
        TARGETS+=("${h%.}")
    done
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
    url_targets "$1"
    for h in "${TARGETS[@]}"; do
        [ -n "$h" ] || continue
        [[ "$h" =~ $INTERNAL_RE ]] || return 0
        internal=1
    done
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
# Bash's own ERE (no grep per test, AI_ST-126); `\b` is spelled as a non-word
# character or end of input, which is what it meant here.
WS_RE=(
    ' -X ?(POST|PUT|PATCH|DELETE)([^A-Za-z0-9_]|$)'
    ' --request[= ](POST|PUT|PATCH|DELETE)([^A-Za-z0-9_]|$)'
    ' (-d|-F|-T)[ =]?[^ -]'
    ' --(data|data-raw|data-binary|data-ascii|data-urlencode|json|form|form-string|upload-file)[= ]'
    ' (-K|--config)[= ]?[^ -]'
    ' --(post-data|post-file|method=(POST|PUT|PATCH|DELETE))'
)
write_shaped_http() {
    local re
    for re in "${WS_RE[@]}"; do
        [[ "$1" =~ $re ]] && return 0
    done
    return 1
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
#
# The split happens on the RAW command, outside quotes only (AI_ST-110). It
# used to run on $nq, whose quotes are already gone, so a `;` inside a quoted
# `-d '{…}'` body ended curl's segment early and orphaned its URL into the next
# one; the curl segment then named no host and failed closed on an ordinary
# internal Plane write.
#
# Merging text into one segment can only ADD hosts, and an added internal host
# can turn a fail-closed segment into an allowed one. Two rules keep the merge
# from rescuing a hidden target (second review, 2026-10-01):
#   - quote characters count only in shell code: an unquoted `#` at a word
#     start comments to end of line, and heredoc bodies (`<<WORD`, `<<'WORD'`,
#     `<<-WORD`) run to their terminator as data. An apostrophe in `# don't` or
#     in a heredoc line used to open a quote that swallowed a real `;`.
#   - client arguments that are not targets are masked to BODY before the host
#     test: the value of -d/--data*/--json/-F/--form*/-H/--header/-e/--referer
#     (curl) and --post-data/--body-data/--header (wget). A URL that appeared
#     only inside a body or header used to stand in for a target held in "$URL"
#     and pass as internal.
# The old operator split still stands where the quoting is ambiguous, erring
# toward the recoverable false block:
#   - the no-jq path, where $cmd is raw JSON and its quotes are JSON's;
#   - unbalanced quotes;
#   - `$'…'` ANSI-C quoting, where `\'` does not close the quote.
# A command with no quote characters keeps the old split too: nothing in it can
# swallow a separator.
#
# Newlines (AI_ST-125). An unquoted line end separates commands exactly as `;`
# does, so a var-URL call on one line no longer borrows an internal host from
# an echo on the next; a backslash-continued line still joins. A heredoc body
# is no longer part of the command it feeds: each body line becomes its own
# segment. That stops a body naming an internal URL from rescuing a `-d @-
# "$URL"` call, while a `bash <<EOF` body that runs curl is still scanned, line
# by line, as the code it is.
#
# awk, not a bash character loop: the loop took ~7s on a 60KB heredoc, and this
# runs on every Bash call. awk prints UNBALANCED instead of segments when a
# quote never closes.
#
# Latency (AI_ST-126). Everything that runs once per client segment is bash
# builtins: write_shaped_http, url_targets, outbound_target and resolve_vars
# spawn no process and open no $(…) subshell, and a variable's resolution is
# cached per name. Measured 2026-10-02 on an 844 KB `cat > f <<'EOF'` whose
# body has ~1500 `curl -X POST` lines (tests/test-outbound-guard.sh, `perf`):
#   URL literal in each line            c44f0e8  9.3 s  ->  0.6 s
#   URL in "$API", assigned on line 1   c44f0e8 56-77 s ->  0.8-1.0 s
# The runner fails any run over 5 s.
# flat_segments -- the quote-blind split: every `|;&` and every line end that a
# backslash does not continue. $nq folds newlines away, so it cannot be the
# input (AI_ST-125): a var-URL call on one line and an internal echo on the
# next would merge into one segment. On the no-jq path $cmd is raw JSON, whose
# line ends are the two characters `\n` (and a continuation is `\\\n`).
flat_segments() {
    local s=$cmd
    if [ "$cmd" = "$payload" ]; then
        s=$(sed -e 's/\\\\\\n/ /g' -e 's/\\n/\n/g' <<<"$s")
    fi
    sed -e ':a' -e '/\\$/{N;s/\\\n/ /;ba' -e '}' <<<"$s" \
        | tr -d '"'"'" | tr '\t' ' ' | sed -e 's/\\ / /g' -e 's/  */ /g' | tr '|;&' '\n'
}

segments() {
    local out
    if [ "$cmd" = "$payload" ] || [[ "$cmd" == *"\$'"* ]] || [[ "$cmd" != *[\"\']* ]]; then
        flat_segments; return
    fi
    out=$(printf '%s\n' "$cmd" | LC_ALL=C awk -v sq="'" '
        function endword(   raw, bare) {
            if (ws == 0) return
            raw = substr(o, ws); bare = raw; gsub(/["\047]/, "", bare); ws = 0
            if (mask) { o = substr(o, 1, length(o) - length(raw)) "BODY"; mask = 0; return }
            if (bare ~ /(^|\/)curl$/) client = "curl"
            else if (bare ~ /(^|\/)wget$/) client = "wget"
            if (bare ~ /^--(data|data-raw|data-binary|data-ascii|data-urlencode|json|form|form-string|header|referer|post-data|body-data)$/ \
                || (client == "curl" && bare ~ /^-[dFHe]$/)) { mask = 1; return }
            if (match(bare, /^--(data|data-raw|data-binary|data-ascii|data-urlencode|json|form|form-string|header|referer|post-data|body-data)=/))
                o = substr(o, 1, length(o) - length(raw)) substr(bare, 1, RLENGTH) "BODY"
            else if (client == "curl" && bare ~ /^-[dFHe]./)
                o = substr(o, 1, length(o) - length(raw)) substr(bare, 1, 2) "BODY"
        }
        function sep(c) { return c == "|" || c == ";" || c == "&" }
        { s = s $0 "\n" }
        END {
            n = length(s); q = ""; esc = 0; o = ""; ws = 0; mask = 0; client = ""; cm = 0; nh = 0
            for (i = 1; i <= n; i++) {
                c = substr(s, i, 1)
                if (esc) { o = o (c == "\n" ? " " : c); esc = 0; continue }
                if (cm) {                              # comment: quote characters are text
                    if (c != "\n") { o = o (sep(c) ? "\n" : c); continue }
                    cm = 0
                }
                if (q == "" && c == "\n") {            # end of a shell line: a separator
                    endword(); mask = 0; client = ""; o = o "\n"
                    for (k = 1; k <= nh; k++) {          # heredoc bodies: data up to the terminator
                        while (i < n) {
                            j = index(substr(s, i + 1), "\n"); if (j == 0) j = n - i
                            line = substr(s, i + 1, j - 1); i = i + j
                            t = line; if (hd[k]) sub(/^\t+/, "", t)
                            if (t == ht[k]) { o = o "\n"; break }
                            gsub(/[|;&]/, "\n", line)
                            # Each body line is its own segment, never part of the
                            # command it feeds; a trailing backslash joins the next
                            # line, so `bash <<EOF` bodies keep continued curl calls.
                            if (sub(/\\$/, "", line)) o = o line " "; else o = o line "\n"
                        }
                    }
                    nh = 0; continue
                }
                if (q == "" && c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t\n;|&()]/)) {
                    endword(); cm = 1; o = o c; continue
                }
                if (q == "" && c == "<" && substr(s, i + 1, 1) == "<" && substr(s, i + 2, 1) != "<") {
                    endword(); j = i + 2; dash = 0
                    if (substr(s, j, 1) == "-") { dash = 1; j++ }
                    while (substr(s, j, 1) ~ /[ \t]/) j++
                    w = ""
                    while (j <= n && substr(s, j, 1) !~ /[ \t\n;|&<>()]/) { w = w substr(s, j, 1); j++ }
                    gsub(/["\047\\]/, "", w)
                    if (w != "") { nh++; ht[nh] = w; hd[nh] = dash }
                    o = o substr(s, i, j - i); i = j - 1; continue
                }
                if (c == "\\" && q != sq) { if (ws == 0) ws = length(o) + 1; o = o c; esc = 1; continue }
                if (q == "" && (c == sq || c == "\"")) q = c
                else if (q != "" && c == q) q = ""
                else if (q == "" && sep(c)) { endword(); mask = 0; client = ""; o = o "\n"; continue }
                else if (q == "" && (c == " " || c == "\t")) { endword(); o = o c; continue }
                if (c == "\n") c = " "
                if (ws == 0) ws = length(o) + 1
                o = o c
            }
            endword()
            if (q != "") { print "UNBALANCED"; exit }
            print o
        }')
    if [ "$out" = UNBALANCED ]; then
        flat_segments; return
    fi
    # Normalise each segment exactly as $nq is built.
    printf '%s\n' "$out" | tr -d '"'"'" | tr '\t' ' ' | sed -e 's/\\ / /g' -e 's/  */ /g'
}

# resolve_vars <segment> -- the segment with each `$NAME` / `${NAME}` replaced
# by every URL this same command assigns to NAME (AI_ST-125).
#
# Splitting on newlines made a common, legitimate script shape fail closed:
#   PROM=http://prom.internal:9090
#   curl --data-urlencode "query=up" "$PROM/api/v1/query"
# It only ever passed because the two lines merged into one segment, which is
# also exactly how a var-URL call borrowed an unrelated echo's internal host.
# Resolving the variable keeps the first and refuses the second. Narrowly:
#   - only a segment that is nothing but `[export|local|declare|readonly]
#     NAME=scheme://...` counts as an assignment. A prefix assignment
#     (`NAME=... curl "$NAME"`) does not: the shell expands $NAME before the
#     prefix takes effect, so its URL is never the target;
#   - EVERY assignment of NAME is substituted, so a later external value still
#     reaches the host test, and any assignment that is not a plain URL, or a
#     `read`/`for`/`mapfile`/`+=`/`printf -v` that could set NAME, leaves the
#     reference unresolved, which fails closed as before.
# What NAME resolves to is a property of the whole command, so it is worked out
# once per name and cached (AI_ST-126): resolving it per client segment grepped
# the full segment list each time, and an 844 KB heredoc of `"$PROM/..."` lines
# took 56 s, most of the hook timeout. An empty value means unresolved.
declare -A VAR_VALS=()
var_values() {
    local name=$1 vals="" line
    if ! grep -qE "(^| )(for|read|mapfile|readarray|getopts|select|unset)( [^ ]+)* ${name}( |$)|(^| )${name}\+=|-v ${name}( |$)" <<<"$segs"; then
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            if [[ "$line" =~ ^\ ?((export|local|declare|readonly)\ )?${name}=(https?://[^\ ]+)\ ?$ ]]; then
                vals="$vals ${BASH_REMATCH[3]}"
            else
                vals=""; break
            fi
        done <<<"$(grep -E "(^| )${name}=" <<<"$segs")"
        [[ "$vals" == *'$'* ]] && vals=""
    fi
    VAR_VALS[$name]=$vals
}

# Sets RESOLVED rather than printing it, so the caller needs no $(…) subshell
# and the VAR_VALS cache survives between segments.
resolve_vars() {
    local seg=$1 rest=$1 name vals
    local -A seen=()
    while [[ "$rest" =~ \$\{?([A-Za-z_][A-Za-z0-9_]*) ]]; do
        rest=${rest#*"${BASH_REMATCH[0]}"}
        name=${BASH_REMATCH[1]}
        [ -n "${seen[$name]+x}" ] && continue
        seen[$name]=1
        [ -n "${VAR_VALS[$name]+x}" ] || var_values "$name"
        vals=${VAR_VALS[$name]}
        [ -n "$vals" ] || continue
        while [[ "$seg" =~ ^(.*)\$(\{${name}\}|${name})([^A-Za-z0-9_].*)?$ ]]; do
            seg="${BASH_REMATCH[1]}$vals${BASH_REMATCH[3]}"
        done
    done
    RESOLVED=$seg
}

raw_http_write() {
    local seg segs
    grep -qE "${B}(curl|wget)\b" <<<"$nq" || return 1
    segs=$(segments)
    # One grep picks the client segments (the same test the loop used to run per
    # segment): a big heredoc splits into thousands, and a process each cost seconds.
    while IFS= read -r seg; do
        [ -n "$seg" ] || continue
        write_shaped_http "$seg" || continue
        # Prefix assignments are not targets (see resolve_vars).
        while [[ "$seg" =~ ^\ ?[A-Za-z_][A-Za-z0-9_]*=[^\ ]*\ (.*)$ ]]; do seg=${BASH_REMATCH[1]}; done
        [[ "$seg" == *'$'* ]] && { resolve_vars "$seg"; seg=$RESOLVED; }
        outbound_target "${seg,,}" && return 0
    done <<<"$(grep -E "${B}(curl|wget)\b" <<<"$segs")"
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

# --- the sink test: file writes are data, not calls (AI_ST-109) ----------
#
# Ruled 2026-09-25 (day-plan-2026-09-25/outbound-guard-ruling.md): when EVERY
# sink of a command is a file path, client text inside it is data and the guard
# stands down. Writing a file that contains `curl` posts nothing; if the file is
# run later, that run is its own Bash call and is gated then. Nine recorded
# false blocks (harness-friction.md, 2026-09-14..29) were all this shape: a
# heredoc creating a spec whose body cites URLs, the guard's own prescribed
# outbound draft quoting the `gh repo create` it stages, a script authored with
# `curl -K -` and its URL in a variable, and a `printf >>` of a friction line
# quoting the call it describes. Each ended at the Write tool and prevented
# nothing.
#
# It runs on the RAW $cmd: $nq has lost the quotes and line ends that say what
# is code and what is data. It stands down only when it can show the whole
# command is inert, and fails closed (gates as before) on anything else:
#   - every simple command's first word is one of a short list that cannot
#     reach the network: cat tee printf echo mkdir touch chmod cd true. Every
#     other word, including bash/sh/python/ssh/sudo/env/xargs, `{`, `(`, `if`,
#     `for`, a `$VAR` command and a prefix assignment (`X=1 cat`), gates. A
#     plain assignment (`D=~/vault/...`) is allowed, except to PATH, IFS,
#     BASH_ENV, ENV, LD_* and the like, which change what a later word runs;
#   - so a pipe or heredoc into an interpreter, a `bash script.sh` after the
#     write, and a real client anywhere on the line all keep the gate on: one
#     network sink is enough;
#   - command and process substitution (`$(`, a backtick, `<(`, `>(`) execute,
#     so they gate: outside single quotes in code, and anywhere in the body of
#     an UNQUOTED heredoc, which the shell expands. A quoted heredoc
#     (`<<'EOF'`, `<<"EOF"`, `<<\EOF`) body is literal and is not inspected;
#   - `$'…'` quoting, an unclosed quote, an unterminated heredoc, any mention
#     of /dev/tcp or /dev/udp (a redirect there IS a network sink), and the
#     no-jq path (raw JSON, quotes unknowable) all gate.
# The gh/forge branches sit behind this test too: L15 (2026-09-22) was the gh
# branch refusing a draft that quoted `gh repo create`, so the ruling's "those
# branches never false-positived" was already out of date. A command made only
# of the words above cannot run gh.
#
# Residual risk, accepted by the ruling: a staged file could be executed by
# something this hook never sees (cron, systemd, a remote host).
files_only_sinks() {
    [ "$cmd" != "$payload" ] || return 1
    [[ "$cmd" == *[Dd][Ee][Vv]/[Tt][Cc][Pp]* || "$cmd" == *[Dd][Ee][Vv]/[Uu][Dd][Pp]* ]] && return 1
    [ "$(printf '%s\n' "$cmd" | LC_ALL=C awk -v sq="'" '
        function endword(   bare) {
            if (!inw) return
            inw = 0; bare = w; w = ""
            if (redir) { redir = 0; return }          # a redirect target is a path
            if (ncw) return                           # an argument
            # NAME=value, with no quote before the `=` (qw: where a quote first began)
            # Not one that changes how later words run: PATH could resolve `cat`
            # to anything.
            if (match(bare, /^[A-Za-z_][A-Za-z0-9_]*=/) && (qw == 0 || qw > RLENGTH)) {
                if (bare ~ /^(PATH|BASH_ENV|ENV|IFS|LD_[A-Z_]*|PROMPT_COMMAND|SHELLOPTS|BASHOPTS|BASH_[A-Z_]*|GLOBIGNORE)=/) bad = 1
                assign = 1; return
            }
            if (assign) bad = 1                       # prefix assignment: gate
            else if (bare !~ /^(cat|tee|printf|echo|mkdir|touch|chmod|cd|true)$/) bad = 1
            ncw = 1
        }
        function newcmd() { endword(); ncw = 0; assign = 0; redir = 0 }
        function addc(c) { if (!inw) { inw = 1; qw = 0 } ; w = w c }
        { s = s $0 "\n" }
        END {
            n = length(s); q = ""; bad = 0; nh = 0
            for (i = 1; i <= n && !bad; i++) {
                c = substr(s, i, 1); c2 = substr(s, i, 2)
                if (q == sq) { if (c == sq) q = ""; else w = w c; continue }
                if (q == "\"") {
                    if (c == "\\") { w = w substr(s, i + 1, 1); i++; continue }
                    if (c2 == "$(" || c == "`") { bad = 1; break }
                    if (c == "\"") q = ""; else w = w c
                    continue
                }
                # unquoted shell code
                if (c == "\\") {
                    if (substr(s, i + 1, 1) == "\n") { i++; continue }
                    addc(substr(s, i + 1, 1)); i++; continue
                }
                if (c2 == "$(" || c == "`" || c2 == "$" sq || c2 == "<(" || c2 == ">(" || c == "(" || c == ")") { bad = 1; break }
                if (c == sq || c == "\"") { if (!inw) { inw = 1; qw = 0 } ; if (!qw) qw = length(w) + 1; q = c; continue }
                if (c == "#" && !inw) { while (i < n && substr(s, i + 1, 1) != "\n") i++; continue }
                if (c == "\n") {
                    newcmd()
                    for (k = 1; k <= nh; k++) {               # heredoc bodies: data
                        found = 0
                        while (i < n) {
                            j = index(substr(s, i + 1), "\n"); if (j == 0) j = n - i
                            line = substr(s, i + 1, j - 1); i = i + j
                            t = line; if (hd[k]) sub(/^\t+/, "", t)
                            if (t == ht[k]) { found = 1; break }
                            if (!hq[k] && (index(line, "$(") || index(line, "`"))) { bad = 1; break }
                        }
                        if (!found) bad = 1
                    }
                    nh = 0; continue
                }
                if (c == ";" || c == "|" || c == "&") { newcmd(); continue }
                if (c == " " || c == "\t") { endword(); continue }
                if (c2 == "<<" && substr(s, i + 2, 1) != "<") {
                    endword(); j = i + 2; dash = 0
                    if (substr(s, j, 1) == "-") { dash = 1; j++ }
                    while (substr(s, j, 1) ~ /[ \t]/) j++
                    wd = ""
                    while (j <= n && substr(s, j, 1) !~ /[ \t\n;|&<>()]/) { wd = wd substr(s, j, 1); j++ }
                    quoted = (wd ~ /["\047\\]/); gsub(/["\047\\]/, "", wd)
                    if (wd == "") { bad = 1; break }
                    nh++; ht[nh] = wd; hd[nh] = dash; hq[nh] = quoted
                    i = j - 1; continue
                }
                if (c == "<" || c == ">") {               # redirect: the next word is a target
                    endword()
                    while (substr(s, i + 1, 1) ~ /[<>&|]/) i++
                    redir = 1; continue
                }
                addc(c)
            }
            if (q != "") bad = 1
            if (!bad) { newcmd(); if (nh) bad = 1 }
            print (bad ? "GATE" : "FILES")
        }')" = FILES ]
}

files_only_sinks && exit 0

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

MSG
# The configured list is read back here, not written into this public file.
# An agent's refusal is local, so showing it the list is fine; the repo is not.
cat >&2 <<MSG
Requests to internal services are ordinary work and are NOT blocked:
  127.0.0.1 / localhost, and the hosts in AGENTS_INTERNAL_HOSTS
  (~/.config/agents/env). Configured now: $( [ -n "$INTERNAL_ENTRIES" ] && tr '\n' ' ' <<<"$INTERNAL_ENTRIES" || echo "NONE, so every non-loopback write is refused; add the key in environment-secrets and re-run its install.sh" )
MSG
cat >&2 <<'MSG'
If your request was refused and its target IS internal, name the host in the
URL on the command line. A request whose URL the guard cannot see — `curl -K` /
`--config` reads both URL and body from a file, and a URL held in a shell
variable is the same shape — is refused rather than guessed at.

There is no environment variable, flag or retry that turns this off — an
override an agent can reach is not a gate. If posting is genuinely required,
say so in your report and stop; the CEO posts it from their own terminal.
MSG

exit 2
