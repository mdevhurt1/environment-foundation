#!/usr/bin/env bash
# Description: Answers "is Ollama actually using the GPU right now" with
#              evidence. Fails on a broken NVML inside the container, a
#              host/container driver mismatch, a loaded model below the VRAM
#              ratio floor, or (with --bench) tokens/s below threshold.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: docker (user in the docker group), nvidia-smi on the host,
#               curl, jq; notify-send for --notify
#
# Deployed payload, self-contained: it does not source shared/logging.sh so
# that it runs from ~/.local/bin under a systemd user unit, or piped over ssh.
#
# Output: exactly one line. "OK ollama-gpu: ..." exit 0, or
#         "FAIL ollama-gpu: <reason>" exit 1. Usage errors exit 2.
#
# Configuration (environment, or KEY=VALUE lines in $OGW_CONFIG, default
# ~/.config/ollama-gpu-watch/config):
#   OGW_CONTAINER          container name                    (ollama)
#   OGW_URL                Ollama API base                   (http://localhost:11434)
#   OGW_MIN_VRAM_RATIO     floor for size_vram/size per loaded model (0.50;
#                          a healthy qwen3.6:35b sits at ~0.90, a detached
#                          GPU reads 0.00)
#   OGW_BENCH_MODEL        model for --bench; default = smallest loaded model
#   OGW_BENCH_TOKENS       num_predict for --bench               (32)
#   OGW_MIN_TOKS           absolute tokens/s floor for --bench   (10)
#   OGW_BASELINE_FRACTION  --bench fails below this x baseline   (0.30)
#   OGW_BASELINE_FILE      stored baselines, "<model> <tok/s>" per line
#                          (~/.local/state/ollama-gpu-watch/baseline)
#   OGW_TIMEOUT            seconds for each docker/curl call     (20)
# Test seams (used by scripts/test.sh): OGW_DOCKER, OGW_NVIDIA_SMI,
# OGW_CURL, OGW_PROC_VERSION.

set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: ollama-gpu-probe [--bench [--save-baseline]] [--textfile PATH] [--notify]
  --bench          timed generation against a loaded model (may load OGW_BENCH_MODEL)
  --save-baseline  with --bench: store the measured tokens/s as that model's baseline
  --textfile PATH  write a node-exporter textfile-collector metric file (atomic)
  --notify         on FAIL, raise a desktop notification with notify-send
USAGE
}

usage_error() { echo "usage error: $* (see --help)" >&2; exit 2; }

BENCH=0 SAVE_BASELINE=0 TEXTFILE="" NOTIFY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bench) BENCH=1 ;;
    --save-baseline) SAVE_BASELINE=1 ;;
    --textfile) [ $# -ge 2 ] || usage_error "--textfile needs a path"; TEXTFILE="$2"; shift ;;
    --notify) NOTIFY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
  shift
done
if [ "$SAVE_BASELINE" -eq 1 ] && [ "$BENCH" -eq 0 ]; then
  usage_error "--save-baseline requires --bench"
fi

OGW_CONFIG="${OGW_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/ollama-gpu-watch/config}"
if [ -f "$OGW_CONFIG" ]; then
  # shellcheck disable=SC1090
  . "$OGW_CONFIG"
fi
OGW_CONTAINER="${OGW_CONTAINER:-ollama}"
OGW_URL="${OGW_URL:-http://localhost:11434}"
OGW_MIN_VRAM_RATIO="${OGW_MIN_VRAM_RATIO:-0.50}"
OGW_BENCH_MODEL="${OGW_BENCH_MODEL:-}"
OGW_BENCH_TOKENS="${OGW_BENCH_TOKENS:-32}"
OGW_MIN_TOKS="${OGW_MIN_TOKS:-10}"
OGW_BASELINE_FRACTION="${OGW_BASELINE_FRACTION:-0.30}"
OGW_BASELINE_FILE="${OGW_BASELINE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/ollama-gpu-watch/baseline}"
OGW_TIMEOUT="${OGW_TIMEOUT:-20}"
DOCKER="${OGW_DOCKER:-docker}"
NVIDIA_SMI="${OGW_NVIDIA_SMI:-nvidia-smi}"
CURL="${OGW_CURL:-curl}"
PROC_VERSION="${OGW_PROC_VERSION:-/proc/driver/nvidia/version}"

host_driver="unknown" container_driver="unknown" gpu_name="unknown"
detail="" bench_toks="" vram_lines=""

# Collapse to one line, cap the length: the reason goes into a log line, a
# notification and nothing else.
oneline() { tr '\n\r' '  ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-200; }

write_textfile() {
  local ok="$1" dir tmp
  [ -n "$TEXTFILE" ] || return 0
  dir="$(dirname "$TEXTFILE")"
  mkdir -p "$dir" || return 0
  tmp="$(mktemp "$dir/.ollama_gpu_ok.XXXXXX")" || return 0
  {
    echo "# HELP ollama_gpu_ok 1 if the Ollama container can reach the GPU and loaded models are GPU-resident, else 0."
    echo "# TYPE ollama_gpu_ok gauge"
    printf 'ollama_gpu_ok{container="%s",host_driver="%s",container_driver="%s"} %s\n' \
      "$OGW_CONTAINER" "$host_driver" "$container_driver" "$ok"
    echo "# HELP ollama_gpu_probe_timestamp_seconds Unix time of the last probe run."
    echo "# TYPE ollama_gpu_probe_timestamp_seconds gauge"
    echo "ollama_gpu_probe_timestamp_seconds $(date +%s)"
    if [ -n "$vram_lines" ]; then
      echo "# HELP ollama_gpu_vram_ratio size_vram/size for each loaded model."
      echo "# TYPE ollama_gpu_vram_ratio gauge"
      printf '%s' "$vram_lines"
    fi
    if [ -n "$bench_toks" ]; then
      echo "# HELP ollama_gpu_bench_tokens_per_second Warm decode rate from the last --bench run."
      echo "# TYPE ollama_gpu_bench_tokens_per_second gauge"
      printf 'ollama_gpu_bench_tokens_per_second{model="%s"} %s\n' "$bench_model" "$bench_toks"
    fi
  } > "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$TEXTFILE"
}

fail() {
  local reason
  reason="$(printf '%s' "$*" | oneline)"
  echo "FAIL ollama-gpu: $reason"
  write_textfile 0
  if [ "$NOTIFY" -eq 1 ] && command -v notify-send >/dev/null 2>&1; then
    notify-send -u critical -a ollama-gpu-watch "Ollama is not on the GPU" "$reason" 2>/dev/null || true
  fi
  exit 1
}

for c in "$DOCKER" "$CURL" jq; do
  command -v "$c" >/dev/null 2>&1 || fail "required command '$c' not found"
done

# --- (a) host driver ---------------------------------------------------------
if out="$(timeout "$OGW_TIMEOUT" "$NVIDIA_SMI" --query-gpu=driver_version --format=csv,noheader 2>&1)" \
   && [[ "$out" =~ ^[0-9]+(\.[0-9]+)+ ]]; then
  host_driver="$(printf '%s\n' "$out" | head -n1 | tr -d ' ')"
elif [ -r "$PROC_VERSION" ]; then
  # "NVRM version: NVIDIA UNIX x86_64 Kernel Module  595.91.07  <date>"
  host_driver="$(sed -n 's/^NVRM version:.*Kernel Module[^0-9]*\([0-9][0-9.]*\).*/\1/p' "$PROC_VERSION" | head -n1)"
  [ -n "$host_driver" ] || host_driver="unknown"
fi
[ "$host_driver" != "unknown" ] || fail "host nvidia driver not readable (nvidia-smi and $PROC_VERSION both failed) - host problem, not a container one"

# --- container must exist and run -------------------------------------------
running="$(timeout "$OGW_TIMEOUT" "$DOCKER" inspect -f '{{.State.Running}}' "$OGW_CONTAINER" 2>&1)" \
  || fail "container '$OGW_CONTAINER' not inspectable: $running"
[ "$running" = "true" ] || fail "container '$OGW_CONTAINER' is not running (State.Running=$running)"

# --- (a) NVML inside the container ------------------------------------------
if ! out="$(timeout "$OGW_TIMEOUT" "$DOCKER" exec "$OGW_CONTAINER" nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>&1)"; then
  fail "NVML broken inside container '$OGW_CONTAINER' (host driver $host_driver): $out - fix: docker restart $OGW_CONTAINER"
fi
if printf '%s' "$out" | grep -qiE 'Failed to initialize NVML|version mismatch|NVIDIA-SMI has failed|No devices were found'; then
  fail "NVML broken inside container '$OGW_CONTAINER' (host driver $host_driver): $out - fix: docker restart $OGW_CONTAINER"
fi
first="$(printf '%s\n' "$out" | head -n1)"
gpu_name="$(printf '%s' "$first" | cut -d, -f1 | sed 's/^ *//; s/ *$//')"
container_driver="$(printf '%s' "$first" | cut -d, -f2 | tr -d ' ')"
[[ "$container_driver" =~ ^[0-9]+(\.[0-9]+)+$ ]] \
  || fail "unparseable nvidia-smi output inside container: $out"

# --- (b) driver versions must agree -----------------------------------------
if [ "$container_driver" != "$host_driver" ]; then
  fail "driver mismatch: host $host_driver, container $container_driver (driver upgraded under a running container) - fix: docker restart $OGW_CONTAINER"
fi

# --- (c) every loaded model must be GPU-resident ------------------------------
ps_json="$(timeout "$OGW_TIMEOUT" "$CURL" -sf --max-time "$OGW_TIMEOUT" "$OGW_URL/api/ps" 2>&1)" \
  || fail "Ollama API $OGW_URL/api/ps unreachable"
models="$(printf '%s' "$ps_json" | jq -r '.models[]? | "\(.name) \(.size) \(.size_vram // 0)"' 2>/dev/null)" \
  || fail "unparseable /api/ps response"
model_summary="" low=""
while read -r name size vram; do
  [ -n "$name" ] || continue
  ratio="$(awk -v v="$vram" -v s="$size" 'BEGIN { if (s > 0) printf "%.3f", v / s; else print "0.000" }')"
  vram_lines+="ollama_gpu_vram_ratio{model=\"$name\"} $ratio"$'\n'
  pct="$(awk -v r="$ratio" 'BEGIN { printf "%.1f", r * 100 }')"
  model_summary+="${model_summary:+,}$name@${pct}%vram"
  if awk -v r="$ratio" -v m="$OGW_MIN_VRAM_RATIO" 'BEGIN { exit !(r < m) }'; then
    low+="${low:+, }$name size_vram=$vram of size=$size (${pct}% < floor $(awk -v m="$OGW_MIN_VRAM_RATIO" 'BEGIN { printf "%.0f", m * 100 }')%)"
  fi
done <<< "$models"
[ -z "$low" ] || fail "model running on CPU: $low - fix: docker restart $OGW_CONTAINER"
[ -n "$model_summary" ] || model_summary="none-loaded"

# --- optional: timed generation -------------------------------------------------
bench_model=""
if [ "$BENCH" -eq 1 ]; then
  bench_model="$OGW_BENCH_MODEL"
  if [ -z "$bench_model" ]; then
    bench_model="$(printf '%s' "$ps_json" | jq -r '[.models[]?] | sort_by(.size) | .[0].name // empty')"
  fi
  [ -n "$bench_model" ] || fail "--bench: no model loaded and OGW_BENCH_MODEL unset; refusing to pick one to load"
  req="$(jq -cn --arg m "$bench_model" --argjson n "$OGW_BENCH_TOKENS" \
    '{model: $m, prompt: "Count from 1 to 40, separated by spaces.", stream: false, think: false, options: {num_predict: $n, temperature: 0}}')"
  gen="$(timeout 300 "$CURL" -sf --max-time 300 -H 'Content-Type: application/json' -d "$req" "$OGW_URL/api/generate" 2>&1)" \
    || fail "--bench: /api/generate on $bench_model failed or exceeded 300s"
  # eval_duration excludes model load time, so this is the warm decode rate.
  bench_toks="$(printf '%s' "$gen" | jq -r 'if (.eval_count // 0) > 0 and (.eval_duration // 0) > 0 then (.eval_count / (.eval_duration / 1e9) * 10 | round / 10) else empty end')"
  [ -n "$bench_toks" ] || fail "--bench: no eval_count/eval_duration in /api/generate response for $bench_model"
  baseline=""
  if [ -r "$OGW_BASELINE_FILE" ]; then
    baseline="$(awk -v m="$bench_model" '$1 == m { b = $2 } END { print b }' "$OGW_BASELINE_FILE")"
  fi
  if [ "$SAVE_BASELINE" -eq 1 ]; then
    mkdir -p "$(dirname "$OGW_BASELINE_FILE")"
    { [ -r "$OGW_BASELINE_FILE" ] && awk -v m="$bench_model" '$1 != m' "$OGW_BASELINE_FILE"; echo "$bench_model $bench_toks"; } \
      > "$OGW_BASELINE_FILE.tmp" && mv -f "$OGW_BASELINE_FILE.tmp" "$OGW_BASELINE_FILE"
    baseline="$bench_toks"
  fi
  floor="$OGW_MIN_TOKS"
  if [ -n "$baseline" ]; then
    floor="$(awk -v b="$baseline" -v f="$OGW_BASELINE_FRACTION" -v a="$OGW_MIN_TOKS" 'BEGIN { x = b * f; if (a > x) x = a; printf "%.1f", x }')"
  fi
  if awk -v t="$bench_toks" -v f="$floor" 'BEGIN { exit !(t < f) }'; then
    fail "--bench: $bench_model decodes at $bench_toks tok/s, below floor $floor (baseline ${baseline:-none}) - fix: docker restart $OGW_CONTAINER"
  fi
  detail=" bench=$bench_model@${bench_toks}tok/s(floor $floor, baseline ${baseline:-none})"
fi

write_textfile 1
echo "OK ollama-gpu: gpu=\"$gpu_name\" driver host=$host_driver container=$container_driver models=$model_summary$detail"
exit 0
