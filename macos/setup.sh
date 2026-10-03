#!/usr/bin/env bash
# =============================================================================
# Claude Code launcher for macOS — one file, whole shim.
#
#   ./setup.sh              install (idempotent; safe to re-run)
#   ./setup.sh --check      report what is present, change nothing
#   ./setup.sh --uninstall  remove the launcher + aliases (keeps your secrets)
#
# Installs: Claude Code, a uv-managed LiteLLM on 127.0.0.1:4000, the InferHub
# seat/proxy scripts, and `claude-acs`. No sudo anywhere.
#
# The model table is NOT hardcoded: it is fetched live from
#   Pukujan/inference-recommendation-engine
# and cached, so a launch works offline too.
#
# NEVER commit the InferHub key. It lives at ~/.config/inferhub/.env (mode 600)
# and is read by path at runtime.
# =============================================================================
set -euo pipefail

VERSION="1.0.0"
REPO_RAW="https://raw.githubusercontent.com/Pukujan/claude-code-launcher/main/macos"

LITELLM_ROOT="${SHIM_LITELLM_ROOT:-$HOME/litellm}"
VENV="$LITELLM_ROOT/.litellm-venv"
BIN_DIR="$HOME/.local/bin"
SECRETS_DIR="${SHIM_SECRETS_DIR:-$HOME/.config/inferhub}"
SECRETS_FILE="$SECRETS_DIR/.env"
STATE_DIR="$HOME/.local/state/claude-acs"
PROXY_PORT="${SHIM_PROXY_PORT:-4000}"
CLAUDE_ROOT="${CLAUDE_ROOT:-$HOME/claude}"

CHECK_ONLY=0
UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --check)     CHECK_ONLY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)   sed -n '2,22p' "$0"; exit 0 ;;
    *) printf 'unknown flag: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

c()  { printf '\033[36m%s\033[0m' "$*"; }
ok() { printf '\033[32m  ok\033[0m %s\n' "$*"; }
bad(){ printf '\033[31m  !!\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "this script installs the macOS shim; see windows/ for Windows"

# ---- 0. report --------------------------------------------------------------
report() {
  printf '%s\n' "Claude Code launcher $VERSION — check"
  local missing=0
  local t
  for t in git curl jq python3 uv; do
    if command -v "$t" >/dev/null 2>&1 || [ -x "/opt/homebrew/bin/$t" ]; then
      ok "$t: $(command -v "$t" 2>/dev/null || echo /opt/homebrew/bin/$t)"
    else
      bad "$t: MISSING"; missing=1
    fi
  done
  # Multi-Node trap: claude must exist in EVERY node prefix the shell might pick.
  local n p
  for n in /opt/homebrew/bin/node /usr/local/bin/node "$HOME"/.nvm/versions/node/*/bin/node; do
    [ -x "$n" ] || continue
    p="$(dirname "$n")"
    if [ -x "$p/claude" ]; then ok "claude in $p ($("$p/claude" --version 2>/dev/null | head -1))"
    else bad "claude MISSING in $p (node $("$n" -v 2>/dev/null))"; missing=1; fi
  done
  [ -x "$VENV/bin/litellm" ] && ok "litellm: $("$VENV/bin/litellm" --version 2>/dev/null | head -1 || echo installed)" \
    || { bad "litellm: not installed"; missing=1; }
  if curl -fsS -m 2 -o /dev/null "http://127.0.0.1:${PROXY_PORT}/health/liveliness" 2>/dev/null; then
    ok "proxy healthy on 127.0.0.1:${PROXY_PORT}"
  else
    bad "proxy not running (claude-acs starts it)"
  fi
  if [ -f "$SECRETS_FILE" ] && grep -qE '^\s*INFERHUB_API_KEY\s*=' "$SECRETS_FILE" 2>/dev/null; then
    ok "InferHub key present ($SECRETS_FILE, mode $(stat -f '%Lp' "$SECRETS_FILE" 2>/dev/null || echo '?'))"
  else
    bad "InferHub key MISSING ($SECRETS_FILE)"; missing=1
  fi
  [ -x "$BIN_DIR/claude-acs" ] && ok "launcher: $BIN_DIR/claude-acs" \
    || { bad "launcher missing: run setup.sh"; missing=1; }
  return $missing
}

if [ "$CHECK_ONLY" -eq 1 ]; then
  report || true
  exit 0
fi

if [ "$UNINSTALL" -eq 1 ]; then
  printf '%s\n' "Removing launcher + LiteLLM. Your key at $SECRETS_FILE is KEPT."
  rm -f "$BIN_DIR/claude-acs" "$BIN_DIR/launch-claude-inferhub.sh"
  if [ -x "$LITELLM_ROOT/stop-litellm.sh" ]; then "$LITELLM_ROOT/stop-litellm.sh" || true; fi
  printf 'Done. Re-run ./setup.sh to reinstall.\n'
  exit 0
fi

# ---- 1. base tools ----------------------------------------------------------
need_brew() {
  command -v "$1" >/dev/null 2>&1 && return 0
  command -v brew >/dev/null 2>&1 || die "Homebrew is required for $1. Install from https://brew.sh then re-run."
  printf '%s\n' "$(c "installing $2 via Homebrew")"
  brew install "$1"
}
printf '%s\n' "$(c "1/6 base tools")"
for pair in "git:git" "curl:curl" "jq:jq" "uv:uv"; do need_brew "${pair%%:*}" "${pair##*:}"; done
git --version >/dev/null 2>&1 || bad "git missing — run 'xcode-select --install' then re-run"

# ---- 2. LiteLLM venv -------------------------------------------------------
printf '%s\n' "$(c "2/6 LiteLLM")"
mkdir -p "$LITELLM_ROOT/config" "$LITELLM_ROOT/scripts" "$LITELLM_ROOT/logs"
if [ ! -x "$VENV/bin/python" ]; then
  uv venv "$VENV" --python 3.12
fi
if [ ! -x "$VENV/bin/litellm" ]; then
  # `python -m litellm` does NOT work: the package has no __main__.
  uv pip install --python "$VENV/bin/python" "litellm[proxy]"
  [ -x "$VENV/bin/litellm" ] || die "litellm console script missing after install"
fi
ok "litellm ready at $VENV"

# ---- 3. Claude Code in every Node prefix -----------------------------------
# A Mac commonly has Homebrew Node AND nvm Node. A global npm install lands in
# exactly ONE of them, so `claude` appears to vanish depending on which Node the
# shell resolves. Install into each prefix and verify each.
printf '%s\n' "$(c "3/6 Claude Code")"
install_claude_all() {
  local -a prefixes=()
  local n
  for n in /opt/homebrew/bin/node /usr/local/bin/node "$HOME"/.nvm/versions/node/*/bin/node; do
    [ -x "$n" ] && prefixes+=("$(dirname "$n")")
  done
  [ ${#prefixes[@]} -gt 0 ] || { bad "no Node found; install Node then re-run"; return 1; }
  local p
  for p in "${prefixes[@]}"; do
    if [ -x "$p/claude" ]; then ok "claude already in $p"; continue; fi
    # An inherited NPM_CONFIG_PREFIX silently redirects the install to the wrong
    # tree even with the target node first on PATH, so clear it here.
    ( unset NPM_CONFIG_PREFIX
      PATH="$p:/usr/bin:/bin:/usr/sbin:/sbin" npm install -g @anthropic-ai/claude-code >/dev/null 2>&1 ) \
      || bad "npm install failed for $p"
  done
  for p in "${prefixes[@]}"; do
    [ -x "$p/claude" ] && ok "verified $p/claude ($("$p/claude" --version 2>/dev/null | head -1))" \
      || bad "claude still missing in $p"
  done
}
install_claude_all || true

# ---- 4. proxy + seat scripts ------------------------------------------------
printf '%s\n' "$(c "4/6 proxy scripts")"
fetch_if_missing() {
  local url="$1" dest="$2"
  if [ -f "$dest" ]; then ok "$(basename "$dest") present"; return 0; fi
  curl -fsSL -m 30 "$url" -o "$dest.tmp" 2>/dev/null \
    && mv "$dest.tmp" "$dest" && chmod +x "$dest" && ok "fetched $(basename "$dest")" \
    || { rm -f "$dest.tmp"; bad "could not fetch $(basename "$dest") (offline?)"; return 1; }
}
fetch_if_missing "$REPO_RAW/start-litellm.sh"  "$LITELLM_ROOT/start-litellm.sh"  || true
fetch_if_missing "$REPO_RAW/stop-litellm.sh"   "$LITELLM_ROOT/stop-litellm.sh"   || true
fetch_if_missing "$REPO_RAW/apply_seat.py"     "$LITELLM_ROOT/scripts/apply_seat.py" || true
chmod +x "$LITELLM_ROOT/start-litellm.sh" "$LITELLM_ROOT/stop-litellm.sh" 2>/dev/null || true

# ---- 5. launcher on PATH ---------------------------------------------------
printf '%s\n' "$(c "5/6 launcher")"
mkdir -p "$BIN_DIR"
fetch_if_missing "$REPO_RAW/launch-claude-inferhub.sh" "$BIN_DIR/launch-claude-inferhub.sh" || true
fetch_if_missing "$REPO_RAW/claude-acs"                "$BIN_DIR/claude-acs" || true
chmod +x "$BIN_DIR/launch-claude-inferhub.sh" "$BIN_DIR/claude-acs" 2>/dev/null || true
if ! grep -qs '.local/bin' "$HOME/.zshrc" 2>/dev/null; then
  printf '\n# claude-code-launcher\nexport PATH="$HOME/.local/bin:$PATH"\n' >>"$HOME/.zshrc"
  ok "added ~/.local/bin to PATH"
fi
mkdir -p "$STATE_DIR" "$CLAUDE_ROOT"; chmod 700 "$STATE_DIR" 2>/dev/null || true

# ---- 6. key + seat ---------------------------------------------------------
printf '%s\n' "$(c "6/6 credentials + first seat")"
read_key_from_file() {
  grep -m1 -E '^[[:space:]]*INFERHUB_API_KEY[[:space:]]*=' "$1" 2>/dev/null \
    | sed -E 's/^[^=]*=[[:space:]]*//; s/^["'"'"']//; s/["'"'"']$//'
}
if [ ! -f "$SECRETS_FILE" ] || ! grep -qE '^\s*INFERHUB_API_KEY\s*=' "$SECRETS_FILE" 2>/dev/null; then
  adopted=""
  for cand in "$HOME/Documents/secrets/.env" "$HOME/.config/acs/inferhub.env" "$HOME/.claude/.env"; do
    [ -f "$cand" ] || continue
    v="$(read_key_from_file "$cand")"
    if [ -n "$v" ]; then adopted="$cand"; break; fi
  done
  if [ -n "$adopted" ]; then
    mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
    { printf '# claude-code-launcher secrets. Mode 600. Never commit.\n'
      grep -E '^\s*INFERHUB_API_KEY\s*=' "$adopted"
    } >"$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    ok "adopted INFERHUB_API_KEY from $adopted (no re-entry needed)"
  else
    printf '%s\n' "$(c "No InferHub key found. Enter it now (hidden input).")"
    printf 'Get one at https://inferhub.dev — a dummy works to test the proxy.\n'
    k=""
    if [ -t 0 ]; then printf 'InferHub API key: '; IFS= read -rs k; printf '\n'
    else printf 'InferHub API key (stdin): ' >&2; IFS= read -r k; fi
    [ -n "$k" ] || die "empty key; cannot continue"
    mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
    printf '# claude-code-launcher secrets. Mode 600. Never commit.\nINFERHUB_API_KEY=%s\n' "$k" >"$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    unset k
    ok "key stored (value never shown)"
  fi
else
  ok "key already present"
fi

if [ -x "$VENV/bin/python" ] && [ -f "$LITELLM_ROOT/scripts/apply_seat.py" ]; then
  "$VENV/bin/python" "$LITELLM_ROOT/scripts/apply_seat.py" \
    --main "${ACS_MAIN_ID:-cb/deepseek-v4.1-flash}" --advisor "${ACS_ADVISOR_ID:-}" >/dev/null \
    && ok "default seat written (main=DeepSeek V4.1 Flash, advisor=OFF)"
fi

# Live model table: fetched from IRE, cached for offline use.
IRE_PROBER="$(dirname "${BASH_SOURCE[0]}")/ire_live_models.py"
if [ -f "$IRE_PROBER" ]; then
  python3 "$IRE_PROBER" >/dev/null 2>&1 \
    && ok "IRE model table refreshed (live from Pukujan/inference-recommendation-engine)" \
    || bad "IRE fetch failed; launcher will use its cached table"
fi

cat <<EOF

$(printf '\033[32m%s\033[0m' "Installed.") Claude Code launcher $VERSION

  launcher   claude-acs              (in $BIN_DIR)
  proxy      http://127.0.0.1:$PROXY_PORT  (starts on demand)
  key        $SECRETS_FILE (mode 600)
  models     live from IRE, cached at $STATE_DIR

Next:
  claude-acs              pick a model and a folder, then launch
  claude-acs ~/some/proj   skip the pickers
  $BIN_DIR/claude-acs --check   verify the install

Open a NEW shell (or 'source ~/.zshrc') so ~/.local/bin is on PATH.
EOF