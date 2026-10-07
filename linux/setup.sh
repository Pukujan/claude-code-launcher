#!/usr/bin/env bash
# =============================================================================
# One-script installer for the Linux launcher.
#
#   linux/setup.sh              install or repair; safe to run again
#   linux/setup.sh --check      report what's there, change nothing
#   linux/setup.sh --uninstall  remove the claude-acs command and stop the proxy
#                               this checkout started (keeps your key and venv)
#
# Install runs "linux/launch-claude-inferhub.sh" in setup-only mode, which puts
# in place whatever is missing (uv, a uv-managed Python, the pinned LiteLLM venv
# under shared/litellm, [CC]), asks once for the InferHub key and fetches the IRE
# model table. Then it writes ~/.local/bin/claude-acs, a small script that runs
# this checkout's launcher:
#
#   claude-acs                pick a folder and models, then start [CC]
#   claude-acs ~/some/proj    skip the folder picker
#   claude-acs --check        same as linux/setup.sh --check
#
# Nothing is downloaded from this repository: everything runs from the checkout.
# No sudo. The proxy stays keyless on 127.0.0.1. The key lives in
# ~/.config/inferhub/.env (mode 600) and is never printed.
#
# Two deliberate differences from mac/setup.sh, because Linux is not macOS:
#   - PATH is added to the rc file of the shell you actually use ($SHELL):
#     ~/.bashrc, ~/.zshrc, or ~/.config/fish/config.fish. The Mac installer
#     always writes ~/.zshrc, which is wrong on a bash or fish box.
#   - A missing prerequisite is reported with the exact install command for your
#     distribution (apt, dnf, pacman, zypper or apk).
# =============================================================================
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
LAUNCHER="$HERE/launch-claude-inferhub.sh"
LITELLM_DIR="$REPO_ROOT/shared/litellm"
BIN_DIR="${CLAUDE_IH_BIN_DIR:-$HOME/.local/bin}"
SHIM="$BIN_DIR/claude-acs"
IH_ENV_FILE="${INFERHUB_ENV_FILE:-$HOME/.config/inferhub/.env}"
LITELLM_PORT="${LITELLM_PORT:-4000}"

ok()  { printf '  ok  %s\n' "$*"; }
bad() { printf '  !!  %s\n' "$*"; }

usage() { sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'; }

# The install command for this distribution, so a missing tool comes with a fix.
pkg_hint() {
  if command -v apt-get >/dev/null 2>&1; then printf 'sudo apt-get install -y %s' "$*"
  elif command -v dnf >/dev/null 2>&1; then printf 'sudo dnf install -y %s' "$*"
  elif command -v pacman >/dev/null 2>&1; then printf 'sudo pacman -S --needed %s' "$*"
  elif command -v zypper >/dev/null 2>&1; then printf 'sudo zypper install -y %s' "$*"
  elif command -v apk >/dev/null 2>&1; then printf 'sudo apk add %s' "$*"
  else printf 'install %s with your package manager' "$*"; fi
}

# The rc file for the shell this user actually logs in with.
rc_file() {
  case "$(basename "${SHELL:-/bin/bash}")" in
    zsh)  printf '%s' "$HOME/.zshrc" ;;
    fish) printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish" ;;
    bash) printf '%s' "$HOME/.bashrc" ;;
    *)    printf '%s' "$HOME/.profile" ;;
  esac
}

check() {
  local missing=0 t rc
  printf 'Linux launcher check (%s)\n' "$REPO_ROOT"
  PATH="$HOME/.local/bin:$PATH"
  for t in curl uv claude python3; do
    if command -v "$t" >/dev/null 2>&1; then
      ok "$t: $(command -v "$t")"
    else
      case "$t" in
        curl)    bad "curl: not found ($(pkg_hint curl))"; missing=1 ;;
        python3) bad "python3: not found ($(pkg_hint python3))"; missing=1 ;;
        uv)      printf '  --  uv: not installed yet (the launcher installs it)\n' ;;
        claude)  printf '  --  [CC]: not installed yet (the launcher installs it)\n' ;;
      esac
    fi
  done
  if [ -x "$LITELLM_DIR/.litellm-venv/bin/litellm" ]; then ok "LiteLLM venv: $LITELLM_DIR/.litellm-venv"
  else printf '  --  LiteLLM venv: not set up yet (the launcher sets it up)\n'; fi
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
  rc="$(rc_file)"
  case ":$PATH:" in *":$BIN_DIR:"*) ;; *) bad "$BIN_DIR is not on PATH in this shell (setup adds it to $rc)";; esac
  return "$missing"
}

# Single-quote a string for a shell script.
squote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

write_shim() {
  local rc
  mkdir -p "$BIN_DIR" || { bad "cannot create $BIN_DIR"; return 1; }
  {
    printf '#!/usr/bin/env bash\n'
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
[ -f "$LAUNCHER" ] || { printf 'launcher not found at %s (moved the checkout? run its linux/setup.sh)\n' "$LAUNCHER" >&2; exit 1; }
exec "${BASH:-/bin/bash}" "$LAUNCHER"
SHIM
  } > "$SHIM.tmp"
  if ! { chmod 755 "$SHIM.tmp" && mv "$SHIM.tmp" "$SHIM"; }; then
    rm -f "$SHIM.tmp"; bad "cannot write $SHIM"; return 1
  fi
  ok "claude-acs written to $SHIM"
  # Add ~/.local/bin to PATH once, in the rc file of the shell in use.
  rc="$(rc_file)"
  if [ "$BIN_DIR" = "$HOME/.local/bin" ] && ! grep -qs '\.local/bin' "$rc" 2>/dev/null; then
    case "$rc" in
      */config.fish)
        mkdir -p "$(dirname "$rc")" 2>/dev/null
        printf '\n# claude-code-launcher\nfish_add_path %s\n' "$BIN_DIR" >> "$rc" ;;
      *)
        # shellcheck disable=SC2016  # $HOME and $PATH are meant to expand in the rc file
        printf '\n# claude-code-launcher\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc" ;;
    esac
    ok "added ~/.local/bin to PATH in $rc (open a new terminal)"
  fi
}

install() {
  if [ "$(uname -s)" != "Linux" ]; then
    bad "this installer is for Linux (this is $(uname -s))"; return 1
  fi
  [ -f "$LAUNCHER" ] || { bad "launcher missing at $LAUNCHER"; return 1; }
  command -v curl >/dev/null 2>&1 || { bad "curl is required first: $(pkg_hint curl)"; return 1; }
  printf 'Setting up the Linux launcher from %s\n' "$REPO_ROOT"
  CLAUDE_IH_SETUP_ONLY=1 "${BASH:-/bin/bash}" "$LAUNCHER" || { bad "setup stopped; see the message above"; return 1; }
  write_shim || return 1
  printf '\nDone. Run: claude-acs   (or %s)\n' "$LAUNCHER"
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
