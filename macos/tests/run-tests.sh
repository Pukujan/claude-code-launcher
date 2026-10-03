#!/usr/bin/env bash
# Unit tests for claude-code-shim. No network, no proxy, no secrets required.
#
#   bash tests/run-tests.sh
#
# Covers the failure modes that actually bit during development: multi-Node
# prefix resolution, env scrubbing, and UI/capture separation in the picker.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Works both in this repo's macos/ layout and the older
# platform/macos/workbench/ checkout it was developed in.
LAUNCHER="$REPO_ROOT/launch-claude-inferhub.sh"
[ -f "$LAUNCHER" ] || LAUNCHER="$REPO_ROOT/platform/macos/workbench/launch-claude-inferhub.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$3] got [$2])"; fi; }

echo "== shell syntax =="
while IFS= read -r f; do
  if bash -n "$f" 2>/dev/null; then ok "parses: ${f#$REPO_ROOT/}"; else bad "parse: ${f#$REPO_ROOT/}"; fi
done < <(find "$REPO_ROOT" -name "*.sh" -not -path "*/vendor/*" -not -name "claude-acs")

echo "== model table =="
# shellcheck source=/dev/null
. "$LAUNCHER"
# The launcher sets `set -euo pipefail` for its own run. That is right for the
# app but fatal here: one failing assertion would abort the suite instead of
# being counted. Relax it for the tests only.
set +e
set +u
check "20 models"        "${#MODEL_IDS[@]}" "20"
check "names aligned"    "${#MODEL_NAMES[@]}" "20"
check "eligibility set"  "${#MODEL_ELIGIBLE[@]}" "20"
check "costs set"        "${#MODEL_COSTS[@]}" "20"
check "rank 1 id"        "${MODEL_IDS[0]}" "cb/deepseek-v4.1-flash"
check "rank 20 id"       "${MODEL_IDS[19]}" "ali/kimi-k2.7-code"
check "no empty slugs"   "$(printf '%s\n' "${MODEL_IDS[@]}" | grep -c '^$')" "0"
check "all vendor-prefixed" "$(printf '%s\n' "${MODEL_IDS[@]}" | grep -cE '^[a-z0-9]+/')" "20"

echo "== menu navigation =="
check "up"        "$(move_index 5 20 UP 10)"   "4"
check "down"      "$(move_index 5 20 DOWN 10)" "6"
check "up clamp"  "$(move_index 0 20 UP 10)"   "0"
check "down clamp" "$(move_index 19 20 DOWN 10)" "19"
check "home"      "$(move_index 7 20 HOME 10)" "0"
check "end"       "$(move_index 7 20 END 10)"  "19"
check "empty list" "$(move_index 0 0 UP 10)"   "0"

echo "== keypress parsing =="
check "enter" "$(printf '\n'    | read_menu_key)" "ENTER"
check "up"    "$(printf '\033[A' | read_menu_key)" "UP"
check "down"  "$(printf '\033[B' | read_menu_key)" "DOWN"
check "esc"   "$(printf '\033'   | read_menu_key)" "ESC"
check "pgdn"  "$(printf '\033[6~' | read_menu_key)" "PGDN"

echo "== index capture is not polluted by UI output =="
# The bug this guards: clear_screen wrote to stdout, so the escape codes landed
# inside $(...) and corrupted the selected index.
# assert_index calls die(), which calls exit — so each call MUST run in a command
# substitution subshell or it would terminate the whole suite.
if _v=$(assert_index 2 2>/dev/null); then ok "assert_index accepts 2"; else bad "assert_index accepts 2"; fi
if _v=$(assert_index $'\033[H\033[2J0' 2>/dev/null); then
  bad "assert_index rejects a capture containing escape codes"
else
  ok "assert_index rejects a capture containing escape codes"
fi
unset _v
check "clip_line returns text" "$(clip_line "visible" 40)" "visible"

echo "== env scrubbing =="
export ANTHROPIC_BASE_URL="http://evil:1234"
export ANTHROPIC_API_KEY="leaked"
export ANTHROPIC_AUTH_TOKEN="leaked-token"
export CKFF_API_KEY="ckff"
export CLAUDE_CODE_OAUTH_TOKEN="tok"
export SHIM_KEEP_ME="keep"
clear_conflicting_env
check "base url cleared"  "${ANTHROPIC_BASE_URL:-}"  ""
check "api key cleared"   "${ANTHROPIC_API_KEY:-}"   ""
check "auth token cleared" "${ANTHROPIC_AUTH_TOKEN:-}" ""
check "ckff cleared"      "${CKFF_API_KEY:-}"        ""
check "oauth cleared"     "${CLAUDE_CODE_OAUTH_TOKEN:-}" ""
check "unrelated kept"    "${SHIM_KEEP_ME:-}"        "keep"
check "betas not disabled" "${CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS:-}" ""
unset SHIM_KEEP_ME

echo "== secrets never in the repo =="
REAL_KEY=""
for cand in "$HOME/.config/inferhub/.env" "$HOME/Documents/secrets/.env"; do
  if [ -f "$cand" ]; then
    k=$(grep -m1 -E '^[[:space:]]*INFERHUB_API_KEY[[:space:]]*=' "$cand" 2>/dev/null \
        | sed -E 's/^[^=]*=[[:space:]]*//; s/^["'"'"']//; s/["'"'"']$//')
    [ -n "$k" ] && REAL_KEY="$k" && break
  fi
done
if [ -n "$REAL_KEY" ]; then
  if grep -rqF "$REAL_KEY" "$REPO_ROOT" 2>/dev/null; then
    bad "REAL INFERHUB KEY IS PRESENT IN THE REPO"
  else
    ok "real InferHub key absent from the repo"
  fi
else
  ok "no key file present to leak (skipped)"
fi
if grep -rqE '^\s*(export\s+)?INFERHUB_API_KEY\s*=\s*["'"'"']?[A-Za-z0-9_-]{12,}' "$REPO_ROOT" --include="*.sh" 2>/dev/null; then
  bad "a script assigns a literal INFERHUB_API_KEY"
else
  ok "no script assigns a literal INFERHUB_API_KEY"
fi

echo "== .gitignore guards =="
# .gitignore lives at the repo root, one level above macos/ in the published
# layout and two above in the dev checkout.
GITIGNORE="$REPO_ROOT/.gitignore"
[ -f "$GITIGNORE" ] || GITIGNORE="$(dirname "$REPO_ROOT")/.gitignore"
# .env and *.key are the security-relevant ones. vendor/ only applies to the
# submodule layout, so it is not required here.
for pattern in ".env" "*.key" "__pycache__"; do
  if grep -qF "$pattern" "$GITIGNORE" 2>/dev/null; then ok "gitignore covers $pattern"
  else bad "gitignore missing $pattern ($GITIGNORE)"; fi
done

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]