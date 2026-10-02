#!/usr/bin/env bash
# Description: Post-install acceptance test for the Ollama GPU watch: the
#              probe and units are linked, the timer is enabled and active,
#              the metric file is fresh and valid, and a live probe run says
#              the GPU is attached right now.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: systemctl, the units installed by install.sh

set -uo pipefail   # NOTE: no -e — we want every check to run and report.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
PROBE="$HOME/.local/bin/ollama-gpu-probe"
PROM="$HOME/.local/share/node_exporter/ollama_gpu_ok.prom"

fails=0
check() {
  # check "<label>" <command...>
  local label="$1"; shift
  if "$@" &>/dev/null; then
    log_ok "$label"
  else
    log_error "$label"
    fails=$((fails + 1))
  fi
}

log_info "Verifying the Ollama GPU watch..."

check "probe linked and executable: $PROBE" test -x "$PROBE"
check "service unit linked" test -e "$UNIT_DIR/ollama-gpu-watch.service"
check "timer unit linked" test -e "$UNIT_DIR/ollama-gpu-watch.timer"
check "timer enabled" systemctl --user is-enabled --quiet ollama-gpu-watch.timer
check "timer active" systemctl --user is-active --quiet ollama-gpu-watch.timer

# Last run: a service that has never run has an empty ExecMainStartTimestamp.
# That is legitimately "not yet", so warn rather than fail.
last_start="$(systemctl --user show -p ExecMainStartTimestamp --value ollama-gpu-watch.service 2>/dev/null)"
if [ -z "$last_start" ] || [ "$last_start" = "n/a" ]; then
  log_warn "service has not run yet (systemctl --user start ollama-gpu-watch.service)"
else
  result="$(systemctl --user show -p Result --value ollama-gpu-watch.service 2>/dev/null)"
  status="$(systemctl --user show -p ExecMainStatus --value ollama-gpu-watch.service 2>/dev/null)"
  log_info "last run: $last_start result=$result exit=$status"
  log_info "last probe line: $(journalctl --user -u ollama-gpu-watch.service -n 20 -o cat 2>/dev/null | grep -E '^(OK|FAIL) ollama-gpu:' | tail -n1)"
  # The timer fires every 15 min; 40 min of silence means it is not running.
  check "metric file written within the last 40 min: $PROM" \
    bash -c "test -n \"\$(find '$PROM' -mmin -40 2>/dev/null)\""
  check "metric file reports ollama_gpu_ok 0 or 1" bash -c "grep -qE '^ollama_gpu_ok\\{.*\\} [01]\$' '$PROM'"
fi

# Capability, not provenance: run the probe once, live, without --bench.
if [ -x "$PROBE" ]; then
  line="$("$PROBE" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then log_ok "live probe: $line"; else log_error "live probe: $line"; fails=$((fails + 1)); fi
fi

echo
if [ "$fails" -eq 0 ]; then
  log_ok "All checks passed. Ollama is on the GPU and the watch is running."
  exit 0
fi
log_error "$fails check(s) failed."
log_warn "If the live probe failed with an NVML error: docker restart ollama, then measure warm."
log_warn "If units are missing: bash $SCRIPT_DIR/install.sh"
exit 1
