#!/usr/bin/env bash
# Description: Removes the Ollama GPU watch: disables the timer, removes the
#              unit and probe symlinks and the metric file. Dry run by
#              default; --yes to proceed.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: systemctl
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

ASSUME_YES=0
case "${1:-}" in
  --yes) ASSUME_YES=1 ;;
  "")    ASSUME_YES=0 ;;
  *)     log_error "Unknown argument: $1 (only --yes is accepted)"; exit 2 ;;
esac

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
PROBE="$HOME/.local/bin/ollama-gpu-probe"
# A stale "ollama_gpu_ok 1" left behind would read as healthy to a scraper.
PROM="$HOME/.local/share/node_exporter/ollama_gpu_ok.prom"

plan() { printf '  - %s\n' "$*"; }
keep() { printf '  . %s\n' "$*"; }

log_info "Ollama GPU watch uninstall would REMOVE:"
plan "the ollama-gpu-watch.timer enablement (systemctl --user disable --now)"
plan "$UNIT_DIR/ollama-gpu-watch.{service,timer} (symlinks)"
plan "$PROBE (symlink)"
plan "$PROM"
log_info "and would deliberately KEEP:"
keep "the ollama container, its models and volumes (never touched)"
keep "$HOME/.config/ollama-gpu-watch/config and $HOME/.local/state/ollama-gpu-watch/baseline (your settings and measurements)"
keep "the ~/.local/share/node_exporter directory (other collectors may use it)"

if [ "$ASSUME_YES" -ne 1 ]; then
  log_warn "Dry run — nothing was removed. Re-run with --yes to proceed."
  exit 0
fi

systemctl --user disable --now ollama-gpu-watch.timer 2>/dev/null || true
systemctl --user stop ollama-gpu-watch.service 2>/dev/null || true
for f in "$UNIT_DIR/ollama-gpu-watch.service" "$UNIT_DIR/ollama-gpu-watch.timer" "$PROBE"; do
  if [ -L "$f" ]; then rm -f "$f"; log_ok "removed $f"; fi
done
rm -f "$PROM"
systemctl --user daemon-reload
systemctl --user reset-failed ollama-gpu-watch.service 2>/dev/null || true
log_ok "Uninstall complete. Module files in the repo are untouched."
