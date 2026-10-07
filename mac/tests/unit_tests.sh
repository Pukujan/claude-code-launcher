#!/bin/bash
# shellcheck disable=SC2034,SC2088  # vars are read by the sourced launcher; literal ~ is under test
# Offline unit tests for the Mac launcher, its folder navigation and the stop
# script. No network, no proxy, no key. Runs under bash 3.2 and bash 5:
#
#   mac/tests/unit_tests.sh [bash-binary]
#
# Folds in the old macos/ tests (tests/run-tests.sh and tests/nav-tests.sh).
if [ -n "${1:-}" ] && [ -z "${CCL_UNIT_REEXEC:-}" ]; then
  CCL_UNIT_REEXEC=1 exec "$1" "$0"
fi
MAC="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$MAC/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
export HOME="$SCRATCH/home"
mkdir -p "$HOME"
export CLAUDE_IH_WORK_ROOT="$HOME/work" CLAUDE_IH_STATE_DIR="$SCRATCH/state" CLAUDE_IH_LOG_DIR="$SCRATCH/logs"
ACS_HAVE_TTY=1   # no terminal: every read comes from stdin

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$3] got [$2])"; fi; }

echo "bash $BASH_VERSION"

echo "== syntax =="
for f in "$MAC/Launch Claude InferHub.command" "$MAC/setup.sh" "$MAC/stop-litellm.sh" "$MAC/lib/nav.sh" "$MAC"/tests/*.sh; do
  if "$BASH" -n "$f" 2>/dev/null; then ok "parses: ${f#"$REPO"/}"; else bad "parses: ${f#"$REPO"/}"; fi
done

# The launcher (mac/Launch Claude InferHub.command) is linted on its own.
# shellcheck source=/dev/null
. "$MAC/Launch Claude InferHub.command"

echo "== model table =="
check "20 built-in models" "$MODEL_COUNT" "20"
check "rank 1 id" "$(model_field 1 3)" "cb/deepseek-v4.1-flash"
check "rank 20 id" "$(model_field 20 3)" "cmc/meta/muse-spark-1.3-contributor"
check "resolve by number" "$(resolve_model 10)" "10"
check "resolve by id" "$(resolve_model cbcn/minimax-m3)" "2"
if resolve_model 21 >/dev/null; then bad "rejects 21"; else ok "rejects 21"; fi
check "auto-compact window" "$AUTO_COMPACT_WINDOW" "272000"

echo "== live IRE table =="
IRE_TABLE="$SCRATCH/table.txt"
printf '1|Model A|cb/model-a|true|0.010|0.030\n2|Model B|ali/model-b|false||\n' > "$IRE_TABLE"
saved="$MODELS"
load_ire_table
check "live table replaces the built-in one" "$MODEL_COUNT" "2"
check "live row 2" "$(model_field 2 3)" "ali/model-b"
MODELS="$saved"; MODEL_COUNT=20
printf '1|broken row\n' > "$IRE_TABLE"
load_ire_table 2>/dev/null
check "malformed table ignored" "$MODEL_COUNT" "20"
py="$(command -v python3)"
if [ -n "$py" ]; then
  "$py" "$REPO/shared/ire/ire_fetch.py" --offline --cache-dir "$SCRATCH/ire-cache" \
    --out "$SCRATCH/ire.json" --table-out "$IRE_TABLE" 2>/dev/null
  load_ire_table
  check "ire_fetch.py table loads" "$MODEL_COUNT" "20"
  check "ire_fetch.py table equals the built-in one" "$MODELS" "$saved"
fi
MODELS="$saved"; MODEL_COUNT=20

echo "== menu keys =="
check "up"         "$(move_index 5 20 UP 10)" "4"
check "down"       "$(move_index 5 20 DOWN 10)" "6"
check "up clamp"   "$(move_index 0 20 UP 10)" "0"
check "down clamp" "$(move_index 19 20 DOWN 10)" "19"
check "home"       "$(move_index 7 20 HOME 10)" "0"
check "end"        "$(move_index 7 20 END 10)" "19"
check "empty list" "$(move_index 0 0 UP 10)" "0"
check "enter" "$(printf '\n' | read_menu_key)" "ENTER"
check "up key" "$(printf '\033[A' | read_menu_key)" "UP"
check "down key" "$(printf '\033[B' | read_menu_key)" "DOWN"
check "left key" "$(printf '\033[D' | read_menu_key)" "LEFT"
check "pgdn key" "$(printf '\033[6~' | read_menu_key)" "PGDN"
check "letter key" "$(printf 'S' | read_menu_key)" "s"
check "clip_line short" "$(clip_line visible 40)" "visible"
check "clip_line long" "$(clip_line abcdefghij 6)" "abc..."

echo "== slot editor (issue #91) =="
check "chain_at rung 1" "$(chain_at "a b c" 1)" "a"
check "chain_at past the end" "$(chain_at "a b c" 4)" ""
check "chain_set replaces a rung and keeps the tail" "$(chain_set "a b c" 1 "z")" "z b c"
check "chain_set none truncates" "$(chain_set "a b c" 2 "")" "a"
check "chain_set appends past the end" "$(chain_set "a b" 3 "c")" "a b c"
check "chain_set de-duplicates" "$(chain_set "a b c" 1 "b")" "b c"
check "chain_set caps at 3 rungs" "$(chain_set "a b c d" 4 "e")" "a b c"
check "slot_num maps haiku to 3" "$(slot_num haiku)" "3"
SLOT_CHAINS[0]="x/y z/w"
check "slot_arg is the --slot form" "$(slot_arg sonnet)" "sonnet=x/y,z/w"
check "slot_chain_text joins with dashes" "$(slot_chain_text sonnet)" "x/y-z/w"
# The chains round-trip through last-picks.json. haiku_same makes haiku follow
# sonnet without storing the chain twice.
slots_file save 1 "s1 s2" "o1" "f1" "unused"
check "saved sonnet" "$(slots_file load | awk -F'\t' '$1=="sonnet"{print $2}')" "s1 s2"
check "haiku_same follows sonnet" "$(slots_file load | awk -F'\t' '$1=="haiku"{print $2}')" "s1 s2"
slots_file save 0 "s1" "o1" "f1" "h1 h2"
check "haiku independent without haiku_same" "$(slots_file load | awk -F'\t' '$1=="haiku"{print $2}')" "h1 h2"
slots_file launch ultracode uc-orch uc-worker
check "a launch save keeps the slots" "$(slots_file load | awk -F'\t' '$1=="sonnet"{print $2}')" "s1"
check "a slots save keeps the launch target" "$(last_pick launch)" "ultracode"
# The resolver fills all four chains (seat file first, then the built-in chains).
slots_default_load
for slot in sonnet opus fable haiku; do
  if [ -n "$(slot_chain "$slot")" ]; then ok "resolver fills $slot"; else bad "resolver fills $slot"; fi
done
# With no terminal the editor must change nothing, so apply_seat keeps using
# --main/--advisor and the dry run's piped answers still line up.
SLOTS_PICKED=1
pick_slots
check "no terminal skips the editor" "$SLOTS_PICKED" ""
CLAUDE_IH_SLOTS=off pick_slots
check "CLAUDE_IH_SLOTS=off skips the editor" "$SLOTS_PICKED" ""
unset CLAUDE_IH_SLOTS

echo "== env scrubbing =="
export ANTHROPIC_BASE_URL=http://elsewhere:1 ANTHROPIC_API_KEY=x ANTHROPIC_AUTH_TOKEN=x \
  CKFF_API_KEY=x ckff_api_url=x CLAUDE_CODE_OAUTH_TOKEN=x SHIM_KEEP_ME=keep
clear_claude_env
check "base url cleared" "${ANTHROPIC_BASE_URL:-}" ""
check "auth token cleared" "${ANTHROPIC_AUTH_TOKEN:-}" ""
check "ckff cleared" "${CKFF_API_KEY:-}${ckff_api_url:-}" ""
check "oauth cleared" "${CLAUDE_CODE_OAUTH_TOKEN:-}" ""
check "unrelated kept" "${SHIM_KEEP_ME:-}" "keep"

echo "== claude.ai login check =="
mock_status() {
  printf '{\n  "loggedIn": %s,\n  "authMethod": "%s",\n  "apiProvider": "firstParty"\n}\n' "$1" "$2"
  [ "$1" = true ]
}
# shellcheck disable=SC2317,SC2329  # called by claude_ai_logged_in
claude() { mock_status true claude.ai; }
if claude_ai_logged_in; then ok "claude.ai login seen"; else bad "claude.ai login seen"; fi
# shellcheck disable=SC2317,SC2329  # called by claude_ai_logged_in
claude() { mock_status false none; }
if claude_ai_logged_in; then bad "logged out is not a login"; else ok "logged out is not a login"; fi
# shellcheck disable=SC2317,SC2329  # called by claude_ai_logged_in
claude() { mock_status true api_key; }
if claude_ai_logged_in; then bad "API key is not a claude.ai login"; else ok "API key is not a claude.ai login"; fi
# shellcheck disable=SC2317,SC2329  # called by claude_ai_logged_in
claude() { echo "not json"; return 1; }
if claude_ai_logged_in; then bad "broken claude is not a login"; else ok "broken claude is not a login"; fi
unset -f claude

echo "== folder helpers =="
NAVDIR="$SCRATCH/nav"; NAVRECENTS="$NAVDIR/recent-folders"
base="$SCRATCH/f"; mkdir -p "$base"
check "make folder" "$(nav_make_folder "$base" newproj)" "$base/newproj"
nav_make_folder "$base" a/b/c >/dev/null
check "nested make" "$([ -d "$base/a/b/c" ] && echo yes)" "yes"
for name in ../escape "" . .. /abs "~/x"; do
  if nav_make_folder "$base" "$name" >/dev/null 2>&1; then bad "refuses [$name]"; else ok "refuses [$name]"; fi
done
if nav_make_folder "$base/missing" c >/dev/null 2>&1; then bad "refuses a missing parent"; else ok "refuses a missing parent"; fi
r1="$base/alpha"; r2="$base/beta"; mkdir -p "$r1" "$r2"
nav_remember "$r1"; nav_remember "$r2"
check "newest recent first" "$(nav_recents_list 2>/dev/null | head -1)" "$(cd "$r2" && pwd -P)"
nav_remember "$r1"
check "recents de-duplicated" "$(nav_recents_list | wc -l | tr -d ' ')" "2"
ln -s "$r1" "$base/link"; nav_remember "$base/link"
check "symlink collapsed" "$(nav_recents_list | grep -c link)" "0"
nav_remember "$base/nope"
check "missing dir ignored" "$(nav_recents_list | grep -c nope)" "0"
ql="$(nav_quick_list)"
check "quick picks list home" "$(printf '%s\n' "$ql" | grep -cx "$(cd "$HOME" && pwd -P)")" "1"
check "quick picks unique" "$(printf '%s\n' "$ql" | sort -u | wc -l | tr -d ' ')" "$(printf '%s\n' "$ql" | wc -l | tr -d ' ')"
mkdir -p "$base/visible" "$base/.hidden"
check "hidden folders skipped" "$(get_project_dirs "$base" | grep -c '\.hidden')" "0"
check "nav_expand ~" "$(nav_expand '~/x')" "$HOME/x"
check "nav_tilde" "$(nav_tilde "$HOME/x")" "~/x"
nav_browse "$base" >/dev/null 2>&1; rc=$?
check "browse without a terminal returns 2" "$rc" "2"
code="$(grep -hv '^[[:space:]]*#' "$MAC/Launch Claude InferHub.command" "$MAC/lib/nav.sh")"
if printf '%s\n' "$code" | grep -qE 'osascript|choose folder'; then bad "no Finder dialog"; else ok "no Finder dialog"; fi

echo "== folder picker (piped answers) =="
mkdir -p "$CLAUDE_IH_WORK_ROOT/one" "$CLAUDE_IH_WORK_ROOT/two" "$SCRATCH/typed"
pick() { ( pick_folder >/dev/null 2>&1 && printf '%s' "$PROJECT_DIR" ); }
check "number picks a subfolder" "$(printf '3\ny\n' | pick)" "$CLAUDE_IH_WORK_ROOT/two"
check "Enter picks the root" "$(printf '\n\n' | pick)" "$CLAUDE_IH_WORK_ROOT"
check "t types a path" "$(printf 't\n%s\ny\n' "$SCRATCH/typed" | pick)" "$SCRATCH/typed"
check "n makes a folder" "$(printf 'n\n\nfresh\ny\n' | pick)" "$CLAUDE_IH_WORK_ROOT/fresh"
check "no then yes" "$(printf '2\nn\n3\ny\n' | pick)" "$CLAUDE_IH_WORK_ROOT/one"
printf 't\n%s\ny\n' "$SCRATCH/typed" | pick >/dev/null
menu="$(printf 'x\n' | ( pick_folder ) 2>&1)"
if printf '%s\n' "$menu" | grep -q "typed  (recent)"; then ok "recent folder listed"; else bad "recent folder listed"; fi
check "q quick pick" "$(printf 'q\n1\ny\n' | pick)" "$(cd "$HOME" && pwd -P)"
check "x quits" "$(printf 'x\n' | pick)" ""

echo "== ultracode (orchestrator/worker picks) =="
if command -v uv >/dev/null 2>&1; then
  UC_DIR="$SCRATCH/ucshim"; UC_STATE_DIR="$SCRATCH/ucstate"; UC_PORT=$((4100 + 4241))
  mkdir -p "$UC_DIR/bin"
  : > "$UC_DIR/proxy.py"; printf '%s\n' "$UC_COMMIT" > "$UC_DIR/.commit"
  cp "$REPO/tests/fixtures/ultracode/config.example.json" "$UC_DIR/"
  # shellcheck disable=SC2016  # the fake ultracode expands these itself
  printf '#!/bin/bash\necho "ran UC_SELECTOR=$UC_SELECTOR $*"\n' > "$UC_DIR/bin/ultracode"; chmod +x "$UC_DIR/bin/ultracode"
  MAIN_NAME="DeepSeek V4.1 Flash"; ADVISOR_NAME=""; LAUNCH=ultracode
  CLAUDE_IH_UC_ORCH=claude-ih-fast CLAUDE_IH_UC_WORKER="" pick_ultracode 2>/dev/null
  check "orchestrator from CLAUDE_IH_UC_ORCH" "$UC_ORCH" "claude-ih-fast"
  check "worker empty = same" "$UC_WORKER" ""
  check "last picks keep launch" "$(last_pick launch)" "ultracode"
  check "last picks keep the orchestrator" "$(last_pick uc_orch)" "claude-ih-fast"
  check "first choice is the main seat" "$(head -1 "$UC_LIST" | cut -f1)" "claude-ih-main"
  check "no CKFF choice" "$(grep -ci ckff "$UC_LIST")" "0"
  check "Top 20 listed" "$(grep -c '^claude-ih-cb-deepseek-v4-1-flash	' "$UC_LIST")" "1"
  check "shim port" "$(grep -c "\"listen_port\": $UC_PORT" "$UC_DIR/config.json")" "1"
  unset UC_ORCH UC_WORKER
  uc_pick orch < <(printf '\033[B\n') >/dev/null 2>&1
  check "arrow pick: Down from last time's orchestrator" "$UC_PICK" "claude-ih-cb-deepseek-v4-1-flash"
  uc_pick worker < <(printf '\n') >/dev/null 2>&1
  check "worker highlights last time's pick (same)" "$UC_PICK" ""
  if uc_pick worker < <(printf '\033[D') >/dev/null 2>&1; then bad "Left goes back"; else ok "Left goes back"; fi
  UC_ORCH=claude-ih-main UC_WORKER=claude-ih-fast
  out="$( ( run_ultracode ) 2>/dev/null )"
  check "runs the cached bin/ultracode with the shim picker off" "$out" "ran UC_SELECTOR=0 --model claude-ih-main --permission-mode bypassPermissions"
  check "selection.json preselects both tiers" "$(tr -d ' \n' < "$UC_STATE_DIR/selection.json")" '{"orch":"claude-ih-main","worker":"claude-ih-fast","worker_explicit":true}'
  unset UC_ORCH UC_WORKER LAUNCH
else
  echo "  skip (uv not installed)"
fi

echo "== stop-litellm.sh =="
mkdir -p "$SCRATCH/repo/mac" "$SCRATCH/repo/shared/litellm/logs"
cp "$MAC/stop-litellm.sh" "$SCRATCH/repo/mac/"
sleep 30 & other=$!
printf '%s\n' "$other" > "$SCRATCH/repo/shared/litellm/logs/litellm.pid"
"$BASH" "$SCRATCH/repo/mac/stop-litellm.sh" >/dev/null 2>&1; rc=$?
check "refuses a PID that isn't its LiteLLM" "$rc" "1"
check "that process is left alone" "$(kill -0 "$other" 2>/dev/null && echo alive)" "alive"
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
"$BASH" "$SCRATCH/repo/mac/stop-litellm.sh" >/dev/null 2>&1
check "stale PID file removed" "$([ -f "$SCRATCH/repo/shared/litellm/logs/litellm.pid" ] && echo left)" ""

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
