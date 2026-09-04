#!/usr/bin/env bash
# Description: Behavioral tests for cc-outbound-guard.sh — the PreToolUse gate that blocks agent-initiated public posting (gh/curl/glab mutations) while leaving reads, clones and pushes alone.
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04, ubuntu-22.04 (WSL supported)
# Dependencies: bash 4+, coreutils; jq optional (the guard has a no-jq path)

set -uo pipefail   # NOT -e: every assertion must run and report.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MODULE_DIR/../../.." && pwd)"
# shellcheck source=./harness.sh
# shellcheck disable=SC1091
source "$TESTS_DIR/harness.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"
require_not_root

GUARD="${GUARD_UNDER_TEST:-$MODULE_DIR/canonical/shell/cc-outbound-guard.sh}"

t_begin "cc-outbound-guard.sh"

# =========================================================================
# WHY THIS FILE EXISTS (outbound-posting-gate)
#
# CEO standing rule 2026-09-04: every public-facing PR/issue/comment/post is
# posted MANUALLY by the CEO. Agents stage swept drafts and never post.
#
# The rule was first written down as a memory, and a memory only binds when
# it is recalled at the right moment. The gate must fail CLOSED when recall
# fails — hence a hook, not a habit.
#
# Measured 2026-09-04 against Claude Code 2.1.236, why a hook and not only
# permissions.deny globs (probe transcript in the task report):
#
#   deny rule Bash(zzzgh issue create:*)     command                      result
#   ------------------------------------     -------------------------    --------
#                                            zzzgh issue create --title   DENIED
#                                            zzzgh  issue create          DENIED (ws collapsed)
#                                            cd /tmp && zzzgh issue …     DENIED (segment split)
#                                            bash -c 'zzzgh issue create' NOT denied by the rule
#                                            zzzgh issue "create"         PERMITTED  <-- evasion
#
# Quoting a single word walks straight through a glob deny rule. The guard
# therefore matches on a NORMALISED command (quotes stripped, whitespace
# collapsed, case folded), which closes both of those holes at once. The deny
# rules stay as the cheap outer layer; this is the one that has to hold.
#
# The other thing globs cannot express: `gh api` is a READ or a WRITE depending
# on flags nobody wrote a verb for — any -f/-F/--field/--raw-field/--input
# makes gh api default to POST. Blocking Bash(gh api:*) would break every read;
# not blocking it leaves the widest hole in the surface. That needs code.
# =========================================================================

# hookin <command> -- render a PreToolUse Bash payload the way Claude Code does.
hookin() {
    if command -v jq >/dev/null 2>&1; then
        jq -nc --arg c "$1" \
            '{session_id:"t", tool_name:"Bash", tool_input:{command:$c, description:"probe"}}'
    else
        printf '{"session_id":"t","tool_name":"Bash","tool_input":{"command":"%s","description":"probe"}}' "$1"
    fi
}

# assert_blocked <desc> <command>
assert_blocked() {
    local desc="$1" cmd="$2" out rc
    out=$(hookin "$cmd" | bash "$GUARD" 2>&1)
    rc=$?
    if [ "$rc" -eq 2 ]; then
        t_pass "blocks: $desc"
    else
        t_fail "blocks: $desc" "command: $cmd" "expected rc 2, got $rc" "output: $(t_render "$out")"
    fi
}

# assert_allowed <desc> <command>
assert_allowed() {
    local desc="$1" cmd="$2" out rc
    out=$(hookin "$cmd" | bash "$GUARD" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        t_pass "allows: $desc"
    else
        t_fail "allows: $desc" "command: $cmd" "expected rc 0, got $rc" "output: $(t_render "$out")"
    fi
}

# --- 1. the plain posting verbs -----------------------------------------

assert_blocked "gh issue create"        'gh issue create --title x --body y'
assert_blocked "gh issue comment"       'gh issue comment 12 --body hi'
assert_blocked "gh issue edit"          'gh issue edit 12 --body hi'
assert_blocked "gh issue close"         'gh issue close 12'
assert_blocked "gh pr create"           'gh pr create --fill'
assert_blocked "gh pr comment"          'gh pr comment 3 --body hi'
assert_blocked "gh pr review"           'gh pr review 3 --approve'
assert_blocked "gh pr merge"            'gh pr merge 3'
assert_blocked "gh release create"      'gh release create v1.0'
assert_blocked "gh gist create"         'gh gist create notes.md --public'
assert_blocked "gh repo create"         'gh repo create newthing --public'

# --- 2. the evasions a glob deny rule lets through ------------------------
#
# Each of these is a REAL result from the 2026-09-04 probe, not a hypothetical.

assert_blocked "quoted subcommand"      'gh issue "create" --title x'
assert_blocked "single-quoted verb"     "gh issue 'create' --title x"
assert_blocked "bash -c wrapper"        "bash -c 'gh issue create --title x'"
assert_blocked "sh -c wrapper"          'sh -c "gh pr create --fill"'
assert_blocked "collapsed whitespace"   'gh   issue    create --title x'
assert_blocked "compound with &&"       'cd /tmp && gh issue create --title x'
assert_blocked "compound with ;"        'echo hi ; gh pr comment 3 --body hi'
assert_blocked "pipeline tail"          'cat body.md | gh issue create --title x --body-file -'
assert_blocked "env prefix"             'GH_TOKEN=x gh issue create --title y'
assert_blocked "mixed case"             'GH ISSUE CREATE --title x'

# --- 3. gh api: read vs write, which no glob can tell apart ---------------

assert_blocked "gh api --method POST"   'gh api --method POST repos/o/r/issues'
assert_blocked "gh api -X POST"         'gh api -X POST repos/o/r/issues'
assert_blocked "gh api -X patch lower"  'gh api -x patch repos/o/r/issues/1'
assert_blocked "gh api --method DELETE" 'gh api --method DELETE repos/o/r/issues/1'
assert_blocked "gh api -f implies POST" 'gh api repos/o/r/issues -f title=x'
assert_blocked "gh api --field"         'gh api repos/o/r/issues --field title=x'
assert_blocked "gh api --raw-field"     'gh api repos/o/r/issues --raw-field title=x'
assert_blocked "gh api --input"         'gh api repos/o/r/issues --input body.json'
assert_blocked "gh api graphql mutation" 'gh api graphql -f query="mutation { addComment }"'

assert_allowed "gh api plain read"      'gh api repos/o/r/issues'
assert_allowed "gh api read with -H"    'gh api -H "Accept: application/vnd.github+json" repos/o/r'
assert_allowed "gh api --paginate read" 'gh api --paginate repos/o/r/issues'

# --- 4. raw HTTP under the CEO's token -----------------------------------

assert_blocked "curl -X POST github"    'curl -X POST https://api.github.com/repos/o/r/issues -d @body.json'
assert_blocked "curl --data github"     'curl --data @b.json https://api.github.com/repos/o/r/issues'
assert_blocked "curl --json github"     'curl --json @b.json https://api.github.com/repos/o/r/issues'
assert_blocked "curl -F upload github"  'curl -F file=@x https://uploads.github.com/x'
assert_blocked "wget --post-data"       'wget --post-data=x https://api.github.com/repos/o/r/issues'
assert_blocked "curl -X PUT github"     'curl -X PUT https://api.github.com/repos/o/r/contents/f'

assert_allowed "curl GET github api"    'curl -s https://api.github.com/repos/o/r'
assert_allowed "curl POST elsewhere"    'curl -X POST http://service.invalid/api/v1/thing -d x'

# --- 4b. the interpreter detour -------------------------------------------
#
# Not adversarial — it is the OBVIOUS next move. An agent told "gh is blocked"
# reaches for the language it already has, and urllib posts an issue as well as
# gh does. Every other evasion in the red-team (variable indirection, base64,
# writing a script then running it) requires deciding to defeat the gate; this
# one only requires wanting to finish the task, so it is the one worth code.

assert_blocked "python urllib POST to github" \
    'python3 -c "import urllib.request; urllib.request.urlopen(urllib.request.Request(\"https://api.github.com/repos/o/r/issues\", data=b\"{}\", method=\"POST\"))"'
assert_blocked "python requests.post to github" \
    'python3 -c "import requests; requests.post(\"https://api.github.com/repos/o/r/issues\", json={})"'
assert_blocked "node fetch POST to github" \
    'node -e "fetch(\"https://api.github.com/repos/o/r/issues\", {method:\"POST\"})"'

assert_allowed "python with no github in sight" 'python3 analyze.py --input data.csv'
assert_allowed "python hello world"             'python3 -c "print(1+1)"'

# --- 5. the alias escape --------------------------------------------------
#
# `gh alias set pc 'pr create'` renames the forbidden verb into one no
# name-based rule knows about, and every later `gh pc` posts. Setting an alias
# is therefore itself a posting-shaped act.

assert_blocked "gh alias set"           "gh alias set pc 'pr create'"
assert_allowed "gh alias list"          'gh alias list'

# --- 6. what must KEEP working -------------------------------------------
#
# A gate that breaks the daily loop gets switched off, and then it protects
# nothing. Pushing to the CEO's own fork and to internal Gitea is explicitly
# NOT posting (feedback_public_posting_is_ceo_manual).

assert_allowed "git push"               'git push origin branch/x'
assert_allowed "git push force-with-lease" 'git push --force-with-lease origin main'
assert_allowed "git clone"              'git clone git@github.com:o/r.git'
assert_allowed "gh auth status"         'gh auth status'
assert_allowed "gh repo view"           'gh repo view mdevhurt1/environment-foundation'
assert_allowed "gh issue list"          'gh issue list --state open'
assert_allowed "gh issue view"          'gh issue view 12'
assert_allowed "gh pr list"             'gh pr list'
assert_allowed "gh pr view"             'gh pr view 3 --json body'
assert_allowed "gh pr checkout"         'gh pr checkout 3'
assert_allowed "gh pr diff"             'gh pr diff 3'
assert_allowed "gh search issues"       'gh search issues "duplicate check" --repo o/r'
assert_allowed "gh repo clone"          'gh repo clone o/r'
assert_allowed "ordinary text mentioning create" 'echo "draft for gh issue creation is staged"'
assert_allowed "writing the draft file" 'cat > draft.md <<EOF'

# --- 7. the block message must route, not just refuse --------------------
#
# A refusal that does not say what to do instead gets worked around. The
# message names the rule, the staging path, and the fact that there is no
# agent-usable override — the CEO's own terminal is the only way out.

OUT=$(hookin 'gh issue create --title x' | bash "$GUARD" 2>&1)
assert_contains "message names the standing rule" "CEO" "$OUT"
assert_contains "message routes to staging"       "stage" "$OUT"
assert_contains "message says posting is manual"  "MANUALLY" "$OUT"

# --- 8. non-Bash tools are none of the guard's business -------------------

OTHER='{"session_id":"t","tool_name":"Read","tool_input":{"file_path":"/tmp/gh issue create"}}'
printf '%s' "$OTHER" | bash "$GUARD" >/dev/null 2>&1
assert_eq "ignores non-Bash tool payloads" "0" "$?"

# --- 9. fail CLOSED, not open, when the payload cannot be parsed ----------
#
# The guard must not become a no-op on a machine without jq, or on a payload
# shape it does not recognise. Both fall back to scanning the raw stdin, which
# is deliberately over-broad: a false block is a nuisance, a false allow is a
# published post that cannot be unpublished.

NOJQ_PATH=$(t_minimal_path bash cat grep sed tr printf) || exit 1
out=$(hookin 'gh issue create --title x' | PATH="$NOJQ_PATH" bash "$GUARD" 2>&1)
assert_eq "blocks posting with no jq on PATH" "2" "$?"
assert_contains "no-jq block still routes" "stage" "$out"

out=$(printf 'not json at all: gh issue create' | bash "$GUARD" 2>&1)
assert_eq "blocks unparseable payload carrying a posting verb" "2" "$?"

printf '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' | bash "$GUARD" >/dev/null 2>&1
assert_eq "allows an ordinary command through the normal path" "0" "$?"

# --- 10. no agent-usable override ----------------------------------------
#
# Any env-var escape hatch is reachable by the very session being gated, so
# there is none. This asserts the absence, because "add a bypass for
# convenience" is the obvious future edit and it would silently void the gate.

out=$(hookin 'gh issue create --title x' \
    | CC_OUTBOUND_GUARD=off CC_ALLOW_POSTING=1 CC_SKIP_GUARD=1 bash "$GUARD" 2>&1)
assert_eq "env vars do not disable the guard" "2" "$?"

# --- 11. length does not change the verdict ------------------------------
#
# Padding is the cheapest thing an evader can add, so the verdict must not
# depend on how long the command is.
#
# Honest limit of these two: they do NOT prove the SIGPIPE hazard is gone. The
# guard's first cut used `printf '%s' "$cmd" | grep -Eq`, the early-exit pipe
# consumer doctor.sh check 9 rejects, and on measurement that form still
# returned 0 at 500K — bash's builtin printf survives the closed pipe. So these
# assertions pass against both the broken and the fixed shape. What actually
# holds the here-string in place is doctor check 9, not this file; these two
# only pin the length-independence.

PAD=$(head -c 100000 /dev/zero | tr '\0' 'x')
assert_blocked "posting verb behind 100K of padding" "echo $PAD ; gh issue create --title x"
assert_blocked "posting verb ahead of 100K of padding" "gh issue create --title x # $PAD"

t_finish
