#!/bin/bash
# Dry run of the Mac launcher with a mock claude and a real local LiteLLM on a
# test port (never 4000). Works on Linux or macOS.
#
#   mac/tests/dry_run.sh [port] [bash-binary]
#
# Copies mac/ and shared/ from this checkout into a throwaway folder and uses a
# throwaway HOME. First mac/setup.sh installs everything (fake InferHub key on
# stdin) and writes claude-acs without starting the proxy. Then claude-acs runs
# the launcher with the picker answers piped in: folder 3 (second subfolder),
# confirm, main 2 (GLM 5.3 Flash), advisor 10 (MiniMax M3). No
# LITELLM_MASTER_KEY is set, so the proxy runs keyless. There is no GitHub
# login in the throwaway HOME, so shared/ire answers from its built-in table.
# Then it checks the argv, cwd and environment the mock received, that the
# proxy listens on 127.0.0.1 only, serves the seat and fast aliases, and that
# mac/stop-litellm.sh stops it by its own PID (never by port).
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
  [ -n "${LITELLM_DANGEROUSLY_PERMIT_WEAK_OR_UNSET_MASTER_KEY:-}" ] && echo "weak_key_flag_leaked: yes"
  [ -n "${CCL_IRE_JSON:-}" ] && [ -f "$CCL_IRE_JSON" ] && echo "ire_json: present"
  [ -n "${CCL_IRE_JSON:-}" ] && python3 -c 'import json,os,sys; sys.exit(0 if isinstance(json.load(open(os.environ["CCL_IRE_JSON"])).get("frontier"), list) else 1)' 2>/dev/null && echo "ire_frontier_key: present"
} > "$MOCK_CLAUDE_OUT"
MOCK
chmod +x "$T/bin/claude"
stop_proxy() {
  local pid
  pid="$(cat "$LL/logs/litellm.pid" 2>/dev/null)"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
}
trap stop_proxy EXIT
run_env() {
  env -i HOME="$T/home" PATH="$T/home/.local/bin:$T/bin:$PATH" TERM=xterm \
    LITELLM_PORT="$PORT" MOCK_CLAUDE_OUT="$T/claude-call.txt" \
    ANTHROPIC_AUTH_TOKEN=should-be-cleared CKFF_DEFAULT_KEY=should-be-cleared ckff_api_url=http://cleared \
    CLAUDE_CODE_OAUTH_TOKEN=should-be-cleared ANTHROPIC_DEFAULT_OPUS_MODEL=should-be-cleared \
    "$@"
}
fail=0
printf 'fake-inferhub-key\n' | run_env "$BASH_BIN" "$REPO/mac/setup.sh" > "$T/setup-output.txt" 2>&1
echo "setup exit: $?"
SHIM="$T/home/.local/bin/claude-acs"
[ -x "$SHIM" ] || { echo "setup.sh did not write claude-acs"; tail -30 "$T/setup-output.txt"; exit 1; }
grep -qF "$LAUNCHER" "$SHIM" || { echo "claude-acs does not point at this checkout's launcher"; fail=1; }
[ -f "$LL/logs/litellm.pid" ] && { echo "setup.sh started the proxy (it should not)"; fail=1; }
[ -x "$LL/.litellm-venv/bin/litellm" ] || { echo "setup.sh did not build the LiteLLM venv"; fail=1; }
run_env "$BASH_BIN" "$REPO/mac/setup.sh" --check > "$T/check-output.txt" 2>&1
grep -q "ok  claude-acs" "$T/check-output.txt" || { echo "setup.sh --check does not see claude-acs"; fail=1; }
grep -q "fake-inferhub-key" "$T/check-output.txt" && { echo "setup.sh --check printed the key"; fail=1; }
printf '3\ny\n2\n10\n' | run_env "$BASH_BIN" "$SHIM" > "$T/launcher-output.txt" 2>&1
echo "launcher exit: $?"
cat "$T/claude-call.txt" 2>/dev/null || { echo "mock claude never ran"; tail -40 "$T/launcher-output.txt"; tail -40 "$T/home/.local/state/claude-inferhub/launcher.log" 2>/dev/null; exit 1; }
expect() { grep -qxF "$1" "$T/claude-call.txt" || { echo "MISSING: $1"; fail=1; }; }
expect "argv: --model sonnet --permission-mode bypassPermissions"
expect "cwd: $T/home/work/beta-svc"
expect "ANTHROPIC_API_KEY=<set>"
expect "api_key_is_local: yes"
expect "ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT"
expect "ANTHROPIC_MODEL=sonnet"
expect "ANTHROPIC_SMALL_FAST_MODEL=small-fast"
expect "ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5"
expect "ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5-5"
expect "ANTHROPIC_DEFAULT_FABLE_MODEL=claude-fable-5"
expect "ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5-20251001"
expect "ire_json: present"
expect "ire_frontier_key: present"
grep -q "weak_key_flag_leaked" "$T/claude-call.txt" && { echo "keyless flag reached claude (proxy only)"; fail=1; }
grep -q "IRE: source=defaults" "$T/launcher-output.txt" || { echo "IRE status line missing"; fail=1; }
n="$(grep -c -E '^(ANTHROPIC_|CLAUDE_CODE_|CKFF_|ckff_)' "$T/claude-call.txt")"
[ "$n" = "8" ] || { echo "expected exactly 8 ANTHROPIC_* vars and no CKFF/CLAUDE_CODE vars, got $n"; fail=1; }
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
# Keyless proxy serves the seat and the fast aliases, from loopback, no key.
models="$(curl -fsS -m 5 "http://127.0.0.1:$PORT/v1/models" 2>/dev/null)"
for name in sonnet opus haiku small-fast; do
  printf '%s' "$models" | grep -q "\"$name\"" || { echo "proxy does not serve $name"; fail=1; }
done
# The weak-key flag is in the proxy's own environment (Linux can check).
if [ -r "/proc/$pid/environ" ]; then
  tr '\0' '\n' < "/proc/$pid/environ" | grep -qx "LITELLM_DANGEROUSLY_PERMIT_WEAK_OR_UNSET_MASTER_KEY=true" \
    || { echo "proxy process lacks the keyless flag"; fail=1; }
fi
# Stop by PID through the stop script.
"$BASH_BIN" "$REPO/mac/stop-litellm.sh" > "$T/stop-output.txt" 2>&1 || { echo "stop-litellm.sh failed"; cat "$T/stop-output.txt"; fail=1; }
if kill -0 "$pid" 2>/dev/null; then echo "proxy still running after stop-litellm.sh"; fail=1; fi
[ -f "$LL/logs/litellm.pid" ] && { echo "PID file left behind"; fail=1; }
# The launcher itself must have run under the bash being tested.
# shellcheck disable=SC2016  # $BASH_VERSION is for the child bash to expand
want_bash="$("$BASH_BIN" -c 'echo "$BASH_VERSION"')"
grep -qF "(bash $want_bash)" "$T/launcher-output.txt" || { echo "launcher did not run under $BASH_BIN ($want_bash)"; fail=1; }
echo "workdir: $T"
if [ "$fail" = 0 ]; then echo "DRY RUN: PASS"; else echo "DRY RUN: FAIL"; exit 1; fi
