#!/bin/bash
# =============================================================================
# Launch Claude InferHub (macOS)
# Source of truth: Pukujan/claude-code-launcher mac/ (see SOURCES.md).
# Ported from ACS inferhub-litellm-macos v0.1.0 (agent-custom-setup PR #65).
# Mac counterpart of windows/launch-claude-inferhub.ps1.
#
# This is the one Mac launcher. It also has the parts of the old macos/ shim
# (PR #7): mac/setup.sh installs everything plus a `claude-acs` command, the
# folder picker has terminal navigation (mac/lib/nav.sh), and the model table
# comes live from IRE through shared/ire/ire_fetch.py.
#
# Double-click in Finder, or run `claude-acs` after mac/setup.sh. First run
# installs what is missing (no sudo): uv, a uv-managed Python, the venv with
# pinned LiteLLM under shared/litellm/.litellm-venv, and Claude Code. Then it
# asks once for the InferHub key, fetches the IRE picks (live, else the last
# good copy, else built-in), starts LiteLLM on 127.0.0.1:4000 from this
# repository's shared/litellm folder, shows the folder picker and the model
# picker, seats the models and runs claude. Later runs skip what is installed.
#
# CLAUDE_IH_SETUP_ONLY=1 stops after the installs and the IRE fetch (setup.sh
# uses this). CLAUDE_IH_PROJECT, CLAUDE_IH_MAIN and CLAUDE_IH_ADVISOR skip the
# pickers; the macos/ names ACS_FOLDER, ACS_MAIN_ID and ACS_ADVISOR_ID still work.
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
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LITELLM_DIR="$REPO_ROOT/shared/litellm"
IH_ENV_FILE="${INFERHUB_ENV_FILE:-$HOME/.config/inferhub/.env}"
HEALTH_TIMEOUT="${LITELLM_HEALTH_TIMEOUT:-300}"
PY_VERSION="${CLAUDE_IH_PYTHON:-3.12}"
NODE_MAJOR="${CLAUDE_IH_NODE_MAJOR:-24}"
UV_INSTALLER_URL="${UV_INSTALLER_URL:-https://astral.sh/uv/install.sh}"
CLAUDE_INSTALLER_URL="${CLAUDE_INSTALLER_URL:-https://claude.ai/install.sh}"

DEFAULT_MODEL_ID="cb/deepseek-v4.1-flash"
SEAT_ALIAS="sonnet"
# Claude Code's auto-compact window: GPT 6 Astra (the opus slot's first model) has 272K.
AUTO_COMPACT_WINDOW="272000"
# Claude Code stops every ripgrep run (Grep, Glob) after CLAUDE_CODE_GLOB_TIMEOUT_SECONDS,
# 20 by default; big folders can take longer, so sessions get 120 unless the user set
# their own positive whole number (issue #69).
GLOB_TIMEOUT_DEFAULT="120"

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
# The slot helpers (issue #91) only need the standard library, plus PyYAML for
# the fallback chains (slots.py falls back to its built-in chains without it).
# The launcher's venv is built before the pickers run, but the helpers also work
# when the launcher is sourced on its own (the unit tests), so fall back to a
# system python3 when the venv is not there yet.
SLOTS_PY="$VENV_PY"
[ -x "$SLOTS_PY" ] || SLOTS_PY="$(command -v python3 2>/dev/null || printf 'python3')"

# Pinned in shared/litellm/requirements.txt and requirements-overrides.txt,
# the same files Windows installs from. The overrides pin fastapi/starlette/
# sse-starlette below what LiteLLM declares, which uv does with --override.
# Change either file and the venv refreshes itself on the next run.
REQ_FILE="$LITELLM_DIR/requirements.txt"
OVR_FILE="$LITELLM_DIR/requirements-overrides.txt"
REQUIREMENTS="$(cat "$REQ_FILE" 2>/dev/null)"
OVERRIDES="$(cat "$OVR_FILE" 2>/dev/null)"

# HOOK(ire-models): the built-in picker table, rank|name|id|eligible|in|out
# and, when the list has a speed, |tps. load_ire_table replaces it with the
# live IRE Top 20 when shared/ire answers.
# This copy is the last resort; it matches shared/litellm/config/top20-builtin.csv,
# the Windows table and shared/ire/defaults.json (tests check all of them).
# The two prices are the best route's cheapest listed asks per 1M tokens.
MODELS='1|DeepSeek V4.1 Flash|cb/deepseek-v4.1-flash|false|0.00015|0.0006
2|MiniMax M3|mm/MiniMax-M3|true|0.0003|0.0012
3|GLM 5.3 Flash|zai/glm-5.3-flash|true|0.00015|0.0005
4|DeepSeek V4 Flash|cbcn/deepseek-v4-flash|false|0.00352|0.01056
5|Qwen3.8 Flash|alicn/qwen3.8-flash|true|0.00015|0.00047
6|GPT 5.6 Luna|cx/gpt-5.6-luna|false|0.0032|0.0192
7|Kimi K2.7 Code|cbcn/kimi-k2.7|true|0.0152|0.064
8|DeepSeek V4 Pro|cbcn/deepseek-v4-pro|false|0.01056|0.03168
9|Qwen3.8 Max 0902|ali/qwen3.8-max-0902|false|0.01|0.03
10|GLM 5.3|alicn/glm-5.3|true|0.0014|0.0044
11|Gemini 3.8 Flash|ag/gemini-3.8-flash-high|false|0.00075|0.00375
12|Gemini 3.7 Flash|ag/gemini-3.7-flash-high|false|0.00075|0.00375
13|MiniMax M2.7|mm/MiniMax-M2.7|false|0.0003|0.0012
14|Gemini 3.6 Flash|ag/gemini-3.6-flash-high|false|0.00075|0.00375
15|MiMo V2.5|cmc/xiaomi/mimo-v2.5|false|0.02086|0.04172
16|Kimi K2.6|cbcn/kimi-k2.6|false|0.0152|0.064
17|GLM 5.2|alicn/glm-5.2|false|0.0014|0.0044
18|GPT 6 Luna|cx/gpt-6-luna|false|0.0016|0.008
19|Qwen3.8 Omni Flash|alicn/qwen3.8-omni-flash|false|0.00015|0.00047
20|MiniMax M2.5|mm/MiniMax-M2.5|false|0.0003|0.0012'

MODEL_COUNT="$(printf '%s\n' "$MODELS" | grep -c '|')"

# Old macos/ shim variable names, kept so existing scripts keep working.
[ -z "${CLAUDE_IH_PROJECT:-}" ] && [ -n "${ACS_FOLDER:-}" ] && CLAUDE_IH_PROJECT="$ACS_FOLDER"
[ -z "${CLAUDE_IH_MAIN:-}" ] && [ -n "${ACS_MAIN_ID:-}" ] && CLAUDE_IH_MAIN="$ACS_MAIN_ID"
[ -z "${CLAUDE_IH_ADVISOR+set}" ] && [ -n "${ACS_ADVISOR_ID+set}" ] && CLAUDE_IH_ADVISOR="$ACS_ADVISOR_ID"

# Terminal folder navigation (browse, quick picks, recents, new folder).
# shellcheck source=SCRIPTDIR/lib/nav.sh
. "$REPO_ROOT/mac/lib/nav.sh"

# Env names handed to the LiteLLM process (values never logged). No CKFF keys:
# CKFF is off since 2026-10-04 (shared/litellm/config/providers.yaml).
PROXY_ENV_NAMES="INFERHUB_API_KEY INFERHUB_API_URL LITELLM_MASTER_KEY"

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
     && "$VENV_PY" -c "import litellm, yaml, ddgs" >/dev/null 2>&1; then
    return 0
  fi
  log "Installing pinned LiteLLM into $VENV ..."
  req="$STATE_DIR/requirements.txt"
  mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
  printf '%s\n' "$REQUIREMENTS" > "$req"
  printf '%s\n' "$OVERRIDES" > "$req.overrides"
  quiet uv pip install --python "$VENV_PY" -r "$req" --override "$req.overrides" \
    || die "LiteLLM install failed (details in the log). Check your network and run again."
  "$VENV_PY" -c "import litellm, yaml, ddgs" >/dev/null 2>&1 || die "LiteLLM installed but does not import"
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
  # HOOK(ire): shared/ire/ire_fetch.py pulls IRE's Top 20, price policy, any
  # fallback picks and the optional frontier list from GitHub (5 s budget, auth
  # from GH_TOKEN/GITHUB_TOKEN or `gh auth token`; IRE is private), then falls
  # back to the last good copy and then built-in defaults. Never fatal.
  # Writes:
  #   $STATE_DIR/ire.json           the bundle for the ladder picker (CCL_IRE_JSON);
  #                                 its "frontier" key is empty if IRE has none
  #   $STATE_DIR/ire-table.txt      rank|name|id|eligible|in|out|tps for the picker
  #   shared/litellm/config/top20.csv  the Top 20 for sync_inferhub_top20.py
  local py line
  IRE_JSON="$STATE_DIR/ire.json"
  IRE_TABLE="$STATE_DIR/ire-table.txt"
  py="$VENV_PY"; [ -x "$py" ] || py="$(command -v python3 || true)"
  if [ -z "$py" ] || ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    log "IRE: no Python or state folder; using the built-in model table"
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] && log "IRE: ${line#\[ire\] }"
  done < <("$py" "$REPO_ROOT/shared/ire/ire_fetch.py" --out "$IRE_JSON" \
             --table-out "$IRE_TABLE" \
             --top20-csv "$LITELLM_DIR/config/top20.csv" 2>&1 >/dev/null)
  if [ -f "$HOME/.config/inferhub/model-provider-preferences.json" ]; then
    if ! "$py" "$REPO_ROOT/shared/ire/apply_provider_preferences.py" \
        --bundle "$IRE_JSON" --table "$IRE_TABLE" \
        --top20-csv "$LITELLM_DIR/config/top20.csv" \
        --preferences "$HOME/.config/inferhub/model-provider-preferences.json" \
        >> "$LOG_FILE" 2>&1; then
      log "IRE: local provider preferences could not be applied; using IRE's current routes"
    fi
  fi
  # Lab roster, when present, replaces the fetched lists. A failure keeps them.
  if [ -f "$HOME/.config/inferhub/lab-roster.json" ]; then
    if line="$("$py" "$REPO_ROOT/shared/ire/apply_lab_roster.py" \
        --roster "$HOME/.config/inferhub/lab-roster.json" \
        --bundle "$IRE_JSON" --table "$IRE_TABLE" \
        --top20-csv "$LITELLM_DIR/config/top20.csv" 2>&1 >/dev/null)"; then
      [ -n "$line" ] && log "IRE: ${line#\[ire\] }"
    else
      [ -n "$line" ] && printf '%s\n' "$line" >> "$LOG_FILE"
      log "IRE: the lab roster could not be applied; keeping the fetched lists"
    fi
  fi
  [ -f "$IRE_JSON" ] && export CCL_IRE_JSON="$IRE_JSON"
  load_ire_table
  return 0
}

# Use the table ire_fetch.py wrote, if every line looks right. Otherwise keep
# the built-in MODELS.
load_ire_table() {
  local table n
  [ -n "${IRE_TABLE:-}" ] && [ -s "$IRE_TABLE" ] || return 0
  table="$(cat "$IRE_TABLE")"
  n="$(printf '%s\n' "$table" | grep -c '|')"
  # Field 7, tokens per second, is optional. A table from before speed was
  # shown still loads. A non-numeric speed is rejected with the rest of a bad line.
  if [ "$n" -lt 1 ] || printf '%s\n' "$table" \
      | grep -vqE '^[0-9]+\|[^|]+\|[a-z0-9]+(/[A-Za-z0-9._-]+)+\|(true|false)\|[0-9.]*\|[0-9.]*(\|[0-9.]*)?$'; then
    log "IRE: the fetched model table looks wrong; using the built-in one"
    return 0
  fi
  MODELS="$table"
  MODEL_COUNT="$n"
}

ensure_top20() {
  local out="$LITELLM_DIR/config/inferhub_top20.yaml" csv stamp sum
  stamp="$LITELLM_DIR/config/.inferhub_top20.source"
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
      printf 'recommendation_rank,model_family,recommendation_eligible,best_route_min_ask_in_usdc_per_1m,best_route_min_ask_out_usdc_per_1m,model_ids\n'
      printf '%s\n' "$MODELS" | awk -F'|' '{printf "%s,%s,%s,%s,%s,%s\n", $1, $2, $4, $5, $6, $3}'
    } > "$csv"
  fi
  # Regenerate only when the source CSV or the API base changed.
  sum="$(cksum < "$csv" 2>/dev/null) $IH_URL"
  if [ -f "$out" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$sum" ]; then
    return 0
  fi
  log "Writing InferHub Top 20 deployments from $(basename "$csv") ..."
  quiet "$VENV_PY" "$LITELLM_DIR/scripts/sync_inferhub_top20.py" --csv "$csv" --api-base "$IH_URL" \
    || die "sync_inferhub_top20.py failed (see log)"
  printf '%s\n' "$sum" > "$stamp" 2>/dev/null
}

# The seat script, with the proxy env (an optional LITELLM_MASTER_KEY decides
# whether runtime.yaml gets a master_key at all).
seat_script() {
  ( export_proxy_env; "$VENV_PY" "$LITELLM_DIR/scripts/apply_inferhub_seat.py" "$@" )
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
    quiet seat_script --api-base "$IH_URL" --no-reload \
      || die "apply_inferhub_seat.py failed (see log)"
  else
    quiet seat_script --api-base "$IH_URL" \
      --main "$DEFAULT_MODEL_ID" --advisor "" --no-reload \
      || die "apply_inferhub_seat.py failed (see log)"
  fi
  mkdir -p "$logs" || die "cannot create $logs"
  log "Starting LiteLLM on $PROXY_BASE (background; logs in $logs) ..."
  (
    cd "$LITELLM_DIR" || exit 1
    # CKFF is off: nothing CKFF inherited from the shell reaches the proxy.
    for n in $(env | awk -F= 'tolower($1) ~ /^ckff[a-z0-9_]*$/ {print $1}'); do unset "$n"; done
    export_proxy_env
    export PYTHONUTF8=1 LITELLM_LOCAL_MODEL_COST_MAP=True
    # Keyless on 127.0.0.1: LiteLLM 1.104+ refuses to start without a master
    # key unless this is set. The pinned 1.103.0 doesn't need it. It is set in
    # this subshell only, so only the proxy process sees it.
    if [ -z "${LITELLM_MASTER_KEY:-}" ]; then
      export LITELLM_DANGEROUSLY_PERMIT_WEAK_OR_UNSET_MASTER_KEY=true
    fi
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
model_field() {  # model_field INDEX(1-based) FIELD(1-7; 7 is tok/s when present)
  printf '%s\n' "$MODELS" | awk -F'|' -v i="$1" -v f="$2" 'NR == i {print $f}'
}

print_models() {  # print_models with_off
  local rank name id elig cost cout tps judge tag star over speed over_bit
  if [ "$1" = "1" ]; then
    printf '   0  OFF  (disable advisor tool / seat aliases fall back to main)\n' >&2
  fi
  while IFS='|' read -r rank name id elig cost cout tps; do
    if [ "$elig" = "true" ]; then tag="eligible"; else tag="gated"; fi
    star=" "
    if [ "$1" != "1" ] && [ "$id" = "$DEFAULT_MODEL_ID" ]; then star="*"; fi
    # The $0.10 cap is judged on the output ask when the table carries one.
    judge="$cout"; [ -n "$judge" ] || judge="$cost"
    over=""; awk -v c="$judge" 'BEGIN { exit !(c + 0 >= 0.10) }' && over="OVER \$0.10"
    speed=""; [ -n "$tps" ] && speed="  ${tps} tok/s"
    over_bit=""; [ -n "$over" ] && over_bit=" $over"
    if [ -n "$cout" ]; then
      printf '%s%3d  %-28s %-42s %-8s  ~%s in/%s out per 1M%s%s\n' \
        "$star" "$rank" "$name" "$id" "$tag" "$cost" "$cout" "$speed" "$over_bit" >&2
    else
      printf '%s%3d  %-28s %-42s %-8s  ~%s/1M%s%s\n' \
        "$star" "$rank" "$name" "$id" "$tag" "$cost" "$speed" "$over_bit" >&2
    fi
  done <<EOF
$MODELS
EOF
}

resolve_model() {  # resolve_model "<number or id>" -> index, or fail
  local want="$1" i=1 id
  case "$want" in
    ''|*[!0-9]*) ;;
    *) if [ "$want" -ge 1 ] && [ "$want" -le "$MODEL_COUNT" ]; then printf '%s' "$want"; return 0; fi; return 1 ;;
  esac
  while [ "$i" -le "$MODEL_COUNT" ]; do
    id="$(model_field "$i" 3)"
    [ "$id" = "$want" ] && { printf '%s' "$i"; return 0; }
    i=$((i + 1))
  done
  return 1
}

pick_main() {
  local idx
  if [ -n "${CLAUDE_IH_MAIN:-}" ]; then
    idx="$(resolve_model "$CLAUDE_IH_MAIN")" || die "CLAUDE_IH_MAIN=$CLAUDE_IH_MAIN is not in the model table"
    MAIN_ID="$(model_field "$idx" 3)"; MAIN_NAME="$(model_field "$idx" 2)"; return 0
  fi
  while :; do
    log ""
    log "Choose MAIN model (IRE Top 20). Default DeepSeek V4.1 Flash."
    log "MAIN executor (maps to alias sonnet/main). gated = ranked but not currently recommendation-eligible."
    print_models 0
    ask "Main model number [Enter = 1, f = frontier order, u = utility, q = quit]: " || die "Cancelled."
    REPLY="$(trim "$REPLY")"
    case "$REPLY" in
      q|Q) die "Cancelled." ;;
      '') REPLY=1 ;;
      f|F) pick_frontier main frontier && return 0; continue ;;
      u|U) pick_frontier main utility && return 0; continue ;;
    esac
    if idx="$(resolve_model "$REPLY")"; then
      MAIN_ID="$(model_field "$idx" 3)"; MAIN_NAME="$(model_field "$idx" 2)"; return 0
    fi
    log "Please type a number from 1 to $MODEL_COUNT."
  done
}

pick_advisor() {
  local idx
  if [ -n "${CLAUDE_IH_ADVISOR+set}" ]; then
    case "$CLAUDE_IH_ADVISOR" in ''|0|off|OFF) ADVISOR_ID=""; ADVISOR_NAME=""; return 0 ;; esac
    idx="$(resolve_model "$CLAUDE_IH_ADVISOR")" || die "CLAUDE_IH_ADVISOR=$CLAUDE_IH_ADVISOR is not in the model table"
    ADVISOR_ID="$(model_field "$idx" 3)"; ADVISOR_NAME="$(model_field "$idx" 2)"; return 0
  fi
  while :; do
    log ""
    log "Choose ADVISOR model (IRE Top 20) or OFF."
    log "ADVISOR maps to alias opus/advisor. Mid-session use /advisor opus or /advisor sonnet (aliases), not raw InferHub ids."
    print_models 1
    ask "Advisor number [Enter = 0 OFF, f = frontier order, u = utility, q = quit]: " || die "Cancelled."
    REPLY="$(trim "$REPLY")"
    case "$REPLY" in
      q|Q) die "Cancelled." ;;
      f|F) pick_frontier advisor frontier && return 0; continue ;;
      u|U) pick_frontier advisor utility && return 0; continue ;;
      ''|0|off|OFF) ADVISOR_ID=""; ADVISOR_NAME=""; return 0 ;;
    esac
    if idx="$(resolve_model "$REPLY")"; then
      ADVISOR_ID="$(model_field "$idx" 3)"; ADVISOR_NAME="$(model_field "$idx" 2)"; return 0
    fi
    log "Please type 0 for OFF or a number from 1 to $MODEL_COUNT."
  done
}

confirm_folder() {
  ask "Launch Claude Code in $1 ? [Y/n]: " || die "Cancelled."
  case "$(trim "$REPLY")" in n|N|no|NO|No) return 1 ;; esac
  return 0
}

# Folder picker. Numbered so it works from a pipe (the dry run) and in a
# terminal alike; b, q, t and n add the terminal navigation from the old
# macos/ shim (mac/lib/nav.sh). No Finder dialog.
#   1..      the default root, its subfolders, then recent folders
#   b        browse the filesystem with the arrow keys (needs a terminal)
#   q        quick picks: home, Desktop, Documents, code folders
#   t        type a path (~ is expanded)
#   n        make a new folder
#   q! / x   quit
pick_folder() {
  local dirs d n i chosen recents quick name parent
  if [ -n "${CLAUDE_IH_PROJECT:-}" ]; then
    [ -d "$CLAUDE_IH_PROJECT" ] || die "CLAUDE_IH_PROJECT=$CLAUDE_IH_PROJECT is not a folder"
    PROJECT_DIR="$(cd "$CLAUDE_IH_PROJECT" && pwd)"; return 0
  fi
  mkdir -p "$WORK_ROOT" 2>/dev/null
  while :; do
    # Default root first (the root itself), then its non-hidden subfolders,
    # then recent folders that aren't already listed.
    dirs="$WORK_ROOT"
    for d in "$WORK_ROOT"/*/; do
      [ -d "$d" ] || continue
      d="${d%/}"
      dirs="$dirs
$d"
    done
    recents=""
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      case "
$dirs
" in *"
$d
"*) continue ;; esac
      recents="$recents$d
"
    done < <(nav_recents_list)
    log ""
    log "Choose a project folder (default root $WORK_ROOT)"
    n=0
    while IFS= read -r d; do
      n=$((n + 1))
      if [ "$n" -eq 1 ]; then
        printf '%4d  %s  (default root)\n' "$n" "$(nav_tilde "$d")" >&2
      else
        printf '%4d  %s\n' "$n" "$(nav_tilde "$d")" >&2
      fi
    done <<EOF
$dirs
EOF
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      n=$((n + 1))
      printf '%4d  %s  (recent)\n' "$n" "$(nav_tilde "$d")" >&2
      dirs="$dirs
$d"
    done <<EOF
$recents
EOF
    printf '   b  Browse folders in this terminal\n' >&2
    printf '   q  Quick picks (home, Desktop, Documents, code folders)\n' >&2
    printf '   t  Type a path\n' >&2
    printf '   n  New folder\n' >&2
    ask "Folder [Enter = 1, b/q/t/n, x = quit]: " || die "Cancelled."
    REPLY="$(trim "$REPLY")"
    chosen=""
    case "$REPLY" in
      x|X|q!|Q!) die "Cancelled." ;;
      b|B)
        chosen="$(nav_browse "$WORK_ROOT")" || { log "No folder chosen."; continue; } ;;
      q|Q)
        quick="$(nav_quick_list)"
        i=0
        while IFS= read -r d; do
          [ -n "$d" ] || continue
          i=$((i + 1)); printf '%4d  %s\n' "$i" "$(nav_tilde "$d")" >&2
        done <<EOF
$quick
EOF
        ask "Quick pick number [Enter = back]: " || die "Cancelled."
        REPLY="$(trim "$REPLY")"
        case "$REPLY" in ''|*[!0-9]*) continue ;; esac
        chosen="$(printf '%s\n' "$quick" | sed -n "${REPLY}p")"
        [ -n "$chosen" ] || { log "No quick pick number $REPLY."; continue; } ;;
      t|T)
        ask "Folder path: " || die "Cancelled."
        chosen="$(trim "$REPLY")"
        chosen="$(nav_expand "$chosen")"
        [ -n "$chosen" ] || continue ;;
      n|N)
        ask "Make it inside [Enter = $(nav_tilde "$WORK_ROOT")]: " || die "Cancelled."
        parent="$(trim "$REPLY")"
        [ -n "$parent" ] || parent="$WORK_ROOT"
        parent="$(nav_expand "$parent")"
        ask "New folder name: " || die "Cancelled."
        name="$(trim "$REPLY")"
        chosen="$(nav_make_folder "$parent" "$name")" || { log "Could not make that folder."; continue; } ;;
      '') chosen="$WORK_ROOT" ;;
      *[!0-9]*) log "Please type a number, b, q, t, n or x."; continue ;;
      *) chosen="$(printf '%s\n' "$dirs" | sed -n "${REPLY}p")"
         [ -n "$chosen" ] || { log "No folder number $REPLY."; continue; } ;;
    esac
    [ -d "$chosen" ] || { log "Not a folder: $chosen"; continue; }
    if confirm_folder "$chosen"; then
      PROJECT_DIR="$(cd "$chosen" && pwd)"
      nav_remember "$PROJECT_DIR"
      return 0
    fi
  done
}

# ---- launch with: Claude Code or UltraCode -------------------------------------
# Comes right after the folder pick. Up/Down, Enter launches, Left goes back to
# the folder pick (returns 1). The choice is kept in last-picks.json. With no
# terminal (scripts, the dry run) or CLAUDE_IH_LAUNCH set there is no picker.
LAST_PICKS="$STATE_DIR/last-picks.json"

pick_launch() {
  local idx=0 key
  LAUNCH="${CLAUDE_IH_LAUNCH:-}"
  if [ -n "$LAUNCH" ] || [ ! -t 0 ] || ! _have_tty; then LAUNCH="${LAUNCH:-claude}"; return 0; fi
  grep -q '"launch": *"ultracode"' "$LAST_PICKS" 2>/dev/null && idx=1
  PICKER_LINES=("Claude Code" "UltraCode (pick an orchestrator and a worker after the models)")
  while :; do
    show_picker 2 "$idx" "Launch with" "Up/Down move. Enter launches. Left = back to the folder. Esc quits."
    key="$(read_menu_key)"
    case "$key" in
      UP|DOWN) idx="$(move_index "$idx" 2 "$key" 1)" ;;
      ENTER|RIGHT) break ;;
      LEFT) return 1 ;;
      ESC) die "Cancelled." ;;
    esac
  done
  if [ "$idx" -eq 1 ]; then LAUNCH=ultracode; else LAUNCH=claude; fi
  save_last_picks
}

# OnlyTerp/UltraCode-Shim (MIT, standard-library Python) runs Claude Code with
# two models: the ORCHESTRATOR (the main loop) and the WORKER (every parallel
# sub-agent and background call). Fetched on demand at a pinned commit into a
# per-user cache (never vendored here) and run from there with its own
# bin/ultracode. The global `ultracode` command is never installed or changed.
# shared/ultracode/uc_models.py writes the cache's config.json (the InferHub
# seats, UltraCode's own usable options without CKFF, and the IRE Top 20, all
# through LiteLLM) and preselects the orchestrator/worker pick.
UC_COMMIT="1870e58e2622c8946c9c7cd45483aa47d7bd5867"
UC_DIR="$HOME/.cache/claude-code-launcher/ultracode-shim"
# The shim keeps its selection.json here (bin/ultracode's state folder).
UC_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ultracode-shim"
# The shim's own proxy port: 4241 + the LiteLLM port (8241 for 4000). Not the
# shim's default 8141, so a standalone ultracode on that port is never reused.
UC_PORT=$((LITELLM_PORT + 4241))

ensure_ultracode() {
  [ -f "$UC_DIR/proxy.py" ] && [ "$(cat "$UC_DIR/.commit" 2>/dev/null)" = "$UC_COMMIT" ] && return 0
  log "Fetching UltraCode-Shim ${UC_COMMIT:0:7} ..."
  local tmp
  tmp="$(mktemp -d)" || die "mktemp failed"
  curl -fsSL "https://github.com/OnlyTerp/UltraCode-Shim/archive/$UC_COMMIT.tar.gz" | tar -xz -C "$tmp" \
    || { rm -rf "$tmp"; die "could not fetch UltraCode-Shim"; }
  rm -rf "$UC_DIR"
  mkdir -p "$(dirname "$UC_DIR")"
  mv "$tmp/UltraCode-Shim-$UC_COMMIT" "$UC_DIR" && printf '%s\n' "$UC_COMMIT" > "$UC_DIR/.commit"
  rm -rf "$tmp"
}

# shared/ultracode/uc_models.py with uv (stdlib only, no project).
uc_models() {
  uv run --no-project python "$REPO_ROOT/shared/ultracode/uc_models.py" "$@"
}

# last_pick KEY: a value from last-picks.json ("" when missing). A saved CKFF
# model (any id with "ckff"; CKFF is off since 2026-10-04) reads as "", so the
# step falls back to its default. InferHub's cb/gpt-6-astra is not CKFF.
last_pick() {
  sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" "$LAST_PICKS" 2>/dev/null | head -1 \
    | grep -viE 'ckff' || true
}

# Writes last-picks.json: the launch target and the UltraCode picks (kept from
# last time when this run didn't make them).
save_last_picks() {
  local orch="${UC_ORCH-$(last_pick uc_orch)}" worker="${UC_WORKER-$(last_pick uc_worker)}"
  mkdir -p "$STATE_DIR" || return 1
  # The whole document is rewritten, so the slot chains pick_slots saved survive
  # a launch-target change (issue #91).
  slots_file launch "$LAUNCH" "$orch" "$worker" || return 1
}

# Writes the cache's config.json and the choices (id<TAB>label) to UC_LIST.
uc_build_choices() {
  local top
  ensure_ultracode
  top="$(mktemp)" || die "mktemp failed"
  printf '%s\n' "$MODELS" > "$top"
  mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
  UC_LIST="$STATE_DIR/ultracode-choices.tsv"
  uc_models build --example "$UC_DIR/config.example.json" --top20 "$top" --proxy-base "$PROXY_BASE" \
    --port "$UC_PORT" --main-name "${MAIN_NAME:-}" --advisor-name "${ADVISOR_NAME:-}" \
    --config-out "$UC_DIR/config.json" --list-out "$UC_LIST" 2>> "$LOG_FILE" \
    || { rm -f "$top"; die "uc_models.py build failed; see $LOG_FILE"; }
  rm -f "$top"
}

uc_listed() {  # uc_listed ID: is ID one of the choices?
  cut -f1 "$UC_LIST" | grep -qxF "$1"
}

# uc_pick orch|worker: one arrow-key list. Sets UC_PICK ("" = same as the
# orchestrator). Returns 1 for Left.
uc_pick() {
  local slot="$1" idx=0 key i id label want title tab
  tab="$(printf '\t')"
  UC_IDS=(); PICKER_LINES=()
  if [ "$slot" = "worker" ]; then
    UC_IDS[0]=""; PICKER_LINES[0]="Same as orchestrator"
    if [ -n "${UC_WORKER+set}" ]; then want="$UC_WORKER"; else want="$(last_pick uc_worker)"; fi
    title="UltraCode WORKER (runs every parallel sub-agent and background call)"
  else
    want="${UC_ORCH:-$(last_pick uc_orch)}"; want="${want:-claude-ih-main}"
    title="UltraCode ORCHESTRATOR (runs the main loop)"
  fi
  while IFS="$tab" read -r id label; do
    [ -n "$id" ] || continue
    i=${#UC_IDS[@]}
    UC_IDS[i]="$id"; PICKER_LINES[i]="$label"
  done < "$UC_LIST"
  i=0
  while [ "$i" -lt "${#UC_IDS[@]}" ]; do
    [ "${UC_IDS[$i]}" = "$want" ] && { idx=$i; break; }
    i=$((i + 1))
  done
  while :; do
    show_picker "${#UC_IDS[@]}" "$idx" "$title" \
      "Up/Down move. Enter picks. Left = back. Esc quits." \
      "Orchestrator = the main loop, worker = every parallel sub-agent. All through the local LiteLLM; CKFF is never offered."
    key="$(read_menu_key)"
    case "$key" in
      UP|DOWN|PGUP|PGDN|HOME|END) idx="$(move_index "$idx" "${#UC_IDS[@]}" "$key" 10)" ;;
      ENTER|RIGHT) break ;;
      LEFT) return 1 ;;
      ESC) die "Cancelled." ;;
    esac
  done
  UC_PICK="${UC_IDS[$idx]}"
}

# After "launch with" = UltraCode: pick the orchestrator and the worker. With
# no terminal, or CLAUDE_IH_UC_ORCH set, use CLAUDE_IH_UC_ORCH /
# CLAUDE_IH_UC_WORKER, else last time's picks, else the main seat for both.
pick_ultracode() {
  uc_build_choices
  if [ -n "${CLAUDE_IH_UC_ORCH:-}" ] || [ ! -t 0 ] || ! _have_tty; then
    UC_ORCH="${CLAUDE_IH_UC_ORCH:-$(last_pick uc_orch)}"
    UC_ORCH="${UC_ORCH:-claude-ih-main}"
    if [ -n "${CLAUDE_IH_UC_WORKER+set}" ]; then UC_WORKER="$CLAUDE_IH_UC_WORKER"; else UC_WORKER="$(last_pick uc_worker)"; fi
    uc_listed "$UC_ORCH" || die "UltraCode orchestrator $UC_ORCH is not one of the choices (see $UC_LIST)"
    [ -z "$UC_WORKER" ] || uc_listed "$UC_WORKER" || die "UltraCode worker $UC_WORKER is not one of the choices (see $UC_LIST)"
  else
    while :; do
      uc_pick orch || continue   # nothing before this step to go back to
      UC_ORCH="$UC_PICK"
      if uc_pick worker; then UC_WORKER="$UC_PICK"; break; fi
    done
  fi
  save_last_picks
}

# Preselects the pick (POST /uc/select when a shim with this config already
# runs, else the shim's selection.json, read when its proxy starts), then runs
# the cache's own bin/ultracode in the chosen folder with the shim's picker off
# and --model <orchestrator>. The shim starts, reuses and stops its own proxy;
# its upstream is the local LiteLLM, so nothing goes to api.anthropic.com.
run_ultracode() {
  local port
  port="$(uc_models preselect --config "$UC_DIR/config.json" --state-file "$UC_STATE_DIR/selection.json" \
    --orch "$UC_ORCH" --worker "${UC_WORKER:-}" 2>> "$LOG_FILE")" || die "uc_models.py preselect failed; see $LOG_FILE"
  unset UC_LISTEN_PORT UC_UPSTREAM   # config.json decides both
  export UC_SELECTOR=0               # our pickers replace the shim's own
  log "ultracode=$UC_DIR/bin/ultracode (shim http://127.0.0.1:$port -> $PROXY_BASE)"
  log "orchestrator=$UC_ORCH worker=${UC_WORKER:-(same as orchestrator)}"
  log "Starting UltraCode..."
  exec "$UC_DIR/bin/ultracode" --model "$UC_ORCH" --permission-mode bypassPermissions
}

# ---- per-slot model picks (issue #91) ----------------------------------------
# Windows opens with a "model slots" step (windows/launch-claude-inferhub.ps1).
# The shared body never had one, so on Mac and Linux the opus (planning) and
# haiku (background) chains, and every slot's fallbacks, could not be set at all:
# apply_seat() only ever passed --main and --advisor, which are the FIRST model of
# sonnet and fable. This is the same step for both platforms: pick each of the
# four [CC] slots' first model and up to two fallbacks with the arrow keys, save
# the chains in last-picks.json under "slots" (the shape Windows writes), and
# hand all four to apply_inferhub_seat.py --slot.
SLOTS_ORDER="sonnet opus fable haiku"
SLOT_CHAINS=()
SLOTS_PICKED=""
SLOT_CATALOG=""
SLOT_LIST="top20"

slot_num() {
  case "$1" in
    sonnet) printf '0' ;;
    opus)   printf '1' ;;
    fable)  printf '2' ;;
    haiku)  printf '3' ;;
  esac
}

slot_chain() { printf '%s' "${SLOT_CHAINS[$(slot_num "$1")]:-}"; }

slot_chain_text() {
  local c
  c="$(slot_chain "$1")"
  if [ -n "$c" ]; then printf '%s' "$(printf '%s' "$c" | tr ' ' '-')"; else printf '(none)'; fi
}

slot_title() {
  case "$1" in
    sonnet) printf 'sonnet (main conversation)' ;;
    opus)   printf 'opus (planning)' ;;
    fable)  printf 'fable (advisor)' ;;
    haiku)  printf 'haiku (background)' ;;
  esac
}

# slot_arg SLOT -> "name=id1,id2,id3" for apply_inferhub_seat.py --slot.
slot_arg() { printf '%s=%s' "$1" "$(slot_chain "$1" | tr ' ' ',')"; }

# slot_name_of ID -> the catalog's display name, else the id itself.
slot_name_of() {
  local id="$1" tab x name rest
  tab="$(printf '\t')"
  while IFS="$tab" read -r x name rest; do
    [ "$x" = "$id" ] && { printf '%s' "$name"; return 0; }
  done <<EOF
$SLOT_CATALOG
EOF
  printf '%s' "$id"
}

# chain_at CHAIN RUNG -> the RUNG-th id (1-based), empty when the chain is shorter.
chain_at() {
  local c="$1" r="$2" i=1 x
  for x in $c; do
    [ "$i" = "$r" ] && { printf '%s' "$x"; return 0; }
    i=$((i + 1))
  done
  printf ''
}

# chain_set CHAIN RUNG ID -> the new chain. An empty ID drops that rung and
# everything after it, which is the "none (no further fallback)" choice. A real
# pick keeps the rungs below it (deduped, at most 3), the same as the Windows
# step, so changing the first model does not silently discard the fallbacks.
chain_set() {
  local c="$1" r="$2" id="$3" i=1 out="" x
  for x in $c; do
    if [ "$i" -lt "$r" ]; then
      out="$out $x"
    elif [ "$i" = "$r" ]; then
      [ -n "$id" ] && out="$out $id"
    elif [ -n "$id" ]; then
      out="$out $x"
    fi
    i=$((i + 1))
  done
  if [ "$r" -ge "$i" ] && [ -n "$id" ]; then out="$out $id"; fi
  printf '%s' "$(printf '%s' "$out" | tr ' ' '\n' | awk 'NF && !seen[$0]++' \
    | head -3 | tr '\n' ' ' | sed 's/^ *//; s/ *$//')"
}

# The pickable routes as TSV, read once per launch: id, name, rank, eligible,
# price_in, price_out, list, tps. ladder_cli.py catalog is the shared source
# (Top 20 plus opted-in extras), so the editor and the ladder picker cannot drift.
slot_catalog_load() {
  SLOT_CATALOG="$("$SLOTS_PY" "$LADDER_CLI" catalog 2>/dev/null | "$SLOTS_PY" -c '
import json, sys
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
def speed(value):
    if value in (None, ""):
        return ""
    try:
        return f"{float(value):.1f}".rstrip("0").rstrip(".")
    except (TypeError, ValueError):
        return ""

for r in rows:
    print("\t".join([
        str(r.get("id", "")), str(r.get("name", "")), str(r.get("rank", "")),
        "1" if r.get("eligible") else "0",
        str(r.get("price_in", "")), str(r.get("price_out", "")),
        str(r.get("list", "")),
        speed(r.get("tps")),
    ]))
' 2>/dev/null)"
}

# One rung of one slot: an arrow-key list. Sets SLOT_CHOICE to the chosen id
# ("" = none, "@sonnet" = haiku follows sonnet). Returns 1 when Left is pressed,
# so the caller can step back.
slot_rung_pick() {
  # slot_rung_pick <slot> <rung> <want> <taken> <allow_same>
  local slot="$1" rung="$2" want="$3" taken="$4" allow_same="$5"
  local idx=0 key i n tab id name rank elig pin pout list tps tag star line speed
  tab="$(printf '\t')"
  SLOT_IDS=(); PICKER_LINES=()
  if [ "$allow_same" = "1" ]; then
    SLOT_IDS[0]="@sonnet"
    PICKER_LINES[0]="   same chain as sonnet: $(slot_chain_text sonnet)"
  fi
  while IFS="$tab" read -r id name rank elig pin pout list tps; do
    [ -n "$id" ] || continue
    [ "$list" = "$SLOT_LIST" ] || continue
    case " $taken " in *" $id "*) continue ;; esac
    if [ "$elig" = "1" ]; then tag="eligible"; else tag="gated"; fi
    star=" "
    [ "$id" = "$want" ] && star="*"
    speed=""; [ -n "$tps" ] && speed="  ${tps} tok/s"
    n=${#SLOT_IDS[@]}
    SLOT_IDS[n]="$id"
    PICKER_LINES[n]="$(printf '%s%3s  %-28s %-42s %-8s  ~%s in/%s out per 1M%s' \
      "$star" "$rank" "$name" "$id" "$tag" "$pin" "$pout" "$speed")"
  done <<EOF
$SLOT_CATALOG
EOF
  if [ "$rung" -gt 1 ]; then
    n=${#SLOT_IDS[@]}
    SLOT_IDS[n]=""; PICKER_LINES[n]="   none (no further fallback)"
  fi
  i=0
  while [ "$i" -lt "${#SLOT_IDS[@]}" ]; do
    [ "${SLOT_IDS[$i]}" = "$want" ] && { idx=$i; break; }
    i=$((i + 1))
  done
  while :; do
    case "$rung" in
      1) line="first model" ;;
      2) line="2nd model (fallback 1) after $(chain_at "$(slot_chain "$slot")" 1)" ;;
      *) line="3rd model (fallback 2) after $(chain_at "$(slot_chain "$slot")" 2)" ;;
    esac
    show_picker "${#SLOT_IDS[@]}" "$idx" "Slot $(slot_title "$slot"): $line   now: $(slot_chain_text "$slot")" \
      "Up/Down move. Enter picks. Left = back a step. t = Top 20, f = frontier, u = pictures. Esc quits." \
      "Prices are per 1M tokens. Speed, when shown, is tok/s. gated = ranked but not currently recommendation-eligible. list: $SLOT_LIST"
    key="$(read_menu_key)"
    case "$key" in
      UP|DOWN|PGUP|PGDN|HOME|END) idx="$(move_index "$idx" "${#SLOT_IDS[@]}" "$key" 10)" ;;
      ENTER|RIGHT) break ;;
      LEFT) return 1 ;;
      t) SLOT_LIST="top20"; return 2 ;;
      f) SLOT_LIST="frontier"; return 2 ;;
      u) SLOT_LIST="utility"; return 2 ;;
      ESC) die "Cancelled." ;;
    esac
  done
  SLOT_CHOICE="${SLOT_IDS[$idx]}"
}

# The four chains, saved. last-picks.json also holds launch and the UltraCode
# picks, so read/modify/write the whole document instead of replacing it.
slots_file() {  # slots_file load | save <haiku_same> <sonnet> <opus> <fable> <haiku>
  "$SLOTS_PY" - "$LAST_PICKS" "$@" <<'PY'
import json, os, sys

path, mode = sys.argv[1], sys.argv[2]


def load():
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        return doc if isinstance(doc, dict) else {}
    except Exception:
        return {}


doc = load()

if mode == "load":
    slots = doc.get("slots") or {}
    if not slots:
        raise SystemExit(1)
    same = bool(slots.get("haiku_same"))
    for name in ("sonnet", "opus", "fable", "haiku"):
        chain = [str(x) for x in (slots.get(name) or []) if x]
        if name == "haiku" and same:
            chain = [str(x) for x in (slots.get("sonnet") or []) if x]
        print(name + "\t" + " ".join(chain))
elif mode == "save":
    doc.setdefault("version", 2)
    slots = {}
    for i, name in enumerate(("sonnet", "opus", "fable", "haiku")):
        slots[name] = [x for x in sys.argv[4 + i].split() if x]
    slots["haiku_same"] = sys.argv[3] == "1"
    doc["slots"] = slots
elif mode == "launch":
    doc.setdefault("version", 2)
    doc["launch"] = sys.argv[3]
    doc["uc_orch"] = sys.argv[4]
    doc["uc_worker"] = sys.argv[5]

os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(doc, indent=2) + "\n")
os.replace(tmp, path)
PY
}

# Fill SLOT_CHAINS from last-picks.json. Returns 1 when nothing is saved yet.
slots_saved_load() {
  local out slot chain
  out="$(slots_file load 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  while IFS="$(printf '\t')" read -r slot chain; do
    [ -n "$slot" ] && SLOT_CHAINS[$(slot_num "$slot")]="$chain"
  done <<EOF
$out
EOF
  return 0
}

# Fill SLOT_CHAINS from the resolver (seat file first, then the yaml defaults),
# so the editor opens on what the proxy is actually using.
slots_default_load() {
  local out slot chain
  out="$("$SLOTS_PY" - "$LITELLM_DIR/scripts" "$LITELLM_DIR/config/inferhub_seat.json" \
    "$LITELLM_DIR/config/inferhub_fallbacks.yaml" <<'PY' 2>/dev/null
import json, sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
import slots

seat = {}
try:
    with open(sys.argv[2], encoding="utf-8-sig") as fh:
        seat = json.load(fh)
except Exception:
    seat = {}
chains = slots.resolve_slots(seat, None, Path(sys.argv[3]))
for name in slots.SLOTS:
    print(name + "\t" + " ".join(chains[name]))
PY
)" || return 1
  [ -n "$out" ] || return 1
  while IFS="$(printf '\t')" read -r slot chain; do
    [ -n "$slot" ] && SLOT_CHAINS[$(slot_num "$slot")]="$chain"
  done <<EOF
$out
EOF
  return 0
}

slot_summary_lines() {
  local slot
  for slot in $SLOTS_ORDER; do
    printf '      %-7s %s\n' "$slot" "$(slot_chain_text "$slot")"
  done
}

# The slots step. Interactive only: with no terminal, CLAUDE_IH_SLOTS=off, or
# CLAUDE_IH_MAIN set (scripts, the dry run), it changes nothing and apply_seat
# keeps its --main/--advisor behaviour.
pick_slots() {
  local slot idx=0 key i step total saved=0 haiku_same=0 want taken entry rung allow rc line STEPS
  SLOTS_PICKED=""
  if slots_saved_load; then
    saved=1
  else
    slots_default_load
  fi
  # haiku follows sonnet only when the chains actually match and are non-empty.
  haiku_same=0
  if [ -n "$(slot_chain haiku)" ] && [ "$(slot_chain haiku)" = "$(slot_chain sonnet)" ]; then
    haiku_same=1
  fi
  if [ "${CLAUDE_IH_SLOTS:-}" = "off" ] || [ -n "${CLAUDE_IH_MAIN:-}" ] \
     || [ ! -t 0 ] || ! _have_tty; then
    return 0
  fi
  slot_catalog_load
  # Step 1: keep the saved chains or change them.
  if [ "$saved" = "1" ]; then
    PICKER_LINES=("Use the saved slots")
    while IFS= read -r line; do PICKER_LINES[${#PICKER_LINES[@]}]="$line"; done <<EOF
$(slot_summary_lines)
EOF
    PICKER_LINES[${#PICKER_LINES[@]}]="Change the slots"
    while :; do
      show_picker "${#PICKER_LINES[@]}" "$idx" \
        "Step 1: model slots (sonnet = main, opus = planning, fable = advisor, haiku = background)" \
        "Up/Down move. Enter picks. Esc quits." \
        "The saved slots are used by every launch, Paseo included. Change them here any time."
      key="$(read_menu_key)"
      case "$key" in
        UP|DOWN|PGUP|PGDN|HOME|END) idx="$(move_index "$idx" "${#PICKER_LINES[@]}" "$key" 10)" ;;
        ENTER|RIGHT) break ;;
        ESC) die "Cancelled." ;;
      esac
    done
    if [ "$idx" -eq 0 ]; then
      SLOTS_PICKED=1
      log "Slots (saved): $(slot_chain_text sonnet) | $(slot_chain_text opus) | $(slot_chain_text fable) | $(slot_chain_text haiku)"
      return 0
    fi
  fi
  # Walk the twelve rungs: four slots, each a first model and two fallbacks.
  STEPS=()
  for slot in $SLOTS_ORDER; do
    for i in 1 2 3; do STEPS[${#STEPS[@]}]="$slot:$i"; done
  done
  total=${#STEPS[@]}
  step=0
  while [ "$step" -lt "$total" ]; do
    entry="${STEPS[$step]}"
    slot="${entry%%:*}"
    rung="${entry##*:}"
    want="$(chain_at "$(slot_chain "$slot")" "$rung")"
    taken=""
    i=1
    while [ "$i" -lt "$rung" ]; do
      taken="$taken $(chain_at "$(slot_chain "$slot")" "$i")"
      i=$((i + 1))
    done
    allow=0
    [ "$slot" = "haiku" ] && [ "$rung" = "1" ] && allow=1
    rc=0
    slot_rung_pick "$slot" "$rung" "$want" "$taken" "$allow" || rc=$?
    if [ "$rc" = "1" ]; then
      # Left: back a rung, or stay on the first one.
      [ "$step" -gt 0 ] && step=$((step - 1))
      continue
    fi
    # rc 2 is a list toggle (t / f): redraw this rung.
    [ "$rc" = "2" ] && continue
    if [ "$SLOT_CHOICE" = "@sonnet" ]; then
      haiku_same=1
      SLOT_CHAINS[$(slot_num haiku)]="$(slot_chain sonnet)"
      step=$total
      continue
    fi
    [ "$slot" = "haiku" ] && [ "$rung" = "1" ] && haiku_same=0
    SLOT_CHAINS[$(slot_num "$slot")]="$(chain_set "$(slot_chain "$slot")" "$rung" "$SLOT_CHOICE")"
    step=$((step + 1))
  done
  slots_file save "$haiku_same" "$(slot_chain sonnet)" "$(slot_chain opus)" \
    "$(slot_chain fable)" "$(slot_chain haiku)" || log "warning: could not save the slots"
  SLOTS_PICKED=1
  log "Slots: sonnet=$(slot_chain_text sonnet) opus=$(slot_chain_text opus) fable=$(slot_chain_text fable) haiku=$(slot_chain_text haiku)"
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

# Off by default since issue #53: every slot's chain is generated into runtime.yaml
# (apply_inferhub_seat.py), and a ladder would replace it. CLAUDE_IH_LADDER=ask or
# =default brings the old per-seat ladders back.
pick_ladder() {
  local role="$1" primary="$2" mode="${CLAUDE_IH_LADDER:-off}"
  [ "$mode" = "off" ] && return 0
  local extra=()
  if [ "$mode" = "default" ] || [ ! -t 0 ]; then extra=(--non-interactive); fi
  "$VENV_PY" "$LADDER_CLI" choose --state "$LADDER_STATE" --role "$role" --primary "$primary" ${extra[@]+"${extra[@]}"} \
    || log "warning: ladder picker failed for $role; the stock chains stay"
}

# Seat primary from one IRE list (frontier by default, or utility) via the
# shared picker; sets MAIN_ID/MAIN_NAME or ADVISOR_ID/ADVISOR_NAME.
pick_frontier() {
  # pick_frontier <role> [frontier|utility|top20]
  local role="$1" list="${2:-frontier}" out="$STATE_DIR/primary-pick.txt" id name off=()
  [ "$role" = "advisor" ] && off=(--allow-off)
  rm -f "$out"
  "$VENV_PY" "$LADDER_CLI" primary --role "$role" --list "$list" --out "$out" ${off[@]+"${off[@]}"} || return 1
  IFS="$(printf '\t')" read -r id name < "$out" || return 1
  if [ "$role" = "main" ]; then MAIN_ID="$id"; MAIN_NAME="$name"; else ADVISOR_ID="$id"; ADVISOR_NAME="$name"; fi
}

apply_ladder() {
  [ "${CLAUDE_IH_LADDER:-off}" = "off" ] && return 0
  [ -f "$LADDER_STATE" ] || return 0
  if "$VENV_PY" "$LADDER_CLI" apply --state "$LADDER_STATE" --base-url "$PROXY_BASE" >> "$LOG_FILE" 2>&1; then
    log "Fallback ladders applied to the running proxy."
  else
    log "warning: could not apply the fallback ladders (see log); the stock chains stay"
  fi
}

# ---- seat + Claude settings ---------------------------------------------------
apply_seat() {
  local args
  if [ "$SLOTS_PICKED" = "1" ]; then
    # The slots step (issue #91) set all four chains, so hand them over whole.
    # --slot replaces --main/--advisor, which can only reach a slot's first model.
    log "Slots: sonnet=$(slot_chain_text sonnet) opus=$(slot_chain_text opus) fable=$(slot_chain_text fable) haiku=$(slot_chain_text haiku)"
    args=(--slot "$(slot_arg sonnet)" --slot "$(slot_arg opus)" \
          --slot "$(slot_arg fable)" --slot "$(slot_arg haiku)")
  else
    # --main / --advisor set the first model of the sonnet and fable slots; the rest of
    # each chain, and the opus and haiku slots, come from the saved or default chains.
    log "Slots: sonnet first=$MAIN_ID fable first=${ADVISOR_ID:-default} through LiteLLM ..."
    args=(--main "$MAIN_ID" --advisor "$ADVISOR_ID")
  fi
  (
    export_proxy_env
    export LITELLM_BASE_URL="$PROXY_BASE"
    "$VENV_PY" "$LITELLM_DIR/scripts/apply_inferhub_seat.py" --api-base "$IH_URL" \
      "${args[@]}" --base-url "$PROXY_BASE"
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
    {"model": seat, "label": "Sonnet slot (main)", "description": "Main chat chain via local LiteLLM",
     "behavesAs": "claude-sonnet-5"},
    {"model": "opus", "label": "Opus slot (planning)", "description": "Planning chain via local LiteLLM",
     "behavesAs": "claude-opus-5-5"},
    {"model": "fable", "label": "Fable slot (advisor)", "description": "Advisor chain via local LiteLLM",
     "behavesAs": "claude-fable-5"},
    {"model": "haiku", "label": "Haiku slot (background)", "description": "Background chain via local LiteLLM",
     "behavesAs": "claude-haiku-4-5-20251001"},
]
for row in os.environ["MODELS_TABLE"].splitlines():
    fields = row.split("|")
    if len(fields) < 4:
        continue
    rank, name, mid, elig = fields[:4]
    provider = mid.split("/", 1)[0]
    description = ("IRE Top 20 #" + rank + "; " + ("eligible" if elig == "true" else "gated")
                   + " - direct, no slot chain")
    if len(fields) >= 7 and fields[6].strip():
        description += f"; {fields[6].strip()} tok/s"
    options.append({
        "model": "ih/" + mid,
        "label": f"{name} — {provider} (IRE Top 20 #{rank})",
        "description": description,
        "behavesAs": "claude-sonnet-5",
    })
ire_path = os.environ.get("CCL_IRE_JSON")
if ire_path and os.path.isfile(ire_path):
    try:
        with open(ire_path, encoding="utf-8") as f:
            ire = json.load(f)
        lab = bool(ire.get("lab_roster"))
        seen = set()
        if lab:
            for opt in options:
                model = str(opt.get("model") or "")
                if model.startswith("ih/"):
                    seen.add(model[3:])

        def direct_rows(rows, label):
            for row in rows:
                mid = str(row.get("route") or "")
                if "/" not in mid:
                    continue
                if lab and mid in seen:
                    continue
                rank = int(row["rank"])
                name = str(row.get("name") or mid)
                eligible = bool(row.get("eligible"))
                provider = mid.split("/", 1)[0]
                description = (f"IRE {label} #{rank}; "
                                + ("eligible" if eligible else "gated")
                                + " - direct, no slot chain")
                speed = row.get("tps")
                if speed not in (None, ""):
                    try:
                        text = f"{float(speed):.1f}".rstrip("0").rstrip(".")
                        description += f"; {text} tok/s"
                    except (TypeError, ValueError):
                        pass
                options.append({
                    "model": "ih/" + mid,
                    "label": f"{name} — {provider} (IRE {label} #{rank})",
                    "description": description,
                    "behavesAs": "claude-sonnet-5",
                })
                if lab:
                    seen.add(mid)

        frontier = [r for r in ire.get("frontier", [])
                    if isinstance(r, dict) and r.get("best_route")
                    and str(r.get("rank", "")).isdigit()
                    and (lab or int(r["rank"]) <= 20)]
        frontier.sort(key=lambda r: (int(r["rank"]), str(r.get("route", ""))))
        direct_rows(frontier, "Frontier")
        if lab:
            utility = [r for r in ire.get("utility", [])
                       if isinstance(r, dict) and r.get("route")
                       and str(r.get("rank", "")).isdigit()]
            utility.sort(key=lambda r: (int(r["rank"]), str(r.get("route", ""))))
            direct_rows(utility, "Utility")
    except (OSError, ValueError, TypeError):
        pass
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data["modelPicker"] = {"options": options}
data["model"] = seat
data["advisorModel"] = "fable"  # the advisor is the fable slot
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
           ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_API_KEY_HELPER_TTL_MS \
           CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS CKFF_KIMI_KEY CKFF_API_KEY CKFF_DEFAULT_KEY \
           ckff_access_token ckff_api_url ckff_alternate_api_url ckff_nonstream_api_url \
           ckff_cortex_kimi_token_ ckff_cortex_kimi_token_model ckff_cortex_embedder_rerank; do
    unset "$n"
  done
  for n in $(env | awk -F= '/^(ANTHROPIC_|CLAUDE_CODE_|CKFF_|ckff_)[A-Za-z0-9_]*=/ {print $1}'); do
    unset "$n"
  done
}

claude_ai_logged_in() {
  # True when claude is signed in with a claude.ai account (/login). Call it
  # after clear_claude_env, so a key in the environment cannot mask the login.
  local st
  st="$(claude auth status --json 2>/dev/null)" || return 1
  printf '%s' "$st" | grep -q '"loggedIn": *true' &&
    printf '%s' "$st" | grep -q '"authMethod": *"claude\.ai"'
}

# set_claude_env MASTER: clears the inherited Anthropic/CKFF variables and
# exports the ones claude needs for the local LiteLLM. Sets AUTH_LINE. Used by
# main and by the non-interactive mode.
set_claude_env() {
  local master="$1"
  # Read before clear_claude_env sweeps CLAUDE_CODE_* away (issue #69).
  local glob_timeout="${CLAUDE_CODE_GLOB_TIMEOUT_SECONDS:-}"
  glob_timeout="${glob_timeout#"${glob_timeout%%[![:space:]]*}"}"
  glob_timeout="${glob_timeout%"${glob_timeout##*[![:space:]]}"}"
  case "$glob_timeout" in
    ''|*[!0-9]*|0*) glob_timeout="$GLOB_TIMEOUT_DEFAULT" ;;
  esac
  if [ "${#glob_timeout}" -gt 6 ]; then glob_timeout="$GLOB_TIMEOUT_DEFAULT"; fi
  clear_claude_env
  # InferHub through the local LiteLLM for this claude only. The key is the
  # optional LiteLLM master key or "local", never a CKFF key. Do NOT set ANTHROPIC_AUTH_TOKEN.
  # Experimental betas stay ON (CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS unset).
  export ANTHROPIC_BASE_URL="$PROXY_BASE"
  # Any key (ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN or apiKeyHelper) outranks the
  # claude.ai login, and Artifacts refuse to run without that login. So with a
  # keyless proxy and a claude.ai login, set no key: model traffic still goes to
  # ANTHROPIC_BASE_URL and the login rides along as the bearer the proxy ignores.
  if [ "$master" = "local" ] && claude_ai_logged_in; then
    AUTH_LINE="auth=claude.ai login (no API key, so Artifacts work)"
  else
    export ANTHROPIC_API_KEY="$master"
    if [ "$master" = "local" ]; then
      AUTH_LINE="auth=dummy API key (run /login with your claude.ai account to use Artifacts)"
    else
      AUTH_LINE="auth=LiteLLM master key (Artifacts need a keyless proxy)"
    fi
  fi
  export ANTHROPIC_MODEL="$SEAT_ALIAS"   # sonnet: the main chat (never opusplan)
  # Pin every slot to a Claude-style name the proxy serves (shared/litellm/scripts/slots.py
  # maps each to its chain). The deprecated ANTHROPIC_SMALL_FAST_MODEL is not set:
  # background calls use the haiku pin.
  export ANTHROPIC_DEFAULT_SONNET_MODEL="claude-sonnet-5"            # sonnet slot (main)
  export ANTHROPIC_DEFAULT_OPUS_MODEL="claude-opus-5-5"              # opus slot (planning)
  export ANTHROPIC_DEFAULT_FABLE_MODEL="claude-fable-5"              # fable slot (the advisor)
  export ANTHROPIC_DEFAULT_HAIKU_MODEL="claude-haiku-4-5-20251001"   # haiku slot (an id Claude Code knows)
  export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$AUTO_COMPACT_WINDOW"      # GPT 6 Astra's 272K window
  export CLAUDE_CODE_WORKFLOWS=1
  export CLAUDE_CODE_GLOB_TIMEOUT_SECONDS="$glob_timeout"             # ripgrep time limit (issue #69)
}

# install_planner [install|uninstall]: the planner sub-agent (~/.claude/agents/planner.md,
# model opus, read-only) and the CLAUDE.md line that hands planning to it. Idempotent,
# never fatal; CCL_PLANNER=off skips the install.
install_planner() {
  local action="${1:-install}" py="${VENV_PY:-}"
  [ "$action" = "install" ] && [ "${CCL_PLANNER:-}" = "off" ] && return 0
  [ -n "$py" ] && [ -x "$py" ] || py="$(command -v python3 2>/dev/null)" || true
  [ -n "$py" ] || { printf 'planner: no Python found; planner sub-agent not changed\n' >&2; return 0; }
  "$py" "$REPO_ROOT/shared/claude/install_planner.py" "$action" --quiet >&2 || true
}

# ---- non-interactive mode (see README "Non-interactive mode") ---------------
# For tools that start Claude Code themselves (Paseo, scripts). No pickers, no
# installs, no prompts, and the proxy is never started, restarted or reloaded:
# the seat the running proxy already has stays. Turn it on with
# --non-interactive or CCL_NONINTERACTIVE=1. Then --print-env json|dotenv (or
# CCL_PRINT_ENV) prints the variables and exits; otherwise claude runs with the
# remaining arguments. --folder DIR runs it there. Launcher options come first;
# "--" ends them. Exit codes: 2 bad option, 3 proxy not healthy.
parse_launcher_args() {
  CCL_NI=""; CCL_PRINT=""; CCL_FOLDER=""; CCL_REST=()
  [ "${CCL_NONINTERACTIVE:-}" = "1" ] && CCL_NI=1
  if [ -n "${CCL_PRINT_ENV:-}" ]; then CCL_NI=1; CCL_PRINT="$CCL_PRINT_ENV"; fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --non-interactive|-NonInteractive) CCL_NI=1; shift ;;
      --print-env|-PrintEnv)
        [ $# -ge 2 ] || { printf 'launch-claude-inferhub: %s needs json or dotenv\n' "$1" >&2; return 2; }
        CCL_NI=1; CCL_PRINT="$2"; shift 2 ;;
      --folder|-Folder)
        [ $# -ge 2 ] || { printf 'launch-claude-inferhub: %s needs a folder\n' "$1" >&2; return 2; }
        CCL_FOLDER="$2"; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  CCL_REST=("$@")
  case "$CCL_PRINT" in
    ''|json|dotenv) ;;
    *) printf "launch-claude-inferhub: print format must be json or dotenv, not '%s'\n" "$CCL_PRINT" >&2; return 2 ;;
  esac
  return 0
}

json_str() {  # json_str VALUE -> a JSON string literal
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# The variables set_claude_env left in this shell (it cleared every other one).
claude_env_names() {
  env | awk -F= '/^(ANTHROPIC_|CLAUDE_CODE_|CKFF_|ckff_)[A-Za-z0-9_]*=/ {print $1}' | LC_ALL=C sort
}

CLAUDE_ENV_CLEAR_NAMES="ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_API_KEY_HELPER_TTL_MS CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS CKFF_KIMI_KEY CKFF_API_KEY CKFF_DEFAULT_KEY ckff_access_token ckff_api_url ckff_alternate_api_url ckff_nonstream_api_url ckff_cortex_kimi_token_ ckff_cortex_kimi_token_model ckff_cortex_embedder_rerank"
CLAUDE_ENV_SWEEP_PREFIXES="ANTHROPIC_ CLAUDE_CODE_ CKFF_ ckff_"

# print_claude_env FORMAT HEALTHY MAIN ADVISOR SOURCE
print_claude_env() {
  local fmt="$1" healthy="$2" main_id="$3" adv_id="$4" source="$5" n v first
  if [ "$fmt" = "dotenv" ]; then
    printf '# claude-code-launcher non-interactive env. Unset these first: %s\n' "$CLAUDE_ENV_CLEAR_NAMES"
    printf '# and every other name starting with %s\n' "$CLAUDE_ENV_SWEEP_PREFIXES"
    printf '# main=%s\n# advisor=%s\n# seat_source=%s\n# proxy_healthy=%s\n# auth=%s\n' \
      "$main_id" "$adv_id" "$source" "$healthy" "$AUTH_LINE"
    for n in $(claude_env_names); do
      eval "v=\"\${$n}\""
      printf '%s=%s\n' "$n" "$v"
    done
    return 0
  fi
  printf '{"set":{'
  first=1
  for n in $(claude_env_names); do
    eval "v=\"\${$n}\""
    [ -n "$first" ] || printf ','
    first=""
    printf '%s:%s' "$(json_str "$n")" "$(json_str "$v")"
  done
  printf '},"unset":['
  first=1
  for n in $CLAUDE_ENV_CLEAR_NAMES; do
    [ -n "$first" ] || printf ','
    first=""
    json_str "$n"
  done
  printf '],"unset_prefixes":["ANTHROPIC_","CLAUDE_CODE_","CKFF_","ckff_"]'
  printf ',"info":{"main":%s,"advisor":%s,"seat_source":%s,"picks_main":"","picks_advisor":"","proxy_healthy":%s,"auth":%s}}\n' \
    "$(json_str "$main_id")" "$(json_str "$adv_id")" "$(json_str "$source")" "$healthy" "$(json_str "$AUTH_LINE")"
}

run_noninteractive() {
  local healthy=true master seat_file main_id="" adv_id="" source="none"
  if [ -n "${CCL_PROXY_PORT:-}" ]; then
    LITELLM_PORT="$CCL_PROXY_PORT"
    PROXY_BASE="http://127.0.0.1:${LITELLM_PORT}"
  fi
  if ! proxy_healthy; then
    healthy=false
    if [ "${CCL_ALLOW_PROXY_DOWN:-}" != "1" ]; then
      printf 'launch-claude-inferhub: the LiteLLM proxy at %s is not answering. Non-interactive mode never starts it; run the launcher once to start it.\n' "$PROXY_BASE" >&2
      return 3
    fi
  fi
  # The seat the running proxy has (written by the last interactive launch). Read only.
  seat_file="${CCL_SEAT_FILE:-$LITELLM_DIR/config/inferhub_seat.json}"
  if [ -f "$seat_file" ]; then
    source="seat file"
    main_id="$(sed -n 's/.*"main_inferhub_id": *"\([^"]*\)".*/\1/p' "$seat_file" | head -1)"
    adv_id="$(sed -n 's/.*"advisor_inferhub_id": *"\([^"]*\)".*/\1/p' "$seat_file" | head -1)"
  fi
  master="$(secret LITELLM_MASTER_KEY)" || master="local"
  set_claude_env "$master"
  master=""
  [ -n "$CCL_PRINT" ] || install_planner install
  if [ -n "$CCL_PRINT" ]; then
    print_claude_env "$CCL_PRINT" "$healthy" "$main_id" "$adv_id" "$source"
    return 0
  fi
  if [ -n "$CCL_FOLDER" ]; then
    cd "$CCL_FOLDER" || { printf 'launch-claude-inferhub: cannot cd to %s\n' "$CCL_FOLDER" >&2; return 2; }
  fi
  exec claude "${CCL_REST[@]}"
}

# ---- main -------------------------------------------------------------------
main() {
  parse_launcher_args "$@" || exit 2
  if [ "$CCL_NI" = "1" ]; then
    run_noninteractive
    exit $?
  fi
  log "=== Launch Claude InferHub (macOS) $(date '+%Y-%m-%d %H:%M:%S %Z') (bash $BASH_VERSION) ==="
  need_curl
  ensure_workbench
  ensure_uv
  ensure_venv
  ensure_claude
  ensure_keys
  IH_URL="$(inferhub_url)"
  fetch_ire
  ensure_top20
  if [ "${CLAUDE_IH_SETUP_ONLY:-}" = "1" ]; then
    log "Setup finished. The proxy starts on the first launch."
    return 0
  fi
  ensure_proxy

  until pick_folder && pick_launch; do :; done
  rm -f "$LADDER_STATE"
  pick_slots
  if [ "$SLOTS_PICKED" = "1" ]; then
    # The slots step set every chain, sonnet's and fable's first models included,
    # so the per-seat prompts would only re-ask for what was just chosen.
    MAIN_ID="$(chain_at "$(slot_chain sonnet)" 1)"
    MAIN_NAME="$(slot_name_of "$MAIN_ID")"
    ADVISOR_ID="$(chain_at "$(slot_chain fable)" 1)"
    ADVISOR_NAME="$(slot_name_of "$ADVISOR_ID")"
    pick_ladder main "$MAIN_ID"
    pick_ladder advisor "$ADVISOR_ID"
  else
    pick_main
    pick_ladder main "$MAIN_ID"
    pick_advisor
    pick_ladder advisor "$ADVISOR_ID"
  fi
  if [ "$LAUNCH" = "ultracode" ]; then
    pick_ultracode
  fi

  apply_seat
  # After apply_seat: its merge step reloads the stock chains, so the picked
  # ladders go on top of that.
  apply_ladder
  sync_model_picker
  install_planner install

  local master
  # Keyless proxy: claude still needs some key, so "local" unless a real
  # LITELLM_MASTER_KEY is set.
  master="$(secret LITELLM_MASTER_KEY)" || master="local"

  set_claude_env "$master"
  master=""

  cd "$PROJECT_DIR" || die "cannot cd to $PROJECT_DIR"
  log ""
  log "cwd=$PROJECT_DIR"
  log "proxy=$ANTHROPIC_BASE_URL  (local LiteLLM, InferHub only; CKFF off)"
  log "pins=sonnet:claude-sonnet-5 opus:claude-opus-5-5 fable:claude-fable-5 haiku:claude-haiku-4-5-20251001  advisor=fable  auto-compact=$AUTO_COMPACT_WINDOW"
  log "sonnet first=$MAIN_ID  ($MAIN_NAME)"
  if [ -n "$ADVISOR_ID" ]; then log "fable (advisor) first=$ADVISOR_NAME ($ADVISOR_ID)"; else log "fable (advisor)=default chain"; fi
  log "$AUTH_LINE"
  log "permission=bypassPermissions (auto mode is Anthropic-only)"
  log "betas=experimental ON (advisor_20260301 via LiteLLM orchestration)"
  if [ "$LAUNCH" = "ultracode" ]; then
    run_ultracode
  fi
  log "Starting Claude Code..."
  exec claude --model "$SEAT_ALIAS" --permission-mode bypassPermissions
}

# Sourcing this file (the tests do) defines everything and launches nothing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
