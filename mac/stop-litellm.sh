#!/bin/bash
# Stop the LiteLLM proxy this checkout started. Mac counterpart of
# windows/litellm/stop-litellm.ps1.
#
# Stops only the PID in shared/litellm/logs/litellm.pid, and only if that
# process is this checkout's LiteLLM (checked against its command line). It
# never kills by port or by process name, so a proxy on 127.0.0.1:4000 that
# something else started is left alone.
set -o pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LITELLM_DIR="$REPO_ROOT/shared/litellm"
PID_FILE="$LITELLM_DIR/logs/litellm.pid"

[ -f "$PID_FILE" ] || { printf 'No PID file at %s; nothing to stop.\n' "$PID_FILE"; exit 0; }
pid="$(tr -cd '0-9' < "$PID_FILE")"
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  printf 'PID %s is not running; removing the stale PID file.\n' "${pid:-?}"
  rm -f "$PID_FILE"
  exit 0
fi
args="$(ps -o args= -p "$pid" 2>/dev/null)"
case "$args" in
  *"$LITELLM_DIR/.litellm-venv/"*litellm*) ;;
  *) printf 'PID %s is not this checkout'"'"'s LiteLLM (%s); left alone.\n' "$pid" "${args:-unknown}" >&2
     exit 1 ;;
esac
kill "$pid" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done
if kill -0 "$pid" 2>/dev/null; then
  printf 'PID %s did not stop after 10 s; stop it by hand: kill %s\n' "$pid" "$pid" >&2
  exit 1
fi
rm -f "$PID_FILE"
printf 'Stopped LiteLLM (PID %s).\n' "$pid"
