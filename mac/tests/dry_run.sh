#!/bin/bash
# Dry run of "Launch Claude InferHub.command" with a mock claude and a real
# local LiteLLM on a test port (never 4000). Works on Linux or macOS.
#
#   tests/dry_run.sh <path-to-litellm-ckff-ops-checkout> [port] [bash-binary]
#
# Uses a throwaway HOME, a fake InferHub key and pipes the picker answers:
# folder 3 (second subfolder), confirm, main 2 (GLM 5.3 Flash), advisor 10
# (MiniMax M3). Then checks the argv, cwd and environment the mock received.
set -u
SRC="${1:?usage: dry_run.sh <litellm-ckff-ops checkout> [port] [bash]}"
PORT="${2:-4100}"
BASH_BIN="${3:-bash}"
[ "$PORT" = "4000" ] && { echo "refusing to test on port 4000" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCHER="$HERE/Launch Claude InferHub.command"
T="$(mktemp -d)"
mkdir -p "$T/home/work/alpha-app" "$T/home/work/beta-svc" "$T/home/work/.hidden" "$T/bin" "$T/home/.claude"
git clone -q "$SRC" "$T/home/work/litellm-ckff-ops" || exit 1
echo '{"theme":"dark"}' > "$T/home/.claude/settings.json"
cat > "$T/bin/claude" <<'MOCK'
#!/bin/bash
{
  echo "argv: $*"
  echo "cwd: $(pwd)"
  env | sort | awk -F= '/^(ANTHROPIC_|CLAUDE_CODE_|CKFF_|ckff_)/ {
    if ($1 == "ANTHROPIC_API_KEY") print $1 "=<set>"; else print }'
} > "$MOCK_CLAUDE_OUT"
MOCK
chmod +x "$T/bin/claude"
printf 'fake-inferhub-key\n3\ny\n2\n10\n' | env -i HOME="$T/home" PATH="$T/bin:$PATH" TERM=xterm \
  LITELLM_PORT="$PORT" MOCK_CLAUDE_OUT="$T/claude-call.txt" \
  ANTHROPIC_AUTH_TOKEN=should-be-cleared CKFF_DEFAULT_KEY=should-be-cleared ckff_api_url=http://cleared \
  "$BASH_BIN" "$LAUNCHER" > "$T/launcher-output.txt" 2>&1
echo "launcher exit: $?"
cat "$T/claude-call.txt" 2>/dev/null || { echo "mock claude never ran"; tail -20 "$T/launcher-output.txt"; exit 1; }
fail=0
expect() { grep -qxF "$1" "$T/claude-call.txt" || { echo "MISSING: $1"; fail=1; }; }
expect "argv: --model sonnet --permission-mode bypassPermissions"
expect "cwd: $T/home/work/beta-svc"
expect "ANTHROPIC_API_KEY=<set>"
expect "ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT"
expect "ANTHROPIC_MODEL=sonnet"
expect "ANTHROPIC_SMALL_FAST_MODEL=ih/ali/qwen3.8-flash"
n="$(grep -c -E '^(ANTHROPIC_|CLAUDE_CODE_|CKFF_|ckff_)' "$T/claude-call.txt")"
[ "$n" = "4" ] || { echo "expected exactly 4 ANTHROPIC_* vars and no CKFF/CLAUDE_CODE vars, got $n"; fail=1; }
grep -q '"main_inferhub_id": "cbcn/glm-5.3-flash"' "$T/home/work/litellm-ckff-ops/config/inferhub_seat.json" || { echo "seat main wrong"; fail=1; }
grep -q '"advisor_inferhub_id": "cbcn/minimax-m3"' "$T/home/work/litellm-ckff-ops/config/inferhub_seat.json" || { echo "seat advisor wrong"; fail=1; }
if [ -z "$(find "$T/home/.config/inferhub/.env" -perm 600 2>/dev/null)" ]; then
  echo "env file is not mode 600"; fail=1
fi
if grep -rq fake-inferhub-key "$T/launcher-output.txt" "$T/home/work/litellm-ckff-ops/logs" "$T/home/.local/state" "$T/home/Library/Logs" 2>/dev/null; then
  echo "key leaked into output or logs"; fail=1
fi
echo "LiteLLM test proxy left running on 127.0.0.1:$PORT (pid file: $T/home/work/litellm-ckff-ops/logs/litellm.pid)"
echo "workdir: $T"
if [ "$fail" = 0 ]; then echo "DRY RUN: PASS"; else echo "DRY RUN: FAIL"; exit 1; fi
