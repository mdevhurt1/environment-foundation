#!/bin/sh
# Statusline renderer.
# Receives JSON on stdin from Claude Code.
# Emits a single line of text with ANSI color codes.
#
# Outputs an additional CTX-WARN marker when context usage >= 80%, which
# the session-start skill instructs the model to react to by proposing /end.
#
# Also renders the RUNNING model, and a MODEL-DRIFT marker when it disagrees
# with the model the session was launched under. These are two independent
# instruments on purpose: .cc-mode records INTENT (what the policy chose at
# launch), while .model.id from the harness is REALITY (what is actually
# answering). The Fable-5 incident was invisible precisely because nothing
# anywhere displayed reality -- the model had moved, every file on disk still
# said what it said before, and no surface disagreed with any other.

set -eu

input=$(cat)

# --- cwd, shortened to ~/... if under $HOME ---
cwd=$(printf '%s' "$input" | jq -r '.cwd // "?"')
case "$cwd" in
  "$HOME")    cwd="~" ;;
  "$HOME"/*)  cwd="~${cwd#"$HOME"}" ;;
esac

# --- mode (from .cc-mode in cwd or any ancestor) ---
#
# THIS PARSES .cc-mode. IT DOES NOT SOURCE IT. That is the point of INFRA-45.
#
# Until 2026-09-03 this block was `. "$dir/.cc-mode"`, which made every value
# in that file shell code executed once per repaint, in every session, in
# every worktree. A value containing a space silently blanked its own field; a
# value containing an unbalanced quote silently blanked every field BELOW it;
# and a value containing $(...) RAN, over and over, for as long as the session
# stayed open.
#
# The writer now encodes what it writes (see "the .cc-mode quoting contract"
# in canonical/shell/cc-functions.sh), which makes files THIS writer produces
# safe to source. That is not sufficient, and is why the reader changed too:
# this loop consumes whatever .cc-mode the upward walk happens to land on --
# one written by an older cc-functions.sh, hand-edited during a debug session,
# restored from a backup, or simply left in an ancestor directory by something
# else entirely. Encoding on write makes the current instances safe; parsing
# on read makes the class impossible. Only the second one survives a file this
# code did not produce.
#
# Cost, since this runs on every repaint: one `while read` over ten short
# lines, entirely in-process. No fork, no eval, no subshell -- __cc_unq
# returns through a variable rather than through $(...) for exactly that
# reason. The four jq/whoami/hostname forks already on this path each cost
# more than the whole loop.
#
# Keys are WHITELISTED to the three this file displays. Sourcing also let
# .cc-mode set anything else in scope -- including $debian_chroot, which the
# final printf interpolates into the prompt. It cannot any more.

# __cc_unq <raw> -- decode one .cc-mode value into $UNQ, per the contract:
# a single-quoted value is unwrapped and each '\'' collapsed to '; anything
# else is already bare and is returned unchanged.
__cc_unq() {
    UNQ=$1
    case $UNQ in "'"*"'") ;; *) return 0 ;; esac
    UNQ=${UNQ#\'}
    UNQ=${UNQ%\'}
    # Fast path: nothing escaped inside, so the unwrap was the whole job.
    case $UNQ in *"'\\''"*) ;; *) return 0 ;; esac
    _rest=$UNQ
    UNQ=''
    while :; do
        case $_rest in *"'\\''"*) ;; *) break ;; esac
        _pre=${_rest%%"'\\''"*}
        _rest=${_rest#*"'\\''"}
        UNQ=$UNQ$_pre\'
    done
    UNQ=$UNQ$_rest
}

mode=""
slug=""
model=""
search="$cwd"
case "$cwd" in "~"*) search="$HOME${cwd#\~}" ;; esac
dir="$search"
while [ "$dir" != "/" ] && [ -n "$dir" ]; do
    if [ -f "$dir/.cc-mode" ]; then
        # `|| [ -n "$line" ]` so a final line with no trailing newline is not
        # dropped -- a truncated .cc-mode must degrade to a missing field, not
        # to a differently-parsed one.
        while IFS= read -r line || [ -n "$line" ]; do
            case $line in
                mode=*)  __cc_unq "${line#mode=}";  mode=$UNQ  ;;
                slug=*)  __cc_unq "${line#slug=}";  slug=$UNQ  ;;
                model=*) __cc_unq "${line#model=}"; model=$UNQ ;;
            esac
        done < "$dir/.cc-mode"
        break
    fi
    dir=$(dirname "$dir")
done

# --- model: reality (from the harness) vs intent (from .cc-mode) ---
# .model.display_name is supplied by Claude Code on stdin and is authoritative
# for what is running now. $model / $model_source come from the .cc-mode
# sourced above; "track-latest" means the policy deliberately declined to pin,
# so anything running is in-policy and cannot drift by definition.
model_display=$(printf '%s' "$input" | jq -r '.model.display_name // empty')
model_id=$(printf '%s' "$input" | jq -r '.model.id // empty')
model_display_out=""
model_drift_out=""
if [ -n "$model_display" ]; then
    model_display_out=$(printf ' \033[01;35m[%s]\033[00m' "$model_display")
    intent="${model:-}"
    if [ -n "$intent" ] && [ "$intent" != "track-latest" ]; then
        # An intent is either a tier alias (opus) or an exact id
        # (claude-opus-5[1m]). Both should appear inside the running id, so a
        # substring test covers each without needing to know the id format.
        case "$model_id" in
            *"$intent"*) ;;
            *) model_drift_out=$(printf ' \033[01;31mMODEL-DRIFT(want %s)\033[00m' "$intent") ;;
        esac
    fi
fi

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
    exploration)    mode_badge=$(printf '\033[01;33m[EXPLORE%s]\033[00m ' "${slug:+ $slug}") ;;
    build)          mode_badge=$(printf '\033[01;31m[BUILD]\033[00m ') ;;
    continue)       mode_badge=$(printf '\033[01;36m[CONTINUE]\033[00m ') ;;
    branched)       mode_badge=$(printf '\033[01;35m[BRANCH%s]\033[00m ' "${slug:+ $slug}") ;;
    command-center) mode_badge=$(printf '\033[01;37m[EA]\033[00m ') ;;
    *)              mode_badge=$(printf '\033[01;90m[bare]\033[00m ') ;;
esac

# --- assemble ---
printf '%s%s\033[01;32m%s@%s\033[00m:\033[01;34m%s\033[00m%s%s%s%s' \
  "$mode_badge" \
  "${debian_chroot:+($debian_chroot)}" \
  "$(whoami)" \
  "$(hostname -s)" \
  "$cwd" \
  "$model_display_out" \
  "$model_drift_out" \
  "$ctx_display" \
  "$ctx_warn_display"
