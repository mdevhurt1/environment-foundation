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
check() { # check <name> <output>
    if printf '%s' "$2" | grep -q "$marker.*20-surface" && printf '%s' "$2" | grep -q '00-core'; then
        echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1: ${2:0:120}"; fail=$((fail+1)); fi
}
tmp=$(mktemp -d -p "$HOME"); cd "$tmp"   # under $HOME: agy trusts only the operator home dir; codex needs --skip-git-repo-check outside a repo
git init -q                              # inside a repo: instructions must reach a project session, which is where they matter
check "claude" "$(timeout 120 claude -p "$q" 2>/dev/null)"
timeout 120 codex exec --skip-git-repo-check -o "$tmp/codex.txt" "$q" >/dev/null 2>&1
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
# The reply must be a computed value, so an echoed command cannot match: a length, matched as LEN= followed by a nonzero digit.
envq='Run this shell command and reply with only its output: echo "PLANE_API_KEY_LEN=${#PLANE_API_KEY} GITEA_API_KEY_LEN=${#GITEA_API_KEY}"'
envok() { printf '%s' "$1" | grep -qE 'PLANE_API_KEY_LEN=[1-9][0-9]* GITEA_API_KEY_LEN=[1-9]'; }
timeout 120 codex exec --skip-git-repo-check -o "$tmp/env.txt" "$envq" >/dev/null 2>&1
if envok "$(cat "$tmp/env.txt" 2>/dev/null)"; then echo "PASS env in runtime (codex)"; pass=$((pass+1)); else echo "FAIL env in runtime (codex; check shell_environment_policy in ~/.codex/config.toml)"; fail=$((fail+1)); fi
out=$(timeout 120 agy -p --dangerously-skip-permissions "$envq" 2>/dev/null)
if [ "${AGY_ENV_INFO:-0}" = "1" ]; then envok "$out" && echo "INFO env in runtime (agy): ok" || echo "INFO env in runtime (agy): ${out:0:80}"; else
if envok "$out"; then echo "PASS env in runtime (agy)"; pass=$((pass+1)); else echo "FAIL env in runtime (agy): ${out:0:80}"; echo "  agy has no documented env-policy switch. If its tool shell strips the keys, record one friction line and rerun verify.sh with AGY_ENV_INFO=1 to demote this row to INFO; the broker-free local design does not depend on agy holding these keys."; fail=$((fail+1)); fi
fi
# Informational only: Claude Code injects settings.local.json's env block itself, so this does not test the env file;
# Pi's local model may not drive its bash tool reliably, so its result is reported, not gated.
out=$(timeout 120 claude -p --dangerously-skip-permissions "$envq" 2>/dev/null); envok "$out" && echo "INFO env in runtime (claude): ok" || echo "INFO env in runtime (claude): ${out:0:80}"
out=$(timeout 300 pi -p "$envq" 2>/dev/null); envok "$out" && echo "INFO env in runtime (pi): ok" || echo "INFO env in runtime (pi): ${out:0:80}"
# Skills as the runtime actually sees them (the filesystem check below proves only the links)
timeout 120 codex exec --skip-git-repo-check -o "$tmp/skills.txt" "List the skills you have available, names only." >/dev/null 2>&1
missing=""
for s in brainstorming plane-api systematic-debugging test-driven-development verification-before-completion writing-plans; do
    grep -qw -- "$s" "$tmp/skills.txt" 2>/dev/null || missing="$missing $s"
done
if [ -z "$missing" ]; then echo "PASS skills in runtime (codex lists the six)"; pass=$((pass+1));
else echo "FAIL skills in runtime (codex; missing:$missing)"; fail=$((fail+1)); fi
cd /; rm -rf "$tmp"

# Shared skills
want="brainstorming plane-api systematic-debugging test-driven-development verification-before-completion writing-plans"
n=$(ls "$HOME/.agents/skills" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')
m=$(ls "$HOME"/.agents/skills/*/SKILL.md 2>/dev/null | wc -l)
if [ "$n" = "$want" ] && [ "$m" -eq 6 ] && [ "$(readlink "$HOME/.claude/skills")" = "$HOME/.agents/skills" ] && [ "$(readlink "$HOME/.gemini/config/skills")" = "$HOME/.agents/skills" ] && [ -d "$HOME/.codex/skills/.system" ]; then
    echo "PASS skills (exactly the six kept names, each with SKILL.md; claude and agy linked; codex and pi read ~/.agents/skills natively; codex managed skills intact)"; pass=$((pass+1))
else echo "FAIL skills"; fail=$((fail+1)); fi

# Hooks
h=$(python3 -c "import json,os;d=json.load(open('$HOME/.claude/settings.json'))['hooks'];print(' '.join(sorted(e+':'+os.path.basename(c['command'].split()[0]) for e,v in d.items() for g in v for c in g['hooks'])))")
if [ "$h" = "PreToolUse:cc-outbound-guard.sh SessionStart:cc-memory-inject.sh" ]; then echo "PASS hooks (PreToolUse cc-outbound-guard.sh, SessionStart cc-memory-inject.sh)"; pass=$((pass+1)); else echo "FAIL hooks ($h)"; fail=$((fail+1)); fi

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
