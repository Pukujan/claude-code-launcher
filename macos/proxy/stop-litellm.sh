#!/usr/bin/env bash
# Stop the local LiteLLM proxy. macOS counterpart of stop-litellm.ps1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$ROOT/logs/litellm.pid"

if [ -f "$PID_FILE" ]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
    kill -9 "$pid" 2>/dev/null || true
    printf 'stopped pid %s\n' "$pid"
  else
    printf 'no live process for pid %s\n' "${pid:-<empty>}"
  fi
  rm -f "$PID_FILE"
  exit 0
fi

# Fall back to matching the process when the pid file was lost.
if pgrep -f "litellm --config $ROOT/config/inferhub_seats.yaml" >/dev/null 2>&1; then
  pkill -f "litellm --config $ROOT/config/inferhub_seats.yaml" || true
  printf 'stopped by pattern match\n'
  exit 0
fi

printf 'LiteLLM not running\n'