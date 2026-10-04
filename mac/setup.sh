#!/bin/bash
# =============================================================================
# One-script installer for the Mac launcher (from the old macos/ shim, PR #7).
#
#   mac/setup.sh              install or repair; safe to run again
#   mac/setup.sh --check      report what's there, change nothing
#   mac/setup.sh --uninstall  remove the claude-acs command and stop the proxy
#                             this checkout started (keeps your key and venv)
#
# Install runs "Launch Claude InferHub.command" in setup-only mode, which puts
# in place whatever is missing (uv, Python, the pinned LiteLLM venv under
# shared/litellm, Claude Code), asks once for the InferHub key and fetches the
# IRE model table. Then it writes ~/.local/bin/claude-acs, a small script that
# runs this checkout's launcher:
#
#   claude-acs                pick a folder and models, then start Claude Code
#   claude-acs ~/some/proj    skip the folder picker
#   claude-acs --check        same as mac/setup.sh --check
#
# Nothing is downloaded from this repository: everything runs from the
# checkout. No sudo. The proxy stays keyless on 127.0.0.1. The key lives in
# ~/.config/inferhub/.env (mode 600) and is never printed.
# Written for the bash 3.2 that ships with macOS.
# =============================================================================
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
LAUNCHER="$HERE/Launch Claude InferHub.command"
LITELLM_DIR="$REPO_ROOT/shared/litellm"
BIN_DIR="${CLAUDE_IH_BIN_DIR:-$HOME/.local/bin}"
SHIM="$BIN_DIR/claude-acs"
IH_ENV_FILE="${INFERHUB_ENV_FILE:-$HOME/.config/inferhub/.env}"
LITELLM_PORT="${LITELLM_PORT:-4000}"

ok()  { printf '  ok  %s\n' "$*"; }
bad() { printf '  !!  %s\n' "$*"; }

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

check() {
  local missing=0 t
  printf 'Mac launcher check (%s)\n' "$REPO_ROOT"
  PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
  for t in curl uv claude python3; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t: $(command -v "$t")"
    else bad "$t: not found"; missing=1; fi
  done
  if [ -x "$LITELLM_DIR/.litellm-venv/bin/litellm" ]; then ok "LiteLLM venv: $LITELLM_DIR/.litellm-venv"
  else bad "LiteLLM venv: not set up yet"; missing=1; fi
  if [ -f "$IH_ENV_FILE" ] && grep -qE '^[[:space:]]*INFERHUB_API_KEY[[:space:]]*=' "$IH_ENV_FILE"; then
    ok "InferHub key: present in $IH_ENV_FILE (value not shown)"
  elif [ -f "$REPO_ROOT/.env" ] && grep -qE '^[[:space:]]*INFERHUB_API_KEY[[:space:]]*=' "$REPO_ROOT/.env"; then
    ok "InferHub key: present in $REPO_ROOT/.env (value not shown)"
  else
    bad "InferHub key: not found (the launcher asks for it once)"; missing=1
  fi
  if curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$LITELLM_PORT/health/liveliness" 2>/dev/null; then
    ok "proxy: healthy on 127.0.0.1:$LITELLM_PORT"
  else
    printf '  --  proxy: not running (the launcher starts it)\n'
  fi
  if [ -x "$SHIM" ] && grep -qF "$LAUNCHER" "$SHIM" 2>/dev/null; then ok "claude-acs: $SHIM"
  elif [ -x "$SHIM" ]; then bad "claude-acs: $SHIM points at another checkout (run setup.sh here to repoint it)"; missing=1
  else bad "claude-acs: not installed"; missing=1; fi
  case ":$PATH:" in *":$BIN_DIR:"*) ;; *) bad "$BIN_DIR is not on PATH in this shell";; esac
  return "$missing"
}

# Single-quote a string for a shell script.
squote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

write_shim() {
  mkdir -p "$BIN_DIR" || { bad "cannot create $BIN_DIR"; return 1; }
  {
    printf '#!/bin/bash\n'
    printf '# Written by %s. Run it again if you move the checkout.\n' "$HERE/setup.sh"
    printf 'LAUNCHER=%s\n' "$(squote "$LAUNCHER")"
    printf 'SETUP=%s\n' "$(squote "$HERE/setup.sh")"
    cat <<'SHIM'
case "${1:-}" in
  --check) exec "${BASH:-/bin/bash}" "$SETUP" --check ;;
  -h|--help) printf 'Usage: claude-acs [project-folder] | --check\n'; exit 0 ;;
esac
if [ -n "${1:-}" ]; then
  [ -d "$1" ] || { printf 'not a folder: %s\n' "$1" >&2; exit 2; }
  CLAUDE_IH_PROJECT="$(cd "$1" && pwd)"
  export CLAUDE_IH_PROJECT
fi
[ -f "$LAUNCHER" ] || { printf 'launcher not found at %s (moved the checkout? run its mac/setup.sh)\n' "$LAUNCHER" >&2; exit 1; }
exec "${BASH:-/bin/bash}" "$LAUNCHER"
SHIM
  } > "$SHIM.tmp"
  if ! { chmod 755 "$SHIM.tmp" && mv "$SHIM.tmp" "$SHIM"; }; then
    rm -f "$SHIM.tmp"; bad "cannot write $SHIM"; return 1
  fi
  ok "claude-acs written to $SHIM"
  # Add ~/.local/bin to PATH for zsh (the macOS default shell) once.
  local rc="$HOME/.zshrc"
  if [ "$BIN_DIR" = "$HOME/.local/bin" ] && ! grep -qs '\.local/bin' "$rc"; then
    # shellcheck disable=SC2016  # $HOME and $PATH are meant to expand in .zshrc
    printf '\n# claude-code-launcher\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
    ok "added ~/.local/bin to PATH in $rc (open a new terminal)"
  fi
}

install() {
  [ "$(uname -s)" = "Darwin" ] || printf 'Note: this installer is for macOS; continuing anyway (%s).\n' "$(uname -s)"
  [ -f "$LAUNCHER" ] || { bad "launcher missing at $LAUNCHER"; return 1; }
  printf 'Setting up the Mac launcher from %s\n' "$REPO_ROOT"
  CLAUDE_IH_SETUP_ONLY=1 "${BASH:-/bin/bash}" "$LAUNCHER" || { bad "setup stopped; see the message above"; return 1; }
  write_shim || return 1
  printf '\nDone. Run: claude-acs   (or double-click mac/Launch Claude InferHub.command)\n'
}

uninstall() {
  if [ -f "$SHIM" ] && grep -qF "$LAUNCHER" "$SHIM" 2>/dev/null; then
    rm -f "$SHIM" && ok "removed $SHIM"
  elif [ -f "$SHIM" ]; then
    bad "$SHIM belongs to another checkout; left alone"
  else
    ok "claude-acs was not installed"
  fi
  "${BASH:-/bin/bash}" "$HERE/stop-litellm.sh" || true
  printf 'Kept: %s and %s/.litellm-venv\n' "$IH_ENV_FILE" "$LITELLM_DIR"
}

case "${1:-}" in
  '') install ;;
  --check) check; exit 0 ;;
  --uninstall) uninstall ;;
  -h|--help) usage ;;
  *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac
