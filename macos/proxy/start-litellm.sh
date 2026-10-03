#!/usr/bin/env bash
# Start the local LiteLLM proxy bound to loopback, serving InferHub seats.
# macOS counterpart of litellm-ckff-ops/start-litellm.ps1.
#
#   ./start-litellm.sh [-Background] [-Port N] [-SkipSync]
#
# The real InferHub key is read from ~/Documents/secrets/.env at runtime and
# exported here only for the proxy process. It is never written to this script.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$ROOT/.litellm-venv"
PY="$VENV/bin/python"
CONFIG="$ROOT/config/inferhub_seats.yaml"
ENV_FILE="${ACS_ENV_FILE:-$HOME/Documents/secrets/.env}"
LOG_DIR="$ROOT/logs"
PID_FILE="$ROOT/logs/litellm.pid"

BACKGROUND=0
PORT=4000

while [ $# -gt 0 ]; do
  case "$1" in
    -Background|-background|-b) BACKGROUND=1; shift ;;
    -Port|-port|-p) PORT="${2:?Port needs a value}"; shift 2 ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
done

die() { printf '%s\n' "$*" >&2; exit 1; }

[ -x "$PY" ] || die "venv missing at $VENV (uv venv $VENV && uv pip install --python $PY 'litellm[proxy]')"
[ -f "$CONFIG" ] || die "missing $CONFIG - run scripts/apply_seat.py first"

mkdir -p "$LOG_DIR"

# Read INFERHUB_API_KEY from the env file without echoing it.
read_env_value() {
  local path="$1" name="$2" line
  [ -r "$path" ] || return 0
  line=$(grep -m1 -E "^[[:space:]]*${name}[[:space:]]*=" "$path" 2>/dev/null || true)
  [ -n "$line" ] || return 0
  line="${line#*=}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  line="${line%\"}"; line="${line#\"}"
  line="${line%\'}"; line="${line#\'}"
  printf '%s' "$line"
}

# shellcheck disable=SC2155  # export masks the return value; harmless here because
#                             the next line validates the value explicitly.
export INFERHUB_API_KEY="$(read_env_value "$ENV_FILE" INFERHUB_API_KEY)"
[ -n "$INFERHUB_API_KEY" ] || die "INFERHUB_API_KEY not found in $ENV_FILE"

if curl -fsS -m 2 -o /dev/null "http://127.0.0.1:${PORT}/health/liveliness" 2>/dev/null; then
  printf 'LiteLLM already healthy on 127.0.0.1:%s\n' "$PORT"
  exit 0
fi

printf 'Starting LiteLLM on 127.0.0.1:%s ...\n' "$PORT"

if [ "$BACKGROUND" -eq 1 ]; then
  # Invoke the console script, not `python -m litellm`: the package has no
  # __main__ and cannot be executed directly.
  nohup "$VENV/bin/litellm" --config "$CONFIG" --host 127.0.0.1 --port "$PORT" \
    >>"$LOG_DIR/litellm.log" 2>&1 &
  echo $! >"$PID_FILE"
  printf 'pid=%s log=%s\n' "$(cat "$PID_FILE")" "$LOG_DIR/litellm.log"
else
  exec "$VENV/bin/litellm" --config "$CONFIG" --host 127.0.0.1 --port "$PORT"
fi

# Background mode: wait for health before returning so callers can rely on it.
if [ "$BACKGROUND" -eq 1 ]; then
  deadline=$(( $(date +%s) + 120 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl -fsS -m 2 -o /dev/null "http://127.0.0.1:${PORT}/health/liveliness" 2>/dev/null; then
      printf 'LiteLLM healthy on 127.0.0.1:%s\n' "$PORT"
      exit 0
    fi
    sleep 2
  done
  printf 'LiteLLM did not become healthy in 120s. Tail %s\n' "$LOG_DIR/litellm.log" >&2
  exit 1
fi