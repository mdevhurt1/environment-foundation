#!/bin/sh
# Statusline renderer.
# Receives JSON on stdin from Claude Code.
# Emits a single line of text with ANSI color codes.
#
# Outputs an additional CTX-WARN marker when context usage >= 80%, which
# the session-start skill instructs the model to react to by proposing /end.

set -eu

input=$(cat)

# --- cwd, shortened to ~/... if under $HOME ---
cwd=$(printf '%s' "$input" | jq -r '.cwd // "?"')
case "$cwd" in
  "$HOME")    cwd="~" ;;
  "$HOME"/*)  cwd="~${cwd#"$HOME"}" ;;
esac

# --- mode (from .cc-mode in cwd or any ancestor) ---
mode=""
slug=""
search="$cwd"
case "$cwd" in "~"*) search="$HOME${cwd#\~}" ;; esac
dir="$search"
while [ "$dir" != "/" ] && [ -n "$dir" ]; do
    if [ -f "$dir/.cc-mode" ]; then
        # shellcheck disable=SC1090,SC1091
        . "$dir/.cc-mode"
        break
    fi
    dir=$(dirname "$dir")
done

# --- context % from JSON (real field, not approximation) ---
ctx_pct=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty')
ctx_display=""
ctx_warn_display=""
if [ -n "$ctx_pct" ]; then
    # round to integer for display
    ctx_pct=$(printf '%.0f' "$ctx_pct")
    ctx_display=$(printf ' \033[01;90m(ctx %d%%)\033[00m' "$ctx_pct")
    if [ "$ctx_pct" -ge 80 ] 2>/dev/null; then
        ctx_warn_display=$(printf ' \033[01;31mCTX-WARN\033[00m')
    fi
fi

# --- mode badge ---
mode_badge=""
case "$mode" in
    exploration) mode_badge=$(printf '\033[01;33m[EXPLORE%s]\033[00m ' "${slug:+ $slug}") ;;
    build)       mode_badge=$(printf '\033[01;31m[BUILD]\033[00m ') ;;
    continue)    mode_badge=$(printf '\033[01;36m[CONTINUE]\033[00m ') ;;
    *)           mode_badge=$(printf '\033[01;90m[bare]\033[00m ') ;;
esac

# --- assemble ---
printf '%s%s\033[01;32m%s@%s\033[00m:\033[01;34m%s\033[00m%s%s' \
  "$mode_badge" \
  "${debian_chroot:+($debian_chroot)}" \
  "$(whoami)" \
  "$(hostname -s)" \
  "$cwd" \
  "$ctx_display" \
  "$ctx_warn_display"
