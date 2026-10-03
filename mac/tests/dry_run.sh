#!/bin/bash
# Dry run of "Launch Claude InferHub.command" with a mock claude and a real
# local LiteLLM on a test port (never 4000). Works on Linux or macOS.
#
#   mac/tests/dry_run.sh [port] [bash-binary]
#
# Copies mac/ and shared/ from this checkout into a throwaway folder, uses a
# throwaway HOME and a fake InferHub key, and pipes the picker answers:
# folder 3 (second subfolder), confirm, main 2 (GLM 5.3 Flash), advisor 10
# (MiniMax M3). No LITELLM_MASTER_KEY is set, so the proxy runs keyless.
# Then it checks the argv, cwd and environment the mock received, that the
# proxy listens on 127.0.0.1 only, and that the seat reached the running proxy.
# The test proxy is stopped at the end (by its own PID, never by port).
set -u
PORT="${1:-4100}"
BASH_BIN="${2:-bash}"
[ "$PORT" = "4000" ] && { echo "refusing to test on port 4000" >&2; exit 2; }
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"
REPO="$T/repo"
mkdir -p "$REPO" "$T/home/work/alpha-app" "$T/home/work/beta-svc" "$T/home/work/.hidden" "$T/bin" "$T/home/.claude"
cp -R "$SRC/mac" "$SRC/shared" "$REPO/" || exit 1
rm -rf "$REPO/shared/litellm/.litellm-venv" "$REPO/shared/litellm/logs"
LAUNCHER="$REPO/mac/Launch Claude InferHub.command"
LL="$REPO/shared/litellm"
echo '{"theme":"dark"}' > "$T/home/.claude/settings.json"
cat > "$T/bin/claude" <<'MOCK'
#!/bin/bash
{
  echo "argv: $*"
  echo "cwd: $(pwd)"
  env | sort | awk -F= '/^(ANTHROPIC_|CLAUDE_CODE_|CKFF_|ckff_)/ {
    if ($1 == "ANTHROPIC_API_KEY") print $1 "=<set>"; else print }'
  [ "${ANTHROPIC_API_KEY:-}" = "local" ] && echo "api_key_is_local: yes"
} > "$MOCK_CLAUDE_OUT"
MOCK
chmod +x "$T/bin/claude"
stop_proxy() {
  local pid
  pid="$(cat "$LL/logs/litellm.pid" 2>/dev/null)"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
}
trap stop_proxy EXIT
printf 'fake-inferhub-key\n3\ny\n2\n10\n' | env -i HOME="$T/home" PATH="$T/bin:$PATH" TERM=xterm \
  LITELLM_PORT="$PORT" MOCK_CLAUDE_OUT="$T/claude-call.txt" \
  ANTHROPIC_AUTH_TOKEN=should-be-cleared CKFF_DEFAULT_KEY=should-be-cleared ckff_api_url=http://cleared \
  CLAUDE_CODE_OAUTH_TOKEN=should-be-cleared ANTHROPIC_DEFAULT_OPUS_MODEL=should-be-cleared \
  "$BASH_BIN" "$LAUNCHER" > "$T/launcher-output.txt" 2>&1
echo "launcher exit: $?"
cat "$T/claude-call.txt" 2>/dev/null || { echo "mock claude never ran"; tail -40 "$T/launcher-output.txt"; tail -40 "$T/home/.local/state/claude-inferhub/launcher.log" 2>/dev/null; exit 1; }
fail=0
expect() { grep -qxF "$1" "$T/claude-call.txt" || { echo "MISSING: $1"; fail=1; }; }
expect "argv: --model sonnet --permission-mode bypassPermissions"
expect "cwd: $T/home/work/beta-svc"
expect "ANTHROPIC_API_KEY=<set>"
expect "api_key_is_local: yes"
expect "ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT"
expect "ANTHROPIC_MODEL=sonnet"
expect "ANTHROPIC_SMALL_FAST_MODEL=ih/ali/qwen3.8-flash"
n="$(grep -c -E '^(ANTHROPIC_|CLAUDE_CODE_|CKFF_|ckff_)' "$T/claude-call.txt")"
[ "$n" = "4" ] || { echo "expected exactly 4 ANTHROPIC_* vars and no CKFF/CLAUDE_CODE vars, got $n"; fail=1; }
grep -q '"main_inferhub_id": "cbcn/glm-5.3-flash"' "$LL/config/inferhub_seat.json" || { echo "seat main wrong"; fail=1; }
grep -q '"advisor_inferhub_id": "cbcn/minimax-m3"' "$LL/config/inferhub_seat.json" || { echo "seat advisor wrong"; fail=1; }
grep -q "LITELLM_MASTER_KEY" "$T/home/.config/inferhub/.env" 2>/dev/null && { echo "launcher wrote a master key"; fail=1; }
if [ -z "$(find "$T/home/.config/inferhub/.env" -perm 600 2>/dev/null)" ]; then
  echo "env file is not mode 600"; fail=1
fi
if grep -rq fake-inferhub-key "$T/launcher-output.txt" "$LL/logs" "$T/home/.local/state" "$T/home/Library/Logs" 2>/dev/null; then
  echo "key leaked into output or logs"; fail=1
fi
# Keyless hot reload: the picked seat must have reached the running proxy.
grep -q "Reloaded scope=seat" "$T/home/.local/state/claude-inferhub/launcher.log" "$T/home/Library/Logs/claude-inferhub/launcher.log" 2>/dev/null \
  || { echo "seat was not hot-reloaded into the running proxy"; fail=1; }
# Bound to loopback only.
pid="$(cat "$LL/logs/litellm.pid" 2>/dev/null)"
if [ -r "/proc/$pid/cmdline" ]; then
  tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q -- "--host 127.0.0.1" || { echo "proxy not started with --host 127.0.0.1"; fail=1; }
else
  ps -o args= -p "$pid" 2>/dev/null | grep -q -- "--host 127.0.0.1" || { echo "proxy not started with --host 127.0.0.1"; fail=1; }
fi
echo "workdir: $T"
if [ "$fail" = 0 ]; then echo "DRY RUN: PASS"; else echo "DRY RUN: FAIL"; exit 1; fi
