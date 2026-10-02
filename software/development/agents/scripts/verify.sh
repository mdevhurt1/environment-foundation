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
pass=0; fail=0
# The kept skills (R5 + the three restored in v2.0.0, AI_ST-108). One list, asserted in both directions below (AI_ST-115).
want="brainstorming end-conversation plane-api ring-maintenance session-start systematic-debugging test-driven-development verification-before-completion writing-plans"
nwant=$(wc -w <<<"$want")
check() { # check <name> <output>
    if printf '%s' "$2" | grep -q "$marker.*20-surface" && printf '%s' "$2" | grep -q '00-core'; then
        echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1: ${2:0:120}"; fail=$((fail+1)); fi
}
tmp=$(mktemp -d -p "$HOME"); cd "$tmp" || exit 1   # under $HOME: agy trusts only the operator home dir; codex needs --skip-git-repo-check outside a repo
git init -q                              # inside a repo: instructions must reach a project session, which is where they matter
check "claude" "$(timeout 120 claude -p "$q" 2>/dev/null)"
timeout 300 codex exec --skip-git-repo-check -o "$tmp/codex.txt" "$q" >/dev/null 2>&1
check "codex"  "$(cat "$tmp/codex.txt" 2>/dev/null)"
check "pi (${PI_ARGS:-default model})" "$(timeout 120 pi -p ${PI_ARGS:-} "$q" 2>/dev/null)"
if [ -f "$HOME/.agents/agy-context-path" ]; then
    check "agy" "$(timeout 120 agy -p "$q" 2>/dev/null)"
else
    echo "FAIL agy: no global context path recorded (Task 3 must find one; four runtimes are required)"; fail=$((fail+1))
fi
# Secrets env: the file, and one runtime actually seeing it (non-interactive shells skip .bashrc, so this is the real test)
envkeys=1
for k in GITEA_API_KEY GITEA_TOKEN N8N_API_KEY PLANE_API_KEY; do grep -q "^export $k=" "$HOME/.config/agents/env" 2>/dev/null || envkeys=0; done
if [ "$(stat -c '%a' "$HOME/.config/agents/env" 2>/dev/null)" = "600" ] && [ "$envkeys" -eq 1 ]; then
    echo "PASS env file (600; GITEA_API_KEY GITEA_TOKEN N8N_API_KEY PLANE_API_KEY exported)"; pass=$((pass+1)); else echo "FAIL env file"; fail=$((fail+1)); fi
# The outbound guard's internal allowlist lives in the env file, not the public repo (AI_ST-133); without it every Plane write is refused
if grep -qE "^export AGENTS_INTERNAL_HOSTS='?[^' ]" "$HOME/.config/agents/env" 2>/dev/null; then echo "PASS guard allowlist (AGENTS_INTERNAL_HOSTS set in env file)"; pass=$((pass+1))
else echo "FAIL guard allowlist: AGENTS_INTERNAL_HOSTS missing or empty in ~/.config/agents/env, so the guard allows loopback only (fix: add it to environment-secrets claude-code/settings.local.json.enc .env, re-run its install.sh)"; fail=$((fail+1)); fi
# The reply must be a computed value, so an echoed command cannot match: a length, matched as LEN= followed by a nonzero digit.
envq='Run this shell command and reply with only its output: echo "PLANE_API_KEY_LEN=${#PLANE_API_KEY} GITEA_API_KEY_LEN=${#GITEA_API_KEY}"'
envok() { printf '%s' "$1" | grep -qE 'PLANE_API_KEY_LEN=[1-9][0-9]* GITEA_API_KEY_LEN=[1-9]'; }
timeout 300 codex exec --skip-git-repo-check -o "$tmp/env.txt" "$envq" >/dev/null 2>&1
if envok "$(cat "$tmp/env.txt" 2>/dev/null)"; then echo "PASS env in runtime (codex)"; pass=$((pass+1)); else echo "FAIL env in runtime (codex; check shell_environment_policy in ~/.codex/config.toml)"; fail=$((fail+1)); fi
# Informational: agy has no documented env-policy switch, so its tool shell does not carry the keys (AI_ST-120).
out=$(timeout 120 agy -p --dangerously-skip-permissions "$envq" 2>/dev/null); envok "$out" && echo "INFO env in runtime (agy): ok" || echo "INFO env in runtime (agy): ${out:0:80}"
# Informational only: Claude Code injects settings.local.json's env block itself, so this does not test the env file;
# Pi's local model may not drive its bash tool reliably, so its result is reported, not gated.
out=$(timeout 120 claude -p --dangerously-skip-permissions "$envq" 2>/dev/null); envok "$out" && echo "INFO env in runtime (claude): ok" || echo "INFO env in runtime (claude): ${out:0:80}"
out=$(timeout 300 pi -p "$envq" 2>/dev/null); envok "$out" && echo "INFO env in runtime (pi): ok" || echo "INFO env in runtime (pi): ${out:0:80}"
# Skills as the runtime actually sees them (the filesystem check below proves only the links)
timeout 300 codex exec --skip-git-repo-check -o "$tmp/skills.txt" "List the skills you have available, names only." >/dev/null 2>&1
missing=""; for s in $want; do grep -qw -- "$s" "$tmp/skills.txt" 2>/dev/null || missing="$missing $s"; done
# Other direction: a vendor-synced skill (a real dir under ~/.claude/skills, not one of our links) must not reach codex
leaked=""; while IFS= read -r f; do
    s=$(basename "$(dirname "$f")"); [ -d "$HOME/.codex/skills/.system/$s" ] && continue   # codex ships its own skill-creator
    grep -qxE "[[:space:]*•-]*\`?$s\`?[[:space:]]*" "$tmp/skills.txt" 2>/dev/null && leaked="$leaked $s"; done < <(find "$HOME/.claude/skills" -mindepth 2 -name SKILL.md 2>/dev/null)   # whole line: -w would hit docs in openai-docs
if [ -z "$missing$leaked" ]; then echo "PASS skills in runtime (codex lists all $nwant kept skills, no vendor skill)"; pass=$((pass+1));
else echo "FAIL skills in runtime (codex; missing:${missing:- none}; vendor leaked:${leaked:- none})"; fail=$((fail+1)); fi
cd /; rm -rf "$tmp"

# Shared skills: ~/.agents/skills is exactly the kept set; each discovery root is a real dir whose links into it are exactly that set
n=$(ls "$HOME/.agents/skills" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')
m=$(ls "$HOME"/.agents/skills/*/SKILL.md 2>/dev/null | wc -l)
roots_ok=1
for root in "$HOME/.claude/skills" "$HOME/.gemini/config/skills"; do
    { [ -d "$root" ] && [ ! -L "$root" ]; } || { roots_ok=0; echo "  $root is not a real directory"; continue; }
    got=$(for l in "$root"/*; do [ -L "$l" ] && case "$(readlink "$l")" in "$HOME/.agents/skills/"*) basename "$l";; esac; done | sort | tr '\n' ' ' | sed 's/ $//')
    [ "$got" = "$want" ] || { roots_ok=0; echo "  $root links: $got"; }
done
[ "$n" = "$want" ] || echo "  ~/.agents/skills holds: $n (want: $want)"
[ "$m" -eq "$nwant" ] || echo "  $m of $nwant skills have SKILL.md"
[ -d "$HOME/.codex/skills/.system" ] || echo "  ~/.codex/skills/.system is missing (codex managed skills)"
if [ "$n" = "$want" ] && [ "$m" -eq "$nwant" ] && [ "$roots_ok" -eq 1 ] && [ -d "$HOME/.codex/skills/.system" ]; then
    echo "PASS skills (exactly the $nwant kept names, each with SKILL.md; claude and agy roots link each one; codex and pi read ~/.agents/skills natively; codex managed skills intact)"; pass=$((pass+1))
else echo "FAIL skills (reasons above; fix: bash $SCRIPT_DIR/install.sh)"; fail=$((fail+1)); fi

# Hooks: read from the hand-kept settings.json; a missing or malformed file is a FAIL with a fix, never a traceback (AI_ST-128)
st="$HOME/.claude/settings.json"; seed="$REPO_ROOT/software/development/claude-code/canonical/settings.json"
h=$(python3 - "$st" 2>&1 <<'PY'
import json, os, sys
try:
    d = json.load(open(sys.argv[1])).get('hooks') or {}
    print(' '.join(sorted(e + ':' + os.path.basename(c['command'].split()[0]) for e, v in d.items() for g in v for c in g['hooks'])))
except FileNotFoundError: print('settings.json missing')
except (ValueError, KeyError, TypeError, AttributeError, IndexError) as x: print('settings.json unreadable: %s' % (str(x) or type(x).__name__))
PY
)
if [ "$h" = "PreToolUse:cc-outbound-guard.sh SessionStart:cc-memory-inject.sh" ]; then echo "PASS hooks (PreToolUse cc-outbound-guard.sh, SessionStart cc-memory-inject.sh)"; pass=$((pass+1))
elif [ "$h" = "settings.json missing" ]; then echo "FAIL hooks: $st missing (fix: bash $SCRIPT_DIR/install.sh seeds it from $seed)"; fail=$((fail+1))
else echo "FAIL hooks (${h:-none}; fix: copy the hooks block of $seed into $st)"; fail=$((fail+1)); fi

# Outbound guard behaviour, not just its registration: the fixture suite (AI_ST-110)
gt="$REPO_ROOT/software/development/claude-code/canonical/shell/tests/test-outbound-guard.sh"
if gout=$(bash "$gt" 2>&1); then echo "PASS guard fixtures ($(tail -n1 <<<"$gout"))"; pass=$((pass+1))
else echo "FAIL guard fixtures: $(grep -m3 '^FAIL' <<<"$gout" | tr '\n' ' ')(run: bash $gt)"; fail=$((fail+1)); fi
# The memory-index regen link MEMORY.md and the skills name (AI_ST-116)
rl="$HOME/.claude/cc-memory-index-regen.sh"
if [ -L "$rl" ] && [ -x "$rl" ]; then echo "PASS regen link ($rl)"; pass=$((pass+1))
else echo "FAIL regen link: $rl missing or dangling (fix: bash $SCRIPT_DIR/install.sh)"; fail=$((fail+1)); fi

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
