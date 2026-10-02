#!/usr/bin/env bash
# Description: Installs the Ollama GPU watch for the current user: links the
#              probe to ~/.local/bin/ollama-gpu-probe and the systemd user
#              service + 15-minute timer into ~/.config/systemd/user, then
#              enables the timer. No root, no package installs.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: systemd user manager, docker (user in the docker group),
#               nvidia-smi, curl, jq; notify-send optional
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root
require_command systemctl
require_command docker "install the docker module first (software/development/docker)"
require_command jq "sudo apt-get install -y jq"
require_command curl "sudo apt-get install -y curl"
command -v nvidia-smi &>/dev/null || log_warn "nvidia-smi not on PATH; the probe falls back to /proc/driver/nvidia/version"
command -v notify-send &>/dev/null || log_warn "notify-send not found; failures will only show in the journal and the metric file"

MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

# link_to <target> <link>: idempotent symlink; refuses to clobber a real file.
link_to() {
  local target="$1" link="$2"
  if [ -L "$link" ] && [ "$(readlink -f "$link")" = "$(readlink -f "$target")" ]; then
    log_ok "already linked: $link"
    return 0
  fi
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    log_error "$link exists and is not a symlink; move it aside and re-run"
    exit 1
  fi
  ln -sfn "$target" "$link"
  log_ok "linked $link -> $target"
}

mkdir -p "$BIN_DIR" "$UNIT_DIR" "$HOME/.local/share/node_exporter"
link_to "$MODULE_DIR/canonical/ollama-gpu-probe.sh" "$BIN_DIR/ollama-gpu-probe"
for u in ollama-gpu-watch.service ollama-gpu-watch.timer; do
  link_to "$MODULE_DIR/canonical/systemd/$u" "$UNIT_DIR/$u"
done

systemctl --user daemon-reload
systemctl --user enable --now ollama-gpu-watch.timer
log_ok "ollama-gpu-watch.timer enabled: $(systemctl --user show -p NextElapseUSecRealtime --value ollama-gpu-watch.timer)"

if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]; then
  log_warn "User lingering is off: the timer runs only while $USER has a session."
  log_warn "To keep it running with nobody logged in: loginctl enable-linger $USER"
fi
log_info "Run one probe now: systemctl --user start ollama-gpu-watch.service; then: bash $SCRIPT_DIR/verify.sh"
