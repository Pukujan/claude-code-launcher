#!/usr/bin/env bash
# Stop the LiteLLM proxy this checkout started (Linux entry point).
#
# The stop logic is shared with mac/stop-litellm.sh, which is already safe on
# Linux: it reads shared/litellm/logs/litellm.pid, checks the PID's command line
# is this checkout's LiteLLM, and only then kills it. It never kills by port or
# by process name, so a proxy on 127.0.0.1:4000 that something else started is
# left alone. Kept as a thin entry so `linux/` has a stop command of its own and
# so this path never changes if the shared body moves later.
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
STOP="$REPO_ROOT/mac/stop-litellm.sh"

if [ ! -f "$STOP" ]; then
  printf 'stop-litellm.sh is missing at:\n  %s\nRun this from a complete claude-code-launcher checkout (git pull).\n' "$STOP" >&2
  exit 1
fi

exec "${BASH:-/bin/bash}" "$STOP" "$@"
