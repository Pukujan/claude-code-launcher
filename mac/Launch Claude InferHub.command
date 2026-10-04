#!/bin/bash
# =============================================================================
# Launch Claude InferHub (macOS)
# Source of truth: Pukujan/claude-code-launcher mac/ (see SOURCES.md).
# Ported from ACS inferhub-litellm-macos v0.1.0 (agent-custom-setup PR #65).
# Mac counterpart of windows/launch-claude-inferhub.ps1.
#
# Double-click in Finder. First run installs what is missing (no sudo):
#   uv, a uv-managed Python, the venv with pinned LiteLLM under
#   shared/litellm/.litellm-venv, and Claude Code. Then it asks once for the
#   InferHub key, starts LiteLLM on 127.0.0.1:4000 from this repository's
#   shared/litellm folder (no other checkout needed), shows a folder picker and
#   the Windows model picker, seats the models and runs claude.
# Later runs skip everything already installed.
#
# The proxy is keyless and bound to 127.0.0.1 only. A LITELLM_MASTER_KEY is
# optional and passed through when set; otherwise claude gets the dummy key
# "local". Secrets are read from files at runtime and never printed:
#   <repo>/.env  and  ~/.config/inferhub/.env (mode 600)
# Written for the bash 3.2 that ships with macOS (no bash 4 features).
# =============================================================================

set -o pipefail
umask 022

# ---- settings (environment overrides are for tests and power users) --------
LITELLM_PORT="${LITELLM_PORT:-4000}"
PROXY_BASE="http://127.0.0.1:${LITELLM_PORT}"
WORK_ROOT="${CLAUDE_IH_WORK_ROOT:-$HOME/work}"
# This file lives in <repo>/mac/; the proxy files live in <repo>/shared/litellm.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LITELLM_DIR="$REPO_ROOT/shared/litellm"
IH_ENV_FILE="${INFERHUB_ENV_FILE:-$HOME/.config/inferhub/.env}"
HEALTH_TIMEOUT="${LITELLM_HEALTH_TIMEOUT:-300}"
PY_VERSION="${CLAUDE_IH_PYTHON:-3.12}"
NODE_MAJOR="${CLAUDE_IH_NODE_MAJOR:-24}"
UV_INSTALLER_URL="${UV_INSTALLER_URL:-https://astral.sh/uv/install.sh}"
CLAUDE_INSTALLER_URL="${CLAUDE_INSTALLER_URL:-https://claude.ai/install.sh}"

DEFAULT_MODEL_ID="cb/deepseek-v4.1-flash"
SEAT_ALIAS="sonnet"
SMALL_FAST_MODEL="ih/ali/qwen3.8-flash"

OS_NAME="$(uname -s)"
if [ "$OS_NAME" = "Darwin" ]; then
  LOG_DIR="${CLAUDE_IH_LOG_DIR:-$HOME/Library/Logs/claude-inferhub}"
  STATE_DIR="${CLAUDE_IH_STATE_DIR:-$HOME/Library/Application Support/claude-inferhub}"
else
  LOG_DIR="${CLAUDE_IH_LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-inferhub}"
  STATE_DIR="${CLAUDE_IH_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-inferhub}"
fi
LOG_FILE="$LOG_DIR/launcher.log"
VENV="$LITELLM_DIR/.litellm-venv"
VENV_PY="$VENV/bin/python"

# Pinned in shared/litellm/requirements.txt and requirements-overrides.txt,
# the same files Windows installs from. The overrides pin fastapi/starlette/
# sse-starlette below what LiteLLM declares, which uv does with --override.
# Change either file and the venv refreshes itself on the next run.
REQ_FILE="$LITELLM_DIR/requirements.txt"
OVR_FILE="$LITELLM_DIR/requirements-overrides.txt"
REQUIREMENTS="$(cat "$REQ_FILE" 2>/dev/null)"
OVERRIDES="$(cat "$OVR_FILE" 2>/dev/null)"

# HOOK(ire-models): the picker table, the same IRE Top 20 as the Windows
# launcher: rank|name|id|eligible|cost. It matches
# shared/litellm/config/top20-builtin.csv (tests/test_top20_tables.py checks).
MODELS='1|DeepSeek V4.1 Flash|cb/deepseek-v4.1-flash|true|0.022
2|GLM 5.3 Flash|cbcn/glm-5.3-flash|true|0.033
3|Gemini 3.8 Flash|ag/gemini-3.8-flash-high|false|0.066
4|DeepSeek V4 Flash|cbcn/deepseek-v4-flash|true|0.047
5|DeepSeek V4 Pro 0813|ali/deepseek-v4-pro-0813|false|0.083
6|Qwen3.8 Max 0902|ali/qwen3.8-max-0902|false|0.078
7|Qwen3.8 Flash|ali/qwen3.8-flash|true|0.008
8|Muse Spark 1.3 Contributor|cmc/meta/muse-spark-1.3-contributor|false|0.040
9|GPT 5.6 Luna|cx/gpt-5.6-luna|false|0.040
10|MiniMax M3|cbcn/minimax-m3|true|0.052
11|DeepSeek V4 Flash 0731|ali/deepseek-v4-flash-0731|false|0.091
12|Gemini 3.7 Flash|ag/gemini-3.7-flash-high|false|0.077
13|Gemini 3.6 Flash|ag/gemini-3.6-flash-high|false|0.081
14|DeepSeek V4 Pro|cbcn/deepseek-v4-pro|true|0.138
15|GLM 5.2|ali/glm-5.2|true|0.181
16|Hy4 Preview|cb/hy4-preview|false|0.077
17|Muse Spark 1.2 Contributor|cmc/meta/muse-spark-1.2-contributor|false|0.029
18|Qwen 3.8 Max|ali/qwen3.8-max|true|0.170
19|GLM 5.3|cbcn/glm-5.3|true|0.267
20|Kimi K2.7 Code|ali/kimi-k2.7-code|true|0.156'

# Env names handed to the LiteLLM process (values never logged).
PROXY_ENV_NAMES="INFERHUB_API_KEY INFERHUB_API_URL LITELLM_MASTER_KEY CKFF_DEFAULT_KEY CKFF_GROK_KEY CKFF_KIRO_KEY CKFF_KIMI_KEY CKFF_GEMINI_CLI_KEY CKFF_CODEX_CC_KEY CKFF_CODEX_PLUS_KEY CKFF_CODEX_PRO_KEY CKFF_IMAGEGEN_KEY CKFF_EMBED_KEY"

# Tools installed by this script land here; put them first on PATH.
PATH="$HOME/.local/bin:$STATE_DIR/node/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

# ---- output helpers ---------------------------------------------------------
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_FILE="/dev/null"

log() {
  printf '%s\n' "$*" >&2
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null
}

die() {
  log ""
  log "ERROR: $*"
  log "Full log: $LOG_FILE"
  if [ -t 0 ]; then
    printf 'Press Return to close this window. ' >&2
    read -r _ || true
  fi
  exit 1
}

# Run a command with its output going to the log file only.
quiet() {
  printf '%s + %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null
  "$@" >> "$LOG_FILE" 2>&1
}

ask() {  # ask "prompt" -> REPLY (reads stdin; Enter gives an empty string)
  printf '%s' "$1" >&2
  REPLY=""
  IFS= read -r REPLY || return 1
  return 0
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# env_get FILE NAME -> value of NAME=... in FILE (quotes stripped). No eval.
env_get() {
  local file="$1" name="$2" line key val
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(trim "$line")"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="$(trim "${line%%=*}")"
    key="${key#export }"
    [ "$key" = "$name" ] || continue
    val="$(trim "${line#*=}")"
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    printf '%s' "$val"
    return 0
  done < "$file"
  return 1
}

# secret NAME -> first value from <repo>/.env, then ~/.config/inferhub/.env,
# then the already-exported environment.
secret() {
  local v
  v="$(env_get "$REPO_ROOT/.env" "$1")" && [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  v="$(env_get "$IH_ENV_FILE" "$1")" && [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  eval "v=\"\${$1:-}\""
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  return 1
}

# Append NAME=value to the private env file (dir 700, file 600).
save_secret() {
  local name="$1" value="$2" dir
  dir="$(dirname "$IH_ENV_FILE")"
  mkdir -p "$dir" || die "cannot create $dir"
  chmod 700 "$dir" 2>/dev/null
  ( umask 077; touch "$IH_ENV_FILE" ) || die "cannot write $IH_ENV_FILE"
  chmod 600 "$IH_ENV_FILE" || die "cannot chmod 600 $IH_ENV_FILE"
  printf '%s=%s\n' "$name" "$value" >> "$IH_ENV_FILE" || die "cannot write $IH_ENV_FILE"
}

proxy_healthy() {
  # /health/liveliness first: /health can 500 without prisma, and
  # unauthenticated /v1/models fails when a master key is set.
  local p
  for p in /health/liveliness /health/readiness /health/liveness; do
    if curl -fsS -m 2 -o /dev/null "$PROXY_BASE$p" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

port_in_use() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$LITELLM_PORT" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  # No lsof: try to connect instead.
  (exec 3<>"/dev/tcp/127.0.0.1/$LITELLM_PORT") 2>/dev/null
}

# ---- bootstrap steps --------------------------------------------------------
need_curl() {
  command -v curl >/dev/null 2>&1 || die "curl is missing; it ships with macOS, so this Mac looks unusual. Install curl and try again."
}

ensure_workbench() {
  # The proxy files ship in this repository; nothing to clone.
  [ -f "$LITELLM_DIR/scripts/apply_inferhub_seat.py" ] && [ -f "$LITELLM_DIR/config/config.yaml" ] \
    && [ -n "$REQUIREMENTS" ] && [ -n "$OVERRIDES" ] && return 0
  die "$LITELLM_DIR is incomplete. Run this launcher from a full claude-code-launcher checkout (git pull to update)."
}

ensure_uv() {
  command -v uv >/dev/null 2>&1 && return 0
  need_curl
  log "Installing uv (Python manager, user install, no sudo) ..."
  curl -LsSf "$UV_INSTALLER_URL" 2>>"$LOG_FILE" | env UV_NO_MODIFY_PATH=1 sh >> "$LOG_FILE" 2>&1 \
    || die "uv install failed. Try it by hand: curl -LsSf https://astral.sh/uv/install.sh | sh"
  hash -r
  command -v uv >/dev/null 2>&1 || die "uv installed but not found in ~/.local/bin"
}

ensure_venv() {
  local stamp="$VENV/.claude-inferhub-requirements.txt" req
  if [ ! -x "$VENV_PY" ]; then
    log "Setting up Python $PY_VERSION and the LiteLLM venv (first run, a few minutes) ..."
    quiet uv python install "$PY_VERSION" || die "uv could not install Python $PY_VERSION"
    quiet uv venv --python "$PY_VERSION" "$VENV" || die "could not create venv at $VENV"
  fi
  if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$REQUIREMENTS
$OVERRIDES" ] \
     && "$VENV_PY" -c "import litellm, yaml" >/dev/null 2>&1; then
    return 0
  fi
  log "Installing pinned LiteLLM into $VENV ..."
  req="$STATE_DIR/requirements.txt"
  mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
  printf '%s\n' "$REQUIREMENTS" > "$req"
  printf '%s\n' "$OVERRIDES" > "$req.overrides"
  quiet uv pip install --python "$VENV_PY" -r "$req" --override "$req.overrides" \
    || die "LiteLLM install failed (details in the log). Check your network and run again."
  "$VENV_PY" -c "import litellm, yaml" >/dev/null 2>&1 || die "LiteLLM installed but does not import"
  printf '%s\n%s' "$REQUIREMENTS" "$OVERRIDES" > "$stamp"
}

ensure_node() {
  command -v npm >/dev/null 2>&1 && return 0
  if command -v brew >/dev/null 2>&1; then
    log "Installing Node with Homebrew ..."
    quiet brew install node && return 0
  fi
  [ "$OS_NAME" = "Darwin" ] || die "npm is missing; install Node.js and try again."
  local arch base sums file tmp want got
  case "$(uname -m)" in arm64) arch=arm64 ;; *) arch=x64 ;; esac
  base="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x"
  log "Installing Node $NODE_MAJOR into $STATE_DIR/node (user dir, no sudo) ..."
  tmp="$(mktemp -d)" || die "mktemp failed"
  sums="$(curl -fsSL "$base/SHASUMS256.txt")" || die "cannot reach $base"
  file="$(printf '%s\n' "$sums" | awk -v a="darwin-$arch.tar.gz" '$2 ~ a"$" {print $2; exit}')"
  want="$(printf '%s\n' "$sums" | awk -v a="darwin-$arch.tar.gz" '$2 ~ a"$" {print $1; exit}')"
  [ -n "$file" ] || die "no Node tarball for darwin-$arch at $base"
  curl -fsSL -o "$tmp/$file" "$base/$file" || die "Node download failed"
  got="$(shasum -a 256 "$tmp/$file" | awk '{print $1}')"
  [ "$got" = "$want" ] || die "Node tarball checksum mismatch; not installing"
  rm -rf "$STATE_DIR/node"
  mkdir -p "$STATE_DIR/node" || die "cannot create $STATE_DIR/node"
  tar -xzf "$tmp/$file" -C "$STATE_DIR/node" --strip-components 1 || die "Node unpack failed"
  rm -rf "$tmp"
  hash -r
}

ensure_claude() {
  command -v claude >/dev/null 2>&1 && return 0
  need_curl
  log "Installing Claude Code (official installer, user install) ..."
  if curl -fsSL "$CLAUDE_INSTALLER_URL" 2>>"$LOG_FILE" | bash >> "$LOG_FILE" 2>&1; then
    hash -r
    command -v claude >/dev/null 2>&1 && return 0
  fi
  log "Official installer did not work; trying npm into ~/.local instead ..."
  ensure_node
  quiet npm install -g --prefix "$HOME/.local" @anthropic-ai/claude-code \
    || die "Claude Code install failed. Install it by hand (curl -fsSL https://claude.ai/install.sh | bash) and run this again."
  hash -r
  command -v claude >/dev/null 2>&1 || die "Claude Code installed but 'claude' is not on PATH"
}

ensure_keys() {
  local key
  if ! secret INFERHUB_API_KEY >/dev/null; then
    log ""
    log "One-time setup: paste your InferHub API key. It will not be shown,"
    log "and it is saved only to $IH_ENV_FILE (readable by you alone)."
    printf 'InferHub API key: ' >&2
    key=""
    if [ -t 0 ]; then
      IFS= read -rs key || true
      printf '\n' >&2
    else
      IFS= read -r key || true
    fi
    key="$(trim "$key")"
    [ -n "$key" ] || die "No key entered. Run the launcher again when you have your InferHub key."
    save_secret INFERHUB_API_KEY "$key"
    key=""
    log "Saved INFERHUB_API_KEY to $IH_ENV_FILE (mode 600)."
  fi
  # No LITELLM_MASTER_KEY is needed: the proxy is keyless on 127.0.0.1. If
  # one is set it is passed through (export_proxy_env) and used by claude.
}

inferhub_url() {
  local u
  u="$(secret INFERHUB_API_URL)" || u=""
  [ -n "$u" ] || u="https://api.inferhub.dev/v1"
  u="${u%/}"
  case "$u" in */v1) ;; *) u="$u/v1" ;; esac
  printf '%s' "$u"
}

# Export the proxy's env names into the current (sub)shell.
export_proxy_env() {
  local n v
  for n in $PROXY_ENV_NAMES; do
    if v="$(secret "$n")"; then export "$n=$v"; fi
  done
  export INFERHUB_API_URL="$IH_URL"
}

fetch_ire() {
  # HOOK(ire): shared/ire/ire_fetch.py pulls IRE's Top 20, price policy and any
  # fallback picks from GitHub (5 s budget), then falls back to the last good
  # copy and then built-in defaults. Never fatal. The JSON lands in
  # $IRE_JSON for the ladder picker; its schema is in shared/ire/README.md.
  local py line
  IRE_JSON="$STATE_DIR/ire.json"
  py="$VENV_PY"; [ -x "$py" ] || py="$(command -v python3 || true)"
  if [ -z "$py" ] || ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    log "IRE: no Python or state folder; using the built-in model table"
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] && log "IRE: ${line#\[ire\] }"
  done < <("$py" "$REPO_ROOT/shared/ire/ire_fetch.py" --out "$IRE_JSON" 2>&1 >/dev/null)
  [ -f "$IRE_JSON" ] && export CCL_IRE_JSON="$IRE_JSON"
  return 0
}

ensure_top20() {
  local out="$LITELLM_DIR/config/inferhub_top20.yaml" csv
  [ -f "$out" ] && return 0
  # HOOK(ire): INFERHUB_TOP20_CSV wins, then shared/litellm/config/top20.csv
  # (written by an IRE fetch when one exists), then the IRE CSV in
  # ~/.config/inferhub, then shared/litellm/config/top20-builtin.csv.
  csv="${INFERHUB_TOP20_CSV:-}"
  if [ -z "$csv" ] && [ -f "$LITELLM_DIR/config/top20.csv" ]; then
    csv="$LITELLM_DIR/config/top20.csv"
  fi
  if [ -z "$csv" ] && [ -f "$HOME/.config/inferhub/research_model_top20_recommendations.csv" ]; then
    csv="$HOME/.config/inferhub/research_model_top20_recommendations.csv"
  fi
  if [ -z "$csv" ] && [ -f "$LITELLM_DIR/config/top20-builtin.csv" ]; then
    csv="$LITELLM_DIR/config/top20-builtin.csv"
  fi
  if [ -z "$csv" ]; then
    # No IRE CSV on this Mac: build one from the launcher's Top 20 table so the
    # workbench's own generator writes the same ih/ deployments as Windows.
    mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
    csv="$STATE_DIR/top20-builtin.csv"
    {
      printf 'recommendation_rank,model_family,recommendation_eligible,supply_weighted_median_cost_usdc_per_1m,model_ids\n'
      printf '%s\n' "$MODELS" | awk -F'|' '{printf "%s,%s,%s,%s,%s\n", $1, $2, $4, $5, $3}'
    } > "$csv"
  fi
  log "Writing InferHub Top 20 deployments from $(basename "$csv") ..."
  quiet "$VENV_PY" "$LITELLM_DIR/scripts/sync_inferhub_top20.py" --csv "$csv" --api-base "$IH_URL" \
    || die "sync_inferhub_top20.py failed (see log)"
}

ensure_proxy() {
  local pid deadline logs="$LITELLM_DIR/logs" seat="$LITELLM_DIR/config/inferhub_seat.json"
  if proxy_healthy; then
    log "LiteLLM proxy already up at $PROXY_BASE"
    return 0
  fi
  if port_in_use; then
    die "Something is listening on port $LITELLM_PORT but is not a healthy LiteLLM. Not touching it. Check with: lsof -nP -iTCP:$LITELLM_PORT -sTCP:LISTEN"
  fi
  # Seat + merged runtime.yaml must exist before the proxy boots (same as
  # start-litellm.ps1: default seat, apply aliases, merge, no reload).
  if [ -f "$seat" ]; then
    quiet "$VENV_PY" "$LITELLM_DIR/scripts/apply_inferhub_seat.py" --api-base "$IH_URL" --no-reload \
      || die "apply_inferhub_seat.py failed (see log)"
  else
    quiet "$VENV_PY" "$LITELLM_DIR/scripts/apply_inferhub_seat.py" --api-base "$IH_URL" \
      --main "$DEFAULT_MODEL_ID" --advisor "" --no-reload \
      || die "apply_inferhub_seat.py failed (see log)"
  fi
  mkdir -p "$logs" || die "cannot create $logs"
  log "Starting LiteLLM on $PROXY_BASE (background; logs in $logs) ..."
  (
    cd "$LITELLM_DIR" || exit 1
    export_proxy_env
    export PYTHONUTF8=1 LITELLM_LOCAL_MODEL_COST_MAP=True
    export PYTHONPATH="$LITELLM_DIR${PYTHONPATH:+:$PYTHONPATH}"
    exec nohup "$VENV/bin/litellm" --config "$LITELLM_DIR/config/runtime.yaml" \
      --host 127.0.0.1 --port "$LITELLM_PORT" < /dev/null \
      >> "$logs/litellm.out.log" 2>> "$logs/litellm.err.log"
  ) &
  pid=$!
  printf '%s\n' "$pid" > "$logs/litellm.pid" 2>/dev/null
  deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 2
    if proxy_healthy; then
      log "LiteLLM proxy is healthy at $PROXY_BASE"
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      die "LiteLLM exited during startup. See $logs/litellm.err.log"
    fi
  done
  die "LiteLLM did not become healthy at $PROXY_BASE within ${HEALTH_TIMEOUT}s (pid $pid still running). See $logs/litellm.err.log"
}

# ---- pickers ----------------------------------------------------------------
model_field() {  # model_field INDEX(1-based) FIELD(1-5)
  printf '%s\n' "$MODELS" | awk -F'|' -v i="$1" -v f="$2" 'NR == i {print $f}'
}

print_models() {  # print_models with_off
  local rank name id elig cost tag star
  if [ "$1" = "1" ]; then
    printf '   0  OFF  (disable advisor tool / seat aliases fall back to main)\n' >&2
  fi
  while IFS='|' read -r rank name id elig cost; do
    if [ "$elig" = "true" ]; then tag="eligible"; else tag="gated"; fi
    star=" "
    if [ "$1" != "1" ] && [ "$id" = "$DEFAULT_MODEL_ID" ]; then star="*"; fi
    printf '%s%3d  %-28s %-42s %-8s  ~%s/Mtok\n' "$star" "$rank" "$name" "$id" "$tag" "$cost" >&2
  done <<EOF
$MODELS
EOF
}

resolve_model() {  # resolve_model "<number or id>" -> index, or fail
  local want="$1" i=1 id
  case "$want" in
    ''|*[!0-9]*) ;;
    *) if [ "$want" -ge 1 ] && [ "$want" -le 20 ]; then printf '%s' "$want"; return 0; fi; return 1 ;;
  esac
  while [ "$i" -le 20 ]; do
    id="$(model_field "$i" 3)"
    [ "$id" = "$want" ] && { printf '%s' "$i"; return 0; }
    i=$((i + 1))
  done
  return 1
}

pick_main() {
  local idx
  if [ -n "${CLAUDE_IH_MAIN:-}" ]; then
    idx="$(resolve_model "$CLAUDE_IH_MAIN")" || die "CLAUDE_IH_MAIN=$CLAUDE_IH_MAIN is not in the Top 20 list"
    MAIN_ID="$(model_field "$idx" 3)"; MAIN_NAME="$(model_field "$idx" 2)"; return 0
  fi
  while :; do
    log ""
    log "Choose MAIN model (IRE Top 20). Default DeepSeek V4.1 Flash."
    log "MAIN executor (maps to alias sonnet/main). gated = ranked but not currently recommendation-eligible."
    print_models 0
    ask "Main model number [Enter = 1, q = quit]: " || die "Cancelled."
    REPLY="$(trim "$REPLY")"
    case "$REPLY" in q|Q) die "Cancelled." ;; '') REPLY=1 ;; esac
    if idx="$(resolve_model "$REPLY")"; then
      MAIN_ID="$(model_field "$idx" 3)"; MAIN_NAME="$(model_field "$idx" 2)"; return 0
    fi
    log "Please type a number from 1 to 20."
  done
}

pick_advisor() {
  local idx
  if [ -n "${CLAUDE_IH_ADVISOR+set}" ]; then
    case "$CLAUDE_IH_ADVISOR" in ''|0|off|OFF) ADVISOR_ID=""; ADVISOR_NAME=""; return 0 ;; esac
    idx="$(resolve_model "$CLAUDE_IH_ADVISOR")" || die "CLAUDE_IH_ADVISOR=$CLAUDE_IH_ADVISOR is not in the Top 20 list"
    ADVISOR_ID="$(model_field "$idx" 3)"; ADVISOR_NAME="$(model_field "$idx" 2)"; return 0
  fi
  while :; do
    log ""
    log "Choose ADVISOR model (IRE Top 20) or OFF."
    log "ADVISOR maps to alias opus/advisor. Mid-session use /advisor opus or /advisor sonnet (aliases), not raw InferHub ids."
    print_models 1
    ask "Advisor number [Enter = 0 OFF, q = quit]: " || die "Cancelled."
    REPLY="$(trim "$REPLY")"
    case "$REPLY" in
      q|Q) die "Cancelled." ;;
      ''|0|off|OFF) ADVISOR_ID=""; ADVISOR_NAME=""; return 0 ;;
    esac
    if idx="$(resolve_model "$REPLY")"; then
      ADVISOR_ID="$(model_field "$idx" 3)"; ADVISOR_NAME="$(model_field "$idx" 2)"; return 0
    fi
    log "Please type 0 for OFF or a number from 1 to 20."
  done
}

browse_folder() {
  if ! command -v osascript >/dev/null 2>&1; then
    log "Finder browsing only works on macOS."
    return 1
  fi
  osascript -e "POSIX path of (choose folder with prompt \"Choose a project folder for Claude Code\" default location (POSIX file \"$WORK_ROOT\"))" 2>/dev/null
}

confirm_folder() {
  ask "Launch Claude Code in $1 ? [Y/n]: " || die "Cancelled."
  case "$(trim "$REPLY")" in n|N|no|NO|No) return 1 ;; esac
  return 0
}

pick_folder() {
  local dirs d n i chosen
  if [ -n "${CLAUDE_IH_PROJECT:-}" ]; then
    [ -d "$CLAUDE_IH_PROJECT" ] || die "CLAUDE_IH_PROJECT=$CLAUDE_IH_PROJECT is not a folder"
    PROJECT_DIR="$(cd "$CLAUDE_IH_PROJECT" && pwd)"; return 0
  fi
  mkdir -p "$WORK_ROOT" 2>/dev/null
  while :; do
    # Default root first (the root itself), then its non-hidden subfolders.
    dirs="$WORK_ROOT"
    for d in "$WORK_ROOT"/*/; do
      [ -d "$d" ] || continue
      d="${d%/}"
      dirs="$dirs
$d"
    done
    log ""
    log "Choose a project folder (default root $WORK_ROOT)"
    n=0
    while IFS= read -r d; do
      n=$((n + 1))
      if [ "$n" -eq 1 ]; then
        printf '%4d  %s  (default root)\n' "$n" "$d" >&2
      else
        printf '%4d  %s\n' "$n" "$d" >&2
      fi
    done <<EOF
$dirs
EOF
    printf '   b  Browse... (choose a folder in Finder)\n' >&2
    ask "Folder number [Enter = 1, b = browse, q = quit]: " || die "Cancelled."
    REPLY="$(trim "$REPLY")"
    chosen=""
    case "$REPLY" in
      q|Q) die "Cancelled." ;;
      b|B) chosen="$(browse_folder)" || { log "No folder chosen."; continue; }
           chosen="${chosen%/}" ;;
      '') chosen="$WORK_ROOT" ;;
      *[!0-9]*) log "Please type a number, b or q."; continue ;;
      *) i=0
         while IFS= read -r d; do
           i=$((i + 1))
           [ "$i" -eq "$REPLY" ] && chosen="$d"
         done <<EOF
$dirs
EOF
         [ -n "$chosen" ] || { log "No folder number $REPLY."; continue; } ;;
    esac
    [ -d "$chosen" ] || { log "Not a folder: $chosen"; continue; }
    if confirm_folder "$chosen"; then
      PROJECT_DIR="$(cd "$chosen" && pwd)"
      return 0
    fi
  done
}

# ---- fallback ladders (issue #5) ----------------------------------------------
# After each seat is picked, show its default fallback ladder and let Alex
# accept it (Enter) or pick up to 3 rungs. Applied to the running proxy after
# apply_seat through /workbench/reload_runtime (scope ladder), no restart.
# CLAUDE_IH_LADDER=default takes the defaults without asking; =off skips the
# ladder step (the stock inferhub_fallbacks.yaml chains stay). With no
# terminal on stdin (scripts, CI) the defaults are taken.
LADDER_CLI="$REPO_ROOT/shared/ladder/ladder_cli.py"
LADDER_STATE="$LITELLM_DIR/config/ladder_state.json"

pick_ladder() {
  local role="$1" primary="$2" mode="${CLAUDE_IH_LADDER:-ask}"
  [ "$mode" = "off" ] && return 0
  local extra=()
  if [ "$mode" = "default" ] || [ ! -t 0 ]; then extra=(--non-interactive); fi
  "$VENV_PY" "$LADDER_CLI" choose --state "$LADDER_STATE" --role "$role" --primary "$primary" ${extra[@]+"${extra[@]}"} \
    || log "warning: ladder picker failed for $role; the stock chains stay"
}

apply_ladder() {
  [ "${CLAUDE_IH_LADDER:-ask}" = "off" ] && return 0
  [ -f "$LADDER_STATE" ] || return 0
  "$VENV_PY" "$LADDER_CLI" apply --state "$LADDER_STATE" --base-url "$PROXY_BASE" >> "$LOG_FILE" 2>&1 \
    && log "Fallback ladders applied to the running proxy." \
    || log "warning: could not apply the fallback ladders (see log); the stock chains stay"
}

# ---- seat + Claude settings ---------------------------------------------------
apply_seat() {
  log "Seating main=$MAIN_ID advisor=${ADVISOR_ID:-OFF} through LiteLLM ..."
  (
    export_proxy_env
    export LITELLM_BASE_URL="$PROXY_BASE"
    "$VENV_PY" "$LITELLM_DIR/scripts/apply_inferhub_seat.py" --api-base "$IH_URL" \
      --main "$MAIN_ID" --advisor "$ADVISOR_ID" --base-url "$PROXY_BASE"
  ) >> "$LOG_FILE" 2>&1 || die "apply_inferhub_seat.py failed (see log)"
}

sync_model_picker() {
  # Same as Sync-ModelPicker on Windows: only touches an existing settings file.
  local settings="$HOME/.claude/settings.json"
  [ -f "$settings" ] || return 0
  MODELS_TABLE="$MODELS" SEAT_ALIAS="$SEAT_ALIAS" "$VENV_PY" - "$settings" <<'PY' >> "$LOG_FILE" 2>&1 \
    || log "warning: could not sync the Claude model picker (see log)"
import json, os, sys
path = sys.argv[1]
seat = os.environ["SEAT_ALIAS"]
options = [
    {"model": seat, "label": "InferHub seat (sonnet alias)",
     "description": "Maps to seated Top 20 main via local LiteLLM", "behavesAs": "claude-sonnet-5"},
    {"model": "opus", "label": "InferHub seat (opus/advisor alias)",
     "description": "Maps to seated Top 20 advisor via local LiteLLM", "behavesAs": "claude-opus-4-6"},
]
for row in os.environ["MODELS_TABLE"].splitlines():
    rank, name, mid, elig, _cost = row.split("|")
    options.append({
        "model": "ih/" + mid,
        "label": name + " (InferHub ih/)",
        "description": "IRE Top 20 #" + rank + "; " + ("eligible" if elig == "true" else "gated")
                       + " - prefer sonnet/opus seats for advisor",
        "behavesAs": "claude-sonnet-5",
    })
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data["modelPicker"] = {"options": options}
data["model"] = seat
data["advisorModel"] = "opus"
tmp = path + ".tmp-claude-inferhub"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(json.dumps(data, indent=2) + "\n")
os.replace(tmp, path)
print("synced model picker in", path)
PY
}

clear_claude_env() {
  # Clear Anthropic / OAuth / CKFF tokens so claude cannot inherit another
  # BASE_URL or key. Claude prefers ANTHROPIC_AUTH_TOKEN over ANTHROPIC_API_KEY.
  local n
  for n in ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_MODEL \
           ANTHROPIC_SMALL_FAST_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
           ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_API_KEY_HELPER_TTL_MS \
           CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS CKFF_KIMI_KEY CKFF_API_KEY CKFF_DEFAULT_KEY \
           ckff_access_token ckff_api_url ckff_alternate_api_url ckff_nonstream_api_url \
           ckff_cortex_kimi_token_ ckff_cortex_kimi_token_model ckff_cortex_embedder_rerank; do
    unset "$n"
  done
  for n in $(env | awk -F= '/^(ANTHROPIC_|CLAUDE_CODE_|CKFF_|ckff_)[A-Za-z0-9_]*=/ {print $1}'); do
    unset "$n"
  done
}

# ---- main -------------------------------------------------------------------
main() {
  log "=== Launch Claude InferHub (macOS) $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
  need_curl
  ensure_workbench
  ensure_uv
  ensure_venv
  ensure_claude
  ensure_keys
  IH_URL="$(inferhub_url)"
  fetch_ire
  ensure_top20
  ensure_proxy

  pick_folder
  rm -f "$LADDER_STATE"
  pick_main
  pick_ladder main "$MAIN_ID"
  pick_advisor
  pick_ladder advisor "$ADVISOR_ID"

  apply_seat
  # After apply_seat: its merge step reloads the stock chains, so the picked
  # ladders go on top of that.
  apply_ladder
  sync_model_picker

  local master
  # Keyless proxy: claude still needs some key, so "local" unless a real
  # LITELLM_MASTER_KEY is set.
  master="$(secret LITELLM_MASTER_KEY)" || master="local"

  clear_claude_env
  # InferHub through the local LiteLLM for this claude only. The key is the
  # optional LiteLLM master key or "local", never a CKFF key. Do NOT set ANTHROPIC_AUTH_TOKEN.
  # Experimental betas stay ON (CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS unset).
  export ANTHROPIC_API_KEY="$master"
  export ANTHROPIC_BASE_URL="$PROXY_BASE"
  export ANTHROPIC_MODEL="$SEAT_ALIAS"
  export ANTHROPIC_SMALL_FAST_MODEL="$SMALL_FAST_MODEL"
  master=""

  cd "$PROJECT_DIR" || die "cannot cd to $PROJECT_DIR"
  log ""
  log "cwd=$PROJECT_DIR"
  log "proxy=$ANTHROPIC_BASE_URL  (unified CKFF+InferHub LiteLLM)"
  log "small_fast=$ANTHROPIC_SMALL_FAST_MODEL  (InferHub cheap side model for search/hooks)"
  log "seat_alias=$SEAT_ALIAS  behavesAs=claude-sonnet-5"
  log "main=$MAIN_ID  ($MAIN_NAME)"
  if [ -n "$ADVISOR_ID" ]; then log "advisor=$ADVISOR_NAME ($ADVISOR_ID)"; else log "advisor=OFF"; fi
  log "permission=bypassPermissions (auto mode is Anthropic-only)"
  log "betas=experimental ON (advisor_20260301 via LiteLLM orchestration)"
  log "Starting Claude Code..."
  exec claude --model "$SEAT_ALIAS" --permission-mode bypassPermissions
}

main "$@"
