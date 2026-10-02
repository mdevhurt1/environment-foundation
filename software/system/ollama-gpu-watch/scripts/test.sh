#!/usr/bin/env bash
# Description: Offline unit test of canonical/ollama-gpu-probe.sh. Replaces
#              docker, nvidia-smi and curl with stubs and replays the healthy
#              case plus every failure signature, including the exact
#              2026-09-25 NVML output (positive control: it must FAIL).
#              Touches no container, GPU or network.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: bash, jq, awk, mktemp
# Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root
require_command jq

PROBE="$SCRIPT_DIR/../canonical/ollama-gpu-probe.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUBS="$WORK/bin"
mkdir -p "$STUBS"

# --- stubs: behaviour is driven by FAKE_* environment variables -------------
cat > "$STUBS/nvidia-smi" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_HOST_SMI_OUT:-595.91.07}"
exit "${FAKE_HOST_SMI_RC:-0}"
STUB
cat > "$STUBS/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  inspect) [ "${FAKE_EXISTS:-1}" = 1 ] || { echo "Error: No such object: $4" >&2; exit 1; }
           echo "${FAKE_RUNNING:-true}" ;;
  exec)    printf '%s\n' "${FAKE_EXEC_OUT:-NVIDIA GeForce RTX 3090, 595.91.07}"
           exit "${FAKE_EXEC_RC:-0}" ;;
  *)       exit 99 ;;
esac
STUB
cat > "$STUBS/curl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    */api/ps)       [ "${FAKE_API_DOWN:-0}" = 0 ] || exit 7
                    printf '%s' "${FAKE_PS_JSON:-{\"models\":[]\}}"; exit 0 ;;
    */api/generate) printf '%s' "${FAKE_GEN_JSON:-{\}}"; exit 0 ;;
  esac
done
exit 22
STUB
chmod +x "$STUBS"/*

PS_HEALTHY='{"models":[{"name":"qwen3.6:35b","size":23592823682,"size_vram":22153000000},{"name":"gemma4:12b","size":9000000000,"size_vram":8400000000}]}'
PS_CPU='{"models":[{"name":"qwen3.6:35b","size":23592823682,"size_vram":0}]}'
PS_PARTIAL='{"models":[{"name":"qwen3.6:35b","size":23592823682,"size_vram":21180000000}]}'
NVML_0925='Failed to initialize NVML: Unknown Error'

pass=0 fails=0
# expect <label> <want-exit> <want-regex> [VAR=value ...]
expect() {
  local label="$1" want_rc="$2" want_re="$3"; shift 3
  local out rc
  local -a args=()
  read -r -a args <<< "${ARGS:-}"
  out="$(env -i PATH="$STUBS:/usr/bin:/bin" HOME="$WORK/home" \
           OGW_CONFIG=/nonexistent OGW_BASELINE_FILE="$WORK/baseline" \
           OGW_PROC_VERSION="$WORK/proc-version" "$@" \
           bash "$PROBE" "${args[@]}" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$want_rc" ] && printf '%s' "$out" | grep -qE "$want_re" \
     && [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ]; then
    log_ok "$label  -> rc=$rc  $out"
    pass=$((pass + 1))
  else
    log_error "$label  -> rc=$rc (want $want_rc, /$want_re/, one line)  $out"
    fails=$((fails + 1))
  fi
}

set +e
log_info "Healthy cases"
expect "healthy: NVML ok, drivers agree, models 94%/93% in VRAM" 0 \
  '^OK ollama-gpu: gpu="NVIDIA GeForce RTX 3090" driver host=595.91.07 container=595.91.07 models=qwen3.6:35b@93.9%vram,gemma4:12b@93.3%vram$' \
  FAKE_PS_JSON="$PS_HEALTHY"
expect "healthy: nothing loaded is not a failure" 0 'models=none-loaded' \
  FAKE_PS_JSON='{"models":[]}'
expect "healthy: 89.8% (qwen at 64k ctx) is above the 50% floor" 0 '89\.8%vram' \
  FAKE_PS_JSON="$PS_PARTIAL"
printf 'NVRM version: NVIDIA UNIX x86_64 Kernel Module  595.91.07  Tue Sep 22 2026\n' > "$WORK/proc-version"
expect "healthy: host nvidia-smi broken, /proc fallback supplies the version" 0 'driver host=595.91.07' \
  FAKE_HOST_SMI_OUT='NVIDIA-SMI has failed' FAKE_HOST_SMI_RC=9 FAKE_PS_JSON="$PS_HEALTHY"
rm -f "$WORK/proc-version"

log_info "Failure signatures (each must FAIL)"
expect "POSITIVE CONTROL: 2026-09-25 NVML output inside the container" 1 \
  '^FAIL ollama-gpu: NVML broken inside container .ollama.*Failed to initialize NVML: Unknown Error.*docker restart ollama' \
  FAKE_EXEC_OUT="$NVML_0925" FAKE_EXEC_RC=255 FAKE_PS_JSON="$PS_CPU"
expect "NVML failure text even with exit 0" 1 'NVML broken' \
  FAKE_EXEC_OUT="$NVML_0925" FAKE_EXEC_RC=0
expect "library/driver version mismatch text" 1 'NVML broken.*version mismatch' \
  FAKE_EXEC_OUT='Failed to initialize NVML: Driver/library version mismatch' FAKE_EXEC_RC=18
expect "driver upgraded under the container: 595.84 vs 595.91.07" 1 \
  'driver mismatch: host 595.91.07, container 595.84' \
  FAKE_EXEC_OUT='NVIDIA GeForce RTX 3090, 595.84'
expect "NVML ok but model at size_vram=0 (CPU fallback)" 1 \
  'model running on CPU: qwen3.6:35b size_vram=0 of size=23592823682 \(0\.0% < floor 50%\)' \
  FAKE_PS_JSON="$PS_CPU"
expect "configurable floor: 89.8% fails a 95% floor" 1 'floor 95%' \
  FAKE_PS_JSON="$PS_PARTIAL" OGW_MIN_VRAM_RATIO=0.95
expect "container stopped" 1 "is not running" FAKE_RUNNING=false
expect "container absent" 1 "not inspectable" FAKE_EXISTS=0
expect "API down" 1 "unreachable" FAKE_API_DOWN=1
expect "host driver unreadable" 1 "host nvidia driver not readable" \
  FAKE_HOST_SMI_OUT='NVIDIA-SMI has failed' FAKE_HOST_SMI_RC=9

log_info "--bench"
ARGS="--bench"
expect "bench: 54 tok in 0.71s (76 tok/s), no baseline, floor 10" 0 \
  'bench=gemma4:12b@76\.1tok/s\(floor 10, baseline none\)' \
  FAKE_PS_JSON="$PS_HEALTHY" FAKE_GEN_JSON='{"eval_count":54,"eval_duration":710000000}'
ARGS="--bench --save-baseline"
expect "bench: save baseline 76.1" 0 'baseline 76\.1' \
  FAKE_PS_JSON="$PS_HEALTHY" FAKE_GEN_JSON='{"eval_count":54,"eval_duration":710000000}'
ARGS="--bench"
expect "bench: 2026-09-25 rate, 16 tok in 49.7s, fails" 1 \
  'decodes at 0\.3 tok/s, below floor 22\.8 \(baseline 76\.1\)' \
  FAKE_PS_JSON="$PS_HEALTHY" FAKE_GEN_JSON='{"eval_count":16,"eval_duration":49700000000}'
expect "bench: 20 tok/s passes the absolute floor but fails 0.30 x baseline" 1 'below floor 22\.8' \
  FAKE_PS_JSON="$PS_HEALTHY" FAKE_GEN_JSON='{"eval_count":20,"eval_duration":1000000000}'
expect "bench: refuses to load a model on its own" 1 'no model loaded and OGW_BENCH_MODEL unset' \
  FAKE_PS_JSON='{"models":[]}'
ARGS="--frobnicate"
expect "usage error exits 2 with one line" 2 "^usage error: unknown argument '--frobnicate'"
ARGS=""

log_info "--textfile metric"
TF="$WORK/tf/ollama_gpu_ok.prom"
ARGS="--textfile $TF"
expect "textfile: failure run" 1 'NVML broken' FAKE_EXEC_OUT="$NVML_0925" FAKE_EXEC_RC=255
if grep -qx 'ollama_gpu_ok{container="ollama",host_driver="595.91.07",container_driver="unknown"} 0' "$TF"; then
  log_ok "textfile: ollama_gpu_ok 0 with driver labels"; pass=$((pass + 1))
else
  log_error "textfile: expected ollama_gpu_ok 0, got: $(cat "$TF" 2>&1)"; fails=$((fails + 1))
fi
expect "textfile: healthy run" 0 '^OK' FAKE_PS_JSON="$PS_HEALTHY"
if grep -qx 'ollama_gpu_ok{container="ollama",host_driver="595.91.07",container_driver="595.91.07"} 1' "$TF" \
   && grep -qx 'ollama_gpu_vram_ratio{model="qwen3.6:35b"} 0.939' "$TF"; then
  log_ok "textfile: ollama_gpu_ok 1 and per-model vram ratio"; pass=$((pass + 1))
else
  log_error "textfile: expected ollama_gpu_ok 1, got: $(cat "$TF" 2>&1)"; fails=$((fails + 1))
fi
ARGS=""
set -e

echo
if [ "$fails" -eq 0 ]; then
  log_ok "probe tests: $pass passed, 0 failed"
  exit 0
fi
log_error "probe tests: $pass passed, $fails failed"
exit 1
