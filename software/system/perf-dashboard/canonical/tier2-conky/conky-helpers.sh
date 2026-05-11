#!/usr/bin/env bash
# Helpers for the perf-dashboard Conky widget. Called from conkyrc via ${execi}.
# Usage: conky-helpers.sh <nvidia|cpu_temp>
#
# Conky's ${execi shellcmd} balances braces while parsing the variable, so we
# cannot inline awk/sed pipelines that contain { }. All such logic lives here.

case "${1:-}" in
  nvidia)
    # Emit a three-line block when the dGPU is awake; otherwise a single
    # "(asleep / unavailable)" line. nvidia-smi prints nothing when the GPU
    # is sleeping under PRIME render-offload.
    out=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,temperature.gpu \
          --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
    if [ -z "$out" ]; then
      echo "(asleep / unavailable)"
      exit 0
    fi
    IFS=, read -r u m t <<< "$out"
    printf 'Usage: %s%%\nVRAM:  %s MB\nTemp:  %s°C\n' "$u" "$m" "$t"
    ;;
  cpu_temp)
    # Print the first CPU temperature reported by lm-sensors, stripped to
    # just the number. Covers AMD k10temp (Tctl/Tdie/Tccd1) and Intel
    # coretemp (Package id 0 / Core 0).
    sensors 2>/dev/null \
      | grep -m1 -E '^(Tctl|Tdie|Tccd1|Package id 0|Core 0)' \
      | sed 's/.*: *+\?\([0-9.]*\).*/\1/'
    ;;
  *)
    echo "n/a"
    ;;
esac
