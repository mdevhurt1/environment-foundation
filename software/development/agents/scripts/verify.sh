#!/usr/bin/env bash
# Description: Proves every runtime reads AGENTS.md, sees the env, lists skills
# Profiles:    workstation, workplace
# Platforms:   ubuntu-24.04
# Dependencies: install.sh, ~/environment-secrets/install.sh, the four runtimes
# Exit 0 only when every required check passes. Run from any directory.
# NOTE: no -e — a reporter runs every check (docs/module-contract.md); pipefail is safe here, every piped reply fits the pipe buffer.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
source "$REPO_ROOT/shared/logging.sh"
require_not_root
marker="HARNESS-RESET-OK"
q="If your instructions name a vault directory you may write to, reply with exactly: $marker <that directory> — then, on the same line, the three vault directories you must never write to. Otherwise reply NO-INSTRUCTIONS."
# The kept skills (R5 + the three restored in v2.0.0, AI_ST-108). One list, asserted in both directions below (AI_ST-115).
want="brainstorming end-conversation plane-api ring-maintenance session-start systematic-debugging test-driven-development verification-before-completion writing-plans"
nwant=$(wc -w <<<"$want")

# The check/fails pattern of docs/module-contract.md, plus a pass count for the summary line (AI_ST-130)
pass=0; fails=0
pass_row() { log_ok "$1"; pass=$((pass + 1)); }
fail_row() { log_error "$1"; fails=$((fails + 1)); }
check() { # check "<label>" <command...>: PASS or FAIL on the command's exit status
    local label="$1"; shift
    if "$@" &>/dev/null; then pass_row "$label"; else fail_row "$label"; fi
}
instructed() { # instructed <name> <reply>: the reply proves AGENTS.md reached the runtime
    if printf '%s' "$2" | grep -q "$marker.*20-surface" && printf '%s' "$2" | grep -q '00-core'; then pass_row "$1"; else fail_row "$1: ${2:0:120}"; fi
}
# The reply must be a computed value, so an echoed command cannot match: a length, matched as LEN= followed by a nonzero digit.
envq='Run this shell command and reply with only its output: echo "PLANE_API_KEY_LEN=${#PLANE_API_KEY} GITEA_API_KEY_LEN=${#GITEA_API_KEY}"'
envok() { printf '%s' "$1" | grep -qE 'PLANE_API_KEY_LEN=[1-9][0-9]* GITEA_API_KEY_LEN=[1-9]'; }

tmp=$(mktemp -d -p "$HOME"); cd "$tmp" || exit 1   # under $HOME: agy trusts only the operator home dir; codex needs --skip-git-repo-check outside a repo
trap 'kill $(jobs -p) 2>/dev/null; cd /; rm -rf "$tmp"' EXIT
git init -q                              # inside a repo: instructions must reach a project session, which is where they matter

# LLM probes start in parallel, except the two Pi calls: both use the same
# local Ollama and a loaded probe can make the other time out. Rows print below
# in fixed order (AI_ST-131).
probe() { # probe <name> <timeout-seconds> <command...>: reply (stdout) to $tmp/<name>.out
    local name="$1" secs="$2"; shift 2
    timeout "$secs" "$@" >"$tmp/$name.out" 2>/dev/null </dev/null &
}
probe claude      120 claude -p "$q"
probe codex       300 codex exec --skip-git-repo-check -o "$tmp/codex.txt" "$q"
# shellcheck disable=SC2086  # PI_ARGS is a word list of extra flags, split on purpose
probe pi          120 pi -p ${PI_ARGS:-} "$q"
pi_probe_pid=$!
[ -f "$HOME/.agents/agy-context-path" ] && probe agy 120 agy -p "$q"
probe codex-env   300 codex exec --skip-git-repo-check -o "$tmp/env.txt" "$envq"
probe agy-env     120 agy -p --dangerously-skip-permissions "$envq"
probe claude-env  120 claude -p --dangerously-skip-permissions "$envq"
probe codex-skills 300 codex exec --skip-git-repo-check -o "$tmp/skills.txt" "List the skills you have available, names only."
wait "$pi_probe_pid" 2>/dev/null
probe pi-env      300 pi -p "$envq"
wait

instructed "claude" "$(cat "$tmp/claude.out" 2>/dev/null)"
instructed "codex"  "$(cat "$tmp/codex.txt" 2>/dev/null)"
instructed "pi (${PI_ARGS:-default model})" "$(cat "$tmp/pi.out" 2>/dev/null)"
if [ -f "$HOME/.agents/agy-context-path" ]; then
    instructed "agy" "$(cat "$tmp/agy.out" 2>/dev/null)"
else
    fail_row "agy: no global context path recorded (Task 3 must find one; four runtimes are required)"
fi
# Secrets env: the file, and one runtime actually seeing it (non-interactive shells skip .bashrc, so this is the real test)
env_file_ok() {
    local k
    [ "$(stat -c '%a' "$HOME/.config/agents/env" 2>/dev/null)" = "600" ] || return 1
    for k in GITEA_API_KEY GITEA_TOKEN N8N_API_KEY PLANE_API_KEY; do grep -q "^export $k=" "$HOME/.config/agents/env" 2>/dev/null || return 1; done
}
check "env file (600; GITEA_API_KEY GITEA_TOKEN N8N_API_KEY PLANE_API_KEY exported)" env_file_ok
# The outbound guard's internal allowlist lives in the env file, not the public repo (AI_ST-133); without it every Plane write is refused
if grep -qE "^export AGENTS_INTERNAL_HOSTS=['\"]?[^'\" ]" "$HOME/.config/agents/env" 2>/dev/null; then pass_row "guard allowlist (AGENTS_INTERNAL_HOSTS set in env file)"
else fail_row "guard allowlist: AGENTS_INTERNAL_HOSTS missing or empty in ~/.config/agents/env, so the guard allows loopback only (fix: add it to environment-secrets claude-code/settings.local.json.enc .env, re-run its install.sh)"; fi
if envok "$(cat "$tmp/env.txt" 2>/dev/null)"; then pass_row "env in runtime (codex)"; else fail_row "env in runtime (codex; check shell_environment_policy in ~/.codex/config.toml)"; fi
# Informational: agy has no documented env-policy switch, so its tool shell does not carry the keys (AI_ST-120).
# Claude Code injects settings.local.json's env block itself, so its row does not test the env file;
# Pi's local model may not drive its bash tool reliably, so its result is reported, not gated.
for r in agy claude pi; do
    out=$(cat "$tmp/$r-env.out" 2>/dev/null)
    if envok "$out"; then log_info "env in runtime ($r): ok"; else log_info "env in runtime ($r): ${out:0:80}"; fi
done
# Skills as the runtime actually sees them (the filesystem check below proves only the links)
missing=""; for s in $want; do grep -qw -- "$s" "$tmp/skills.txt" 2>/dev/null || missing="$missing $s"; done
# Other direction: a vendor-synced skill (a real dir under ~/.claude/skills, not one of our links) must not reach codex
leaked=""; while IFS= read -r f; do
    s=$(basename "$(dirname "$f")"); [ -d "$HOME/.codex/skills/.system/$s" ] && continue   # codex ships its own skill-creator
    grep -qxE "[[:space:]*•-]*\`?$s\`?[[:space:]]*" "$tmp/skills.txt" 2>/dev/null && leaked="$leaked $s"; done < <(find "$HOME/.claude/skills" -mindepth 2 -name SKILL.md 2>/dev/null)   # whole line: -w would hit docs in openai-docs
if [ -z "$missing$leaked" ]; then pass_row "skills in runtime (codex lists all $nwant kept skills, no vendor skill)"
else fail_row "skills in runtime (codex; missing:${missing:- none}; vendor leaked:${leaked:- none})"; fi
cd /; rm -rf "$tmp"

# Shared skills: ~/.agents/skills is exactly the kept set; each discovery root is a real dir whose links into it are exactly that set
n=$(ls "$HOME/.agents/skills" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')
m=$(ls "$HOME"/.agents/skills/*/SKILL.md 2>/dev/null | wc -l)
roots_ok=1
for root in "$HOME/.claude/skills" "$HOME/.gemini/config/skills"; do
    { [ -d "$root" ] && [ ! -L "$root" ]; } || { roots_ok=0; log_info "  $root is not a real directory"; continue; }
    got=$(for l in "$root"/*; do [ -L "$l" ] && case "$(readlink "$l")" in "$HOME/.agents/skills/"*) basename "$l";; esac; done | sort | tr '\n' ' ' | sed 's/ $//')
    [ "$got" = "$want" ] || { roots_ok=0; log_info "  $root links: $got"; }
done
[ "$n" = "$want" ] || log_info "  ~/.agents/skills holds: $n (want: $want)"
[ "$m" -eq "$nwant" ] || log_info "  $m of $nwant skills have SKILL.md"
[ -d "$HOME/.codex/skills/.system" ] || log_info "  ~/.codex/skills/.system is missing (codex managed skills)"
if [ "$n" = "$want" ] && [ "$m" -eq "$nwant" ] && [ "$roots_ok" -eq 1 ] && [ -d "$HOME/.codex/skills/.system" ]; then
    pass_row "skills (exactly the $nwant kept names, each with SKILL.md; claude and agy roots link each one; codex and pi read ~/.agents/skills natively; codex managed skills intact)"
else fail_row "skills (reasons above; fix: bash $SCRIPT_DIR/install.sh)"; fi

# Hooks: read from the hand-kept settings.json; a missing or malformed file is a FAIL with a fix, never a traceback (AI_ST-128)
st="$HOME/.claude/settings.json"; seed="$REPO_ROOT/software/development/claude-code/canonical/settings.json"
h=$(python3 - "$st" 2>&1 <<'PY'
import json, os, sys
try:
    d = json.load(open(sys.argv[1])).get('hooks') or {}
    cmds = sorted((e, os.path.expandvars(os.path.expanduser(c['command'].split()[0]))) for e, v in d.items() for g in v for c in g['hooks'])
    print(' '.join(e + ':' + os.path.basename(p) for e, p in cmds))
    print(' '.join(p for e, p in cmds))   # line 2: the registered executables, $HOME expanded
except FileNotFoundError: print('settings.json missing')
except (ValueError, KeyError, TypeError, AttributeError, IndexError) as x: print('settings.json unreadable: %s' % (str(x) or type(x).__name__))
PY
)
hp=$(sed -n 2p <<<"$h"); h=$(head -n1 <<<"$h")
# The registered executable itself, not its name: it must be byte-identical to the canonical script the fixtures below test
hbad=""; for p in $hp; do cmp -s "$p" "$REPO_ROOT/software/development/claude-code/canonical/shell/$(basename "$p")" && [ -x "$p" ] || hbad="$hbad $p"; done
if [ "$h" = "PreToolUse:cc-outbound-guard.sh SessionStart:cc-memory-inject.sh" ] && [ -n "$hbad" ]; then
    fail_row "hooks: registered executable missing or not the canonical script:$hbad (fix: bash $SCRIPT_DIR/install.sh, and point $st at the ~/.claude links)"
elif [ "$h" = "PreToolUse:cc-outbound-guard.sh SessionStart:cc-memory-inject.sh" ]; then pass_row "hooks (PreToolUse cc-outbound-guard.sh, SessionStart cc-memory-inject.sh; each the canonical script)"
elif [ "$h" = "settings.json missing" ]; then fail_row "hooks: $st missing (fix: bash $SCRIPT_DIR/install.sh seeds it from $seed)"
else fail_row "hooks (${h:-none}; fix: copy the hooks block of $seed into $st)"; fi

# Outbound guard behaviour, not just its registration: the fixture suite (AI_ST-110)
gt="$REPO_ROOT/software/development/claude-code/canonical/shell/tests/test-outbound-guard.sh"
if gout=$(bash "$gt" 2>&1); then pass_row "guard fixtures ($(tail -n1 <<<"$gout"))"
else fail_row "guard fixtures: $(grep -m3 '^FAIL' <<<"$gout" | tr '\n' ' ')(run: bash $gt)"; fi
# The memory-index regen link MEMORY.md and the skills name (AI_ST-116)
rl="$HOME/.claude/cc-memory-index-regen.sh"
if [ -L "$rl" ] && [ -x "$rl" ]; then pass_row "regen link ($rl)"
else fail_row "regen link: $rl missing or dangling (fix: bash $SCRIPT_DIR/install.sh)"; fi

echo
if [ "$fails" -eq 0 ]; then log_ok "passed=$pass failed=$fails"; else log_error "passed=$pass failed=$fails"; fi
[ "$fails" -eq 0 ]
