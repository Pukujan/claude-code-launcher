#!/usr/bin/env bash
# =============================================================================
# InferHub Claude Code launcher via the UNIFIED local LiteLLM proxy.
# macOS (bash 3.2 compatible) port of:
#   agent-custom-setup :: modules/claude-code/inferhub-litellm/v0.2.0/launch-claude-inferhub.ps1
# Upstream source of truth: https://github.com/Pukujan/agent-custom-setup
# Secrets: loaded at runtime from a .env file by path. NEVER embed API keys,
# tokens, or .env contents in this file.
# =============================================================================
set -euo pipefail

# ---- configuration (override with environment variables) --------------------
# Windows originals (superseded, kept for reference):
#   C:\Users\pujan\OneDrive\Desktop\configs\.env  -> $HOME/Documents/secrets/.env
#   D:\claude\litellm                             -> $HOME/litellm
#   D:\claude                                     -> $HOME/claude
#   D:\claude\inferhub\.env                       -> $HOME/Documents/secrets/.env
CLAUDE_ROOT="${CLAUDE_ROOT:-$HOME/claude}"
LITELLM_ROOT="${LITELLM_ROOT:-$HOME/litellm}"
PROXY_PORT="${PROXY_PORT:-4000}"
PROXY_BASE="http://127.0.0.1:${PROXY_PORT}"
DEFAULT_MODEL_ID="cb/deepseek-v4.1-flash"
# Single local secret file: INFERHUB_API_KEY, LITELLM_MASTER_KEY, CKFF_* all live here.
CKFF_ENV_FILE="${CKFF_ENV_FILE:-$HOME/Documents/secrets/.env}"
INFERHUB_ENV_FILE="${INFERHUB_ENV_FILE:-$HOME/Documents/secrets/.env}"

# ---- model table (IRE Top 20) ----------------------------------------------
# Parallel arrays: index order matches Rank order. "eligible" = 1, gated = 0.
MODEL_NAMES=(
  "DeepSeek V4.1 Flash" "GLM 5.3 Flash" "Gemini 3.8 Flash" "DeepSeek V4 Flash" "DeepSeek V4 Pro 0813" "Qwen3.8 Max 0902"
  "Qwen3.8 Flash" "Muse Spark 1.3 Contributor" "GPT 5.6 Luna" "MiniMax M3" "DeepSeek V4 Flash 0731" "Gemini 3.7 Flash"
  "Gemini 3.6 Flash" "DeepSeek V4 Pro" "GLM 5.2" "Hy4 Preview" "Muse Spark 1.2 Contributor" "Qwen 3.8 Max"
  "GLM 5.3" "Kimi K2.7 Code"
)
MODEL_IDS=(
  "cb/deepseek-v4.1-flash" "cbcn/glm-5.3-flash" "ag/gemini-3.8-flash-high" "cbcn/deepseek-v4-flash" "ali/deepseek-v4-pro-0813" "ali/qwen3.8-max-0902"
  "ali/qwen3.8-flash" "cmc/meta/muse-spark-1.3-contributor" "cx/gpt-5.6-luna" "cbcn/minimax-m3" "ali/deepseek-v4-flash-0731" "ag/gemini-3.7-flash-high"
  "ag/gemini-3.6-flash-high" "cbcn/deepseek-v4-pro" "ali/glm-5.2" "cb/hy4-preview" "cmc/meta/muse-spark-1.2-contributor" "ali/qwen3.8-max"
  "cbcn/glm-5.3" "ali/kimi-k2.7-code"
)
MODEL_ELIGIBLE=(
  1 1 0 1 0 0
  1 0 0 1 0 0
  0 1 1 0 0 1
  1 1
)
MODEL_COSTS=(
  "0.022108" "0.032924" "0.066345" "0.046688" "0.08298" "0.078043"
  "0.008056" "0.040076" "0.04015" "0.052142" "0.091326" "0.077005"
  "0.080802" "0.138399" "0.180507" "0.077408" "0.028751" "0.169559"
  "0.26708" "0.155677"
)
MODEL_COUNT=${#MODEL_IDS[@]}

# ---- helpers ---------------------------------------------------------------
die() { printf '%s\n' "$*" >&2; exit 1; }

# Does a controlling terminal actually open? `-r /dev/tty` is not a reliable
# test: it succeeds even with no controlling terminal. Probe by opening a real
# fd inside a subshell (so the fd closes with it) and swallow stderr there.
_have_tty() {
  [ -n "${ACS_HAVE_TTY:-}" ] && return "$ACS_HAVE_TTY"
  if ( exec 3</dev/tty ) 2>/dev/null; then ACS_HAVE_TTY=0; else ACS_HAVE_TTY=1; fi
  return "$ACS_HAVE_TTY"
}

# tty_read <varname> <read-args...> : read from the controlling terminal when
# one exists, otherwise from stdin. shellcheck-disable=SC2229
# (`read "$__var"` without `$` is the correct bash idiom for a dynamic varname;
#  verified to assign correctly).
tty_read() {
  local __var="$1"; shift
  if _have_tty; then
    # shellcheck disable=SC2229  # `read "$__var"` (no `$`) is the correct bash
    # idiom for a dynamic varname; verified to assign. The alternative,
    # ${__var?}, is what shellcheck suggests but it reads wrong here.
    IFS= read "$@" "$__var" </dev/tty
  else
    # shellcheck disable=SC2229
    IFS= read "$@" "$__var"
  fi
}

# ui <text...> -> write to the real terminal, never to stdout.
# The pickers run inside $(...) so stdout is reserved for the returned index;
# without this the whole menu would be captured and never displayed.
ui() {
  if _have_tty; then
    printf '%s\n' "$@" >/dev/tty
  else
    printf '%s\n' "$@"
  fi
}

info() { ui "$(printf '\033[36m%s\033[0m' "$*")"; }
note() { ui "$(printf '\033[90m%s\033[0m' "$*")"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }

read_env_value() {
  # read_env_value <path> <NAME> -> value on stdout, empty if absent
  local path="$1" name="$2" line
  [ -r "$path" ] || return 0
  line=$(grep -m1 -E "^[[:space:]]*${name}[[:space:]]*=" "$path" 2>/dev/null || true)
  [ -n "$line" ] || return 0
  line="${line#*=}"
  line="${line#"${line%%[![:space:]]*}"}"   # ltrim
  line="${line%"${line##*[![:space:]]}"}"   # rtrim
  line="${line%\"}"; line="${line#\"}"
  line="${line%\'}"; line="${line#\'}"
  printf '%s' "$line"
}

read_master_key() {
  local key
  key=$(read_env_value "$CKFF_ENV_FILE" "LITELLM_MASTER_KEY")
  [ -n "$key" ] || key=$(read_env_value "$CKFF_ENV_FILE" "LITELLM_PROXY_KEY")
  [ -n "$key" ] || die "LITELLM_MASTER_KEY not found in $CKFF_ENV_FILE (set LITELLM_MASTER_KEY or point CKFF_ENV_FILE at your .env)"
  printf '%s' "$key"
}

clear_screen() {
  # Must go through ui: the pickers run inside $(...), so anything printed to
  # stdout here would be captured into the selected index and break arithmetic.
  if _have_tty; then
    printf '\033[H\033[2J\033[3J' >/dev/tty 2>/dev/null || printf '\033[H\033[2J' >/dev/tty
  else
    printf '\033[H\033[2J\033[3J'
  fi
}

clip_line() {
  # clip_line <text> <width>
  local text="$1" width="$2"
  [ "$width" -lt 4 ] && width=4
  [ "${#text}" -le "$width" ] && { printf '%s' "$text"; return 0; }
  printf '%s...' "${text:0:$((width - 3))}"
}

console_layout() {
  # prints "<rows> <cols> <maxitems>"
  local rows cols used maxitems
  rows=$(tput lines 2>/dev/null || echo 30)
  cols=$(tput cols 2>/dev/null || echo 100)
  [ "${rows:-0}" -gt 0 ] 2>/dev/null || rows=30
  [ "${cols:-0}" -gt 0 ] 2>/dev/null || cols=100
  used=$1
  maxitems=$((rows - used))
  [ "$maxitems" -lt 3 ] && maxitems=3
  printf '%s %s %s' "$rows" "$cols" "$maxitems"
}

# Show a paginated picker on the terminal. Writes the UI to /dev/tty (never to
# stdout) so the caller can capture the selection on stdout via $(...) safely.
# usage: show_picker <total> <index> <title> <help-line-1> [help-line-2...]
show_picker() {
  local total="$1" index="$2" title="$3"; shift 3
  local help_lines=("$@")
  local help_count=${#help_lines[@]}
  local layout rows cols maxitems
  layout=$(console_layout $((6 + help_count)))
  read -r rows cols maxitems <<<"$layout"
  [ "$maxitems" -gt "$total" ] && maxitems=$total
  [ "$maxitems" -lt 1 ] && maxitems=1
  local width=$((cols - 1))
  [ "$width" -lt 40 ] && width=40

  local start=0 above shown below_count
  if [ "$total" -gt "$maxitems" ]; then
    start=$((index - (maxitems - 1) / 2))
    [ "$start" -lt 0 ] && start=0
    [ "$start" -gt $((total - maxitems)) ] && start=$((total - maxitems))
  fi
  above=""
  [ "$start" -gt 0 ] && above="  ... ${start} more above"
  shown=$maxitems
  [ $((start + shown)) -gt "$total" ] && shown=$((total - start))
  below_count=$((total - (start + shown)))
  below=""
  [ "$below_count" -gt 0 ] && below="  ... ${below_count} more below"

  clear_screen
  ui "$(clip_line "$title" "$width")" ""
  [ -n "$above" ] && note "$(clip_line "$above" "$width")"

  if [ "$total" -eq 0 ]; then
    ui "  (nothing to choose)"
  else
    local i prefix text
    for (( i = start; i < start + shown; i++ )); do
      if [ "$i" -eq "$index" ]; then
        prefix="> "
        text="${prefix}${PICKER_LINES[$i]}"
        ui "$(printf '\033[36m%s\033[0m' "$(clip_line "$text" "$width")")"
      else
        text="  ${PICKER_LINES[$i]}"
        ui "$(clip_line "$text" "$width")"
      fi
    done
  fi

  [ -n "$below" ] && note "$(clip_line "$below" "$width")"
  ui ""
  local hl
  for hl in "${help_lines[@]}"; do
    ui "$(clip_line "$hl" "$width")"
  done
}

# Read one keypress; echoes a token: UP DOWN LEFT RIGHT PGUP PGDN HOME END
# ENTER ESC, or a single lowercase letter for the hotkeys.
read_menu_key() {
  local ch rest rc
  # `read -rsn1` swallows the delimiter, so Enter arrives as an EMPTY string
  # with rc=0. Distinguish it from a real character by length, not by rc alone
  # (rc=1 means EOF with no byte at all).
  tty_read ch -rsn1 || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] && { echo "ESC"; return 0; }
  if [ -z "$ch" ]; then
    echo "ENTER"
    return 0
  fi
  # A plain letter is a hotkey (b, n, q, t, ...). Return it lowercased so the
  # caller can match case-insensitively.
  case "$ch" in
    [A-Za-z]) printf '%s' "$ch" | tr '[:upper:]' '[:lower:]'; return 0 ;;
    $'\177') echo "BACKSPACE"; return 0 ;;   # DEL, the usual Backspace key
  esac
  [ "$ch" != $'\033' ] && { echo "OTHER"; return 0; }
  rest=""
  # bash 3.2 `read -t` takes an integer only (no fractional timeouts), so the
  # escape-sequence read uses 1. It returns immediately when the bytes are
  # already buffered; only a bare ESC waits the full second.
  tty_read rest -rsn2 -t 1 || true
  case "$rest" in
    '[A') echo "UP" ;;
    '[B') echo "DOWN" ;;
    '[C') echo "RIGHT" ;;
    '[D') echo "LEFT" ;;
    '[5') _eat_tty_char; echo "PGUP" ;;
    '[6') _eat_tty_char; echo "PGDN" ;;
    '[H') echo "HOME" ;;
    '[F') echo "END" ;;
    '[1') _eat_tty_char; echo "HOME" ;;
    '[4') _eat_tty_char; echo "END" ;;
    *) echo "ESC" ;;
  esac
}

_eat_tty_char() {
  local _ignored
  tty_read _ignored -rsn1 -t 1 || true
}

move_index() {
  # move_index <index> <count> <key> <pagesize>
  local index="$1" count="$2" key="$3" page="$4"
  [ "$count" -le 0 ] && { echo 0; return 0; }
  [ "$page" -lt 1 ] && page=1
  case "$key" in
    UP)   [ "$index" -gt 0 ] && index=$((index - 1)) ;;
    DOWN) [ "$index" -lt $((count - 1)) ] && index=$((index + 1)) ;;
    PGUP) index=$((index - page)); [ "$index" -lt 0 ] && index=0 ;;
    PGDN) index=$((index + page)); [ "$index" -gt $((count - 1)) ] && index=$((count - 1)) ;;
    HOME) index=0 ;;
    END)  index=$((count - 1)) ;;
  esac
  printf '%s' "$index"
}

interactively_select() {
  # interactively_select <title> <help1> [help2...]  (PICKER_LINES pre-populated)
  # echoes selected index. Falls back to numbered entry when stdin is not a tty.
  local title="$1"; shift
  local index=0 total=${#PICKER_LINES[@]}
  if [ ! -t 0 ]; then
    local i n
    for (( i = 0; i < total; i++ )); do printf '%3d) %s\n' "$((i + 1))" "${PICKER_LINES[$i]}"; done
    printf 'select [1-%d]: ' "$total" >&2
    local pick=""; read -r pick || die "cancelled"
    [ -z "$pick" ] && pick=1
    [ "$pick" -ge 1 ] && [ "$pick" -le "$total" ] || die "invalid selection"
    printf '%s' "$((pick - 1))"; return 0
  fi
  while :; do
    show_picker "$total" "$index" "$title" "$@"
    local key page
    key=$(read_menu_key)
    page=$(console_layout $((6 + $#)))
    case "$key" in
      ENTER) printf '%s' "$index"; return 0 ;;
      ESC) die "Cancelled." ;;
      *) index=$(move_index "$index" "$total" "$key" "${page##* }") ;;
    esac
  done
}

# Assert a captured index is a bare non-negative integer. Anything else means UI
# output leaked into the command substitution; fail loudly rather than let it
# reach arithmetic as a syntax error.
assert_index() {
  case "$1" in
    ''|*[!0-9]*) die "internal error: picker returned a non-numeric index [$1]" ;;
  esac
}

select_main_model() {
  local i
  PICKER_LINES=()
  for (( i = 0; i < MODEL_COUNT; i++ )); do
    local star=" " tag="gated"
    [ "${MODEL_ELIGIBLE[$i]}" -eq 1 ] && tag="eligible"
    [ "${MODEL_IDS[$i]}" = "$DEFAULT_MODEL_ID" ] && star="*"
    PICKER_LINES+=("$(printf '%s%2d  %-28s  %-42s  %-8s  ~%s/Mtok' \
      "$star" "$((i + 1))" "${MODEL_NAMES[$i]}" "${MODEL_IDS[$i]}" "$tag" "${MODEL_COSTS[$i]}")")
  done
  local idx
  idx=$(interactively_select \
    "Choose MAIN model (IRE Top 20). Default DeepSeek V4.1 Flash." \
    "MAIN executor (maps to alias sonnet/main). Up/Down/PgUp/PgDn/Home/End. Enter. Esc quits." \
    "gated = ranked but not currently recommendation-eligible.")
  assert_index "$idx"
  printf '%s' "$idx"
}

select_advisor_model() {
  # index 0 = OFF, then the full model list
  local i
  PICKER_LINES=("OFF  (disable advisor tool / seat aliases fall back to main)")
  for (( i = 0; i < MODEL_COUNT; i++ )); do
    local tag="gated"
    [ "${MODEL_ELIGIBLE[$i]}" -eq 1 ] && tag="eligible"
    PICKER_LINES+=("$(printf '%2d  %-28s  %-42s  %-8s  ~%s/Mtok' \
      "$((i + 1))" "${MODEL_NAMES[$i]}" "${MODEL_IDS[$i]}" "$tag" "${MODEL_COSTS[$i]}")")
  done
  local idx
  idx=$(interactively_select \
    "Choose ADVISOR model (IRE Top 20) or OFF." \
    "ADVISOR model (maps to alias opus/advisor) or OFF. Enter selects. Esc quits." \
    "Mid-session use /advisor opus or /advisor sonnet (aliases), not raw InferHub ids.")
  assert_index "$idx"
  printf '%s' "$idx"
}

get_project_dirs() {
  find "$1" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | LC_ALL=C sort
}

# ---- folder navigation ------------------------------------------------------
# The picker must reach ANY folder, not just children of one root. Four ways in,
# tried in this order from one menu:
#   1. browse   - walk the real filesystem, mkdir-style, with ~/ shortcuts
#   2. quick    - a short list of likely roots (home, Desktop, Documents, code
#                 dirs, git repos) so the common case is one keystroke
#   3. type     - paste an absolute path
#   4. recents  - folders launched before, newest first
#
# Deliberately NO Finder/GUI dialog (osascript `choose folder`): it blocks the
# terminal, steals focus, and cannot be driven from a script or a test. Browse
# mode is the terminal-native way to reach any folder.
NAVDIR="$HOME/.local/state/claude-acs"
NAVRECENTS="$NAVDIR/recent-folders"

nav_init() {
  mkdir -p "$NAVDIR" 2>/dev/null || true
  chmod 700 "$NAVDIR" 2>/dev/null || true
}

# Append to the recents list, newest first, de-duped, capped.
nav_remember() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  nav_init
  # Resolve so /tmp and /private/tmp style aliases collapse to one entry.
  local real
  real=$(cd "$dir" 2>/dev/null && pwd -P) || return 0
  local tmp="$NAVRECENTS.tmp.$$"
  { printf '%s\n' "$real"; grep -Fxv "$real" "$NAVRECENTS" 2>/dev/null || true; } \
    | head -20 >"$tmp"
  mv "$tmp" "$NAVRECENTS" 2>/dev/null || rm -f "$tmp"
}

nav_recents_list() {
  nav_init
  [ -f "$NAVRECENTS" ] || return 0
  local d
  while IFS= read -r d; do
    [ -d "$d" ] && printf '%s\n' "$d"
  done <"$NAVRECENTS"
}

# Quick-pick roots for the common case. Terminal-only: no GUI, no focus steal.
nav_quick_list() {
  local -a cands=(
    "$HOME"
    "$HOME/Desktop"
    "$HOME/Documents"
    "$HOME/Documents/secrets"
    "$HOME/Developer"
    "$HOME/src"
    "$HOME/code"
    "$HOME/projects"
    "$HOME/work"
    "$CLAUDE_ROOT"
    "$PWD"
  )
  local d seen=" "
  for d in "${cands[@]}"; do
    [ -d "$d" ] || continue
    # De-dup on the resolved path so ~/work and a symlink to it list once.
    local r; r=$(cd "$d" 2>/dev/null && pwd -P) || continue
    case "$seen" in
      *" $r "*) continue ;;
    esac
    seen="$seen $r "
    printf '%s\n' "$r"
  done
}

nav_make_folder() {
  # mkdir -p under an existing parent; returns the new path on stdout.
  # Nested names (a/b/c) are allowed; anything that could escape the parent
  # (absolute paths, .. components) is rejected.
  local parent="$1" name="$2"
  [ -d "$parent" ] || return 1
  [ -n "$name" ] || return 1
  case "$name" in
    /*) return 1 ;;          # absolute: would ignore the parent
    ~*) return 1 ;;         # home-relative: ditto
  esac
  # Reject any ".." path component, and a name that is only dots.
  case "/$name/" in
    */../*|*/./*) return 1 ;;
  esac
  [ "$name" = "." ] && return 1
  [ "$name" = ".." ] && return 1
  # Trailing slashes would make the returned path differ from the real dir.
  name="${name%/}"
  [ -n "$name" ] || return 1
  mkdir -p "$parent/$name" 2>/dev/null || return 1
  printf '%s' "$parent/$name"
}

# Browse mode: a file-explorer REPL. Prints the chosen path on stdout.
#
# Keys (no mouse, no GUI):
#   Up/Down        move the highlight
#   Right / Enter  forward: go INTO the highlighted folder
#   Left / Backspace  back: go to the OWNING (parent) folder
#   n              new folder here, then go into it
#   b              back to the main menu
#   Esc            back to the main menu
#
# There is no history stack: left/right are strictly parent/child, so you always
# know where you are from the path in the title.
nav_browse() {
  local start="${1:-$HOME}"
  [ -d "$start" ] || start="$HOME"
  start=$(cd "$start" 2>/dev/null && pwd -P)

  if [ ! -t 0 ]; then
    printf 'not a tty\n' >&2
    return 2
  fi

  local cur="$start"
  # Name of the child we most recently backed out of, so Left lands on it and
  # Right goes straight back in. Empty until the first move.
  local highlight=""

  while :; do
    local -a entries=()
    local d
    while IFS= read -r d; do [ -n "$d" ] && entries+=("$d"); done < <(get_project_dirs "$cur")

    # Labels mirror entries one-for-one, so the highlight index IS the folder index.
    local -a labels=()
    local i
    for (( i = 0; i < ${#entries[@]}; i++ )); do
      labels+=("$(basename "${entries[$i]}")/")
    done
    [ ${#entries[@]} -gt 0 ] || labels+=("(no subfolders)")

    PICKER_LINES=("${labels[@]}")
    local idx=0
    # Restore the highlight onto the child we came back out of.
    if [ -n "$highlight" ]; then
      for (( i = 0; i < ${#entries[@]}; i++ )); do
        [ "$(basename "${entries[$i]}")" = "$highlight" ] && idx=$i
      done
      highlight=""
    fi
    local key
    # One iteration = one keystroke, so hotkeys work without a selection.
    while :; do
      show_picker "${#PICKER_LINES[@]}" "$idx" "Browse: $cur" \
        "Up/Down move. Right or Enter goes into the folder. Left goes to the parent. n = new folder."
      key=$(read_menu_key)
      case "$key" in
        UP)   idx=$(move_index "$idx" "${#PICKER_LINES[@]}" UP 10) ;;
        DOWN) idx=$(move_index "$idx" "${#PICKER_LINES[@]}" DOWN 10) ;;
        PGUP) idx=$(move_index "$idx" "${#PICKER_LINES[@]}" PGUP 10) ;;
        PGDN) idx=$(move_index "$idx" "${#PICKER_LINES[@]}" PGDN 10) ;;
        HOME) idx=0 ;;
        END)  idx=$(( ${#PICKER_LINES[@]} - 1 )) ;;
        LEFT|BACKSPACE)
          # Back = the owning folder. At "/" there is nowhere higher, so stay put.
          local up; up=$(dirname "$cur")
          if [ "$up" != "$cur" ]; then
            highlight="$(basename "$cur")"
            cur="$up"
          fi
          break
          ;;
        RIGHT|ENTER)
          # Forward = into the highlighted folder.
          if [ ${#entries[@]} -eq 0 ]; then break; fi
          local target="${entries[$idx]}"
          [ -n "$target" ] && [ -d "$target" ] || break
          cur="$target"
          idx=0
          break
          ;;
        n)
          local name="" created
          ui "New folder name under $cur: "
          IFS= read -r name || name=""
          if [ -n "$name" ] && created=$(nav_make_folder "$cur" "$name"); then
            ui "created ${created}"
            cur="$created"
            idx=0
          else
            ui "could not create that folder"
          fi
          break
          ;;
        b) return 10 ;;
        ESC) return 10 ;;
        *) : ;;   # unhandled key: redraw
      esac
    done
  done
}

# Returns:
#   0 + path on stdout -> folder chosen
#   1               -> cancelled / no choice; caller re-shows the menu
#   10              -> user pressed [m] in browse mode; caller re-shows the menu
# stdout must stay clean here: the caller captures it with $(...).
choose_folder() {
  nav_init
  local -a labels=() kinds=() values=()
  local d

  labels+=("[b]  Browse folders (walk the filesystem)"); kinds+=("browse"); values+=("$PWD")
  labels+=("[q]  Quick picks (home, Desktop, Documents, code dirs)"); kinds+=("quick"); values+=("")

  while IFS= read -r d; do
    [ -n "$d" ] || continue
    # Show a shortened label; the full path is confirmed before launch anyway.
    local disp="$d"
    # The leading ~ below is a literal display prefix, not an expansion.
    # shellcheck disable=SC2088
    case "$disp" in
      "$HOME"/*) disp="~/${disp#"$HOME"/}" ;;
      "$HOME") disp="~" ;;
    esac
    labels+=("$(basename "$d")  —  $disp")
    kinds+=("direct"); values+=("$d")
  done < <(nav_recents_list)

  labels+=("[t]  Type a path"); kinds+=("typed"); values+=("")
  labels+=("[n]  New folder"); kinds+=("new"); values+=("")
  labels+=("[p]  Projects under $CLAUDE_ROOT"); kinds+=("projects"); values+=("$CLAUDE_ROOT")

  # interactively_select reads the global PICKER_LINES; publish the menu we just
  # built. Omitting this left PICKER_LINES unbound under `set -u`.
  PICKER_LINES=("${labels[@]}")

  local idx
  idx=$(interactively_select "Launch Claude Code in which folder?" \
    "Enter selects. b = browse, q = quick picks, t = type a path, n = new folder." \
    "Your recent folders are listed after b and q.")
  assert_index "$idx"

  case "${kinds[$idx]}" in
    browse)
      local out rc=0
      out=$(nav_browse "${values[$idx]}") || rc=$?
      # 10 = user asked to return to this menu; anything else non-zero is a
      # cancel or a non-tty bail-out. Both just re-show the menu.
      [ "$rc" -eq 10 ] && return 10
      [ -n "$out" ] && [ -d "$out" ] && { printf '%s' "$out"; return 0; }
      return 1
      ;;
    quick)
      local -a qs=() qd
      while IFS= read -r qd; do [ -n "$qd" ] && qs+=("$qd"); done < <(nav_quick_list)
      [ ${#qs[@]} -gt 0 ] || { printf 'no quick-pick folders exist yet\n' >&2; return 1; }
      PICKER_LINES=()
      local i
      for (( i = 0; i < ${#qs[@]}; i++ )); do
        local lbl="${qs[$i]}"
        # The leading ~ is a literal display prefix, not an expansion.
        # shellcheck disable=SC2088
        case "$lbl" in
          "$HOME") lbl="~  (home)" ;;
          "$HOME"/*) lbl="~/${lbl#"$HOME"/}" ;;
        esac
        PICKER_LINES+=("$lbl")
      done
      local j
      j=$(interactively_select "Quick picks" "Enter selects that folder. Esc goes back.")
      assert_index "$j"
      printf '%s' "${qs[$j]}"; return 0
      ;;
    direct)
      printf '%s' "${values[$idx]}"; return 0
      ;;
    typed)
      local raw="" expanded
      printf 'Absolute path (~/ is expanded): ' >/dev/tty 2>/dev/null || printf 'Absolute path (~/ is expanded): '
      IFS= read -r raw || true
      [ -n "$raw" ] || return 1
      expanded="${raw/#\~/$HOME}"
      [ -d "$expanded" ] || { printf 'not a directory: %s\n' "$expanded" >&2; return 1; }
      printf '%s' "$(cd "$expanded" && pwd -P)"; return 0
      ;;
    new)
      local parent="$PWD" name="" created
      printf 'Create a new folder. Parent [%s]: ' "$parent" >/dev/tty 2>/dev/null || printf 'Create a new folder. Parent [%s]: ' "$parent"
      IFS= read -r parent || parent="$PWD"
      parent="${parent/#\~/$HOME}"
      [ -d "$parent" ] || { printf 'parent does not exist: %s\n' "$parent" >&2; return 1; }
      printf 'New folder name: ' >/dev/tty 2>/dev/null || printf 'New folder name: '
      IFS= read -r name || name=""
      created=$(nav_make_folder "$parent" "$name") || { printf 'could not create it\n' >&2; return 1; }
      printf '%s' "$created"; return 0
      ;;
    projects)
      # The original behaviour: pick one of the subfolders of CLAUDE_ROOT.
      local -a dirs=()
      while IFS= read -r d; do [ -n "$d" ] && dirs+=("$d"); done < <(get_project_dirs "$CLAUDE_ROOT")
      [ ${#dirs[@]} -gt 0 ] || { printf 'no folders under %s\n' "$CLAUDE_ROOT" >&2; return 1; }
      PICKER_LINES=()
      local i
      for (( i = 0; i < ${#dirs[@]}; i++ )); do PICKER_LINES+=("$(basename "${dirs[$i]}")"); done
      local j
      j=$(interactively_select "Folders under $CLAUDE_ROOT" "Enter selects. Esc quits.")
      assert_index "$j"
      printf '%s' "${dirs[$j]}"; return 0
      ;;
  esac
  return 1
}

confirm_launch() {
  # echoes YES / NO
  PICKER_LINES=("Yes, launch Claude here" "No, pick a different folder")
  local idx
  idx=$(interactively_select "Launch Claude Code in $1 ?" "Up and Down move. Enter confirms. Esc quits.")
  assert_index "$idx"
  [ "$idx" -eq 0 ] && echo YES || echo NO
}

select_project_folder() {
  # One menu, retried until the user commits to a real directory. Cancelling the
  # Finder dialog, an empty typed path, or [m] in browse mode all return here.
  local chosen rc=0
  while :; do
    chosen=$(choose_folder) || rc=$?
    case "$rc" in
      0)
        rc=0
        if [ -n "$chosen" ] && [ -d "$chosen" ]; then
          if [ "$(confirm_launch "$chosen")" = "YES" ]; then
            nav_remember "$chosen"
            printf '%s' "$chosen"
            return 0
          fi
        fi
        ;;
      1|10)
        # Cancelled or "back to menu": offer the menu again.
        rc=0
        ;;
      *)
        return 1
        ;;
    esac
  done
}

# ---- Claude settings / model picker ----------------------------------------
sync_model_picker() {
  local seat_alias="$1"
  local settings="$HOME/.claude/settings.json"
  [ -f "$settings" ] || return 0
  command -v jq >/dev/null 2>&1 || { warn "jq not found; skipping model picker sync"; return 0; }

  local opts='[]'
  local i
  for (( i = 0; i < MODEL_COUNT; i++ )); do
    local tag="gated"
    [ "${MODEL_ELIGIBLE[$i]}" -eq 1 ] && tag="eligible"
    opts=$(jq -c --arg m "ih/${MODEL_IDS[$i]}" \
      --arg l "${MODEL_NAMES[$i]} (InferHub ih/)" \
      --arg d "IRE Top 20 #$((i + 1)); ${tag} - prefer sonnet/opus seats for advisor" \
      '. + [{model:$m, label:$l, description:$d, behavesAs:"claude-sonnet-5"}]' <<<"$opts")
  done
  opts=$(jq -c '. + [
    {model:"opus", label:"InferHub seat (opus/advisor alias)",
     description:"Maps to seated Top 20 advisor via local LiteLLM", behavesAs:"claude-opus-4-6"},
    {model:"sonnet", label:"InferHub seat (sonnet alias)",
     description:"Maps to seated Top 20 main via local LiteLLM", behavesAs:"claude-sonnet-5"}
  ]' <<<"$opts")

  local tmp
  tmp=$(mktemp)
  if jq --argjson opts "$opts" --arg seat "$seat_alias" \
      '.model = $seat
       | .advisorModel = "opus"
       | .modelPicker = { options: $opts }' "$settings" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$settings"
    info "synced model picker into $settings"
  else
    rm -f "$tmp"
    warn "could not sync model picker: $settings left unchanged"
  fi
}

# ---- LiteLLM proxy ---------------------------------------------------------
test_proxy_health() {
  # /health can 500 without prisma; unauthenticated /v1/models 500s when a
  # master key is set. Prefer the liveliness/readiness probes.
  local path
  for path in /health/liveliness /health/readiness /health/liveness; do
    if curl -fsS -m 2 -o /dev/null "${PROXY_BASE}${path}" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

ensure_litellm_proxy() {
  if test_proxy_health; then
    info "LiteLLM proxy already up at $PROXY_BASE"
    return 0
  fi
  local starter="$LITELLM_ROOT/start-litellm.sh"
  [ -f "$starter" ] || die "Missing $starter - the LiteLLM workbench is expected at $LITELLM_ROOT (set LITELLM_ROOT)"
  info "Starting unified LiteLLM proxy (background)..."
  ( cd "$LITELLM_ROOT" && nohup ./start-litellm.sh -Background -SkipSync -Port "$PROXY_PORT" \
      >"$LITELLM_ROOT/logs/start-$$.log" 2>&1 & ) || true
  local deadline=$(( $(date +%s) + 180 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 2
    if test_proxy_health; then
      info "LiteLLM proxy is healthy at $PROXY_BASE"
      return 0
    fi
  done
  die "LiteLLM proxy did not become healthy at $PROXY_BASE within 180s. Check $LITELLM_ROOT/logs"
}

apply_inferhub_seat() {
  local main_id="$1" advisor_id="$2"
  local py="$LITELLM_ROOT/.litellm-venv/bin/python"
  local apply="$LITELLM_ROOT/scripts/apply_seat.py"
  if [ ! -x "$py" ] || [ ! -f "$apply" ]; then
    # Workbench not installed yet: still record the seat so the next start uses it.
    local seat_path="$LITELLM_ROOT/config/inferhub_seat.json"
    mkdir -p "$(dirname "$seat_path")"
    jq -n --arg main "$main_id" --arg adv "$advisor_id" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{main_inferhub_id:$main, advisor_inferhub_id:(if $adv=="" then null else $adv end), updated_at:$ts}' \
      >"$seat_path"
    note "wrote seat file (workbench venv not ready yet); proxy start will apply aliases"
    return 0
  fi
  ( cd "$LITELLM_ROOT" && "$py" "$apply" --main "$main_id" --advisor "$advisor_id" ) \
    || die "apply_seat.py failed"
}

# ---- environment scrubbing -------------------------------------------------
clear_conflicting_env() {
  # Wipe ANTHROPIC_* / CLAUDE_CODE_* / CKFF_* / ckff_* so the Claude child
  # cannot inherit a User/Process CKFF BASE_URL or key. Claude Code prefers
  # ANTHROPIC_AUTH_TOKEN over ANTHROPIC_API_KEY when both are present, so the
  # exact list must not miss any of them.
  local n
  while IFS= read -r n; do
    [ -n "$n" ] && unset "$n" 2>/dev/null || true
  done < <(env | sed -n 's/^\(ANTHROPIC_[A-Za-z0-9_]*\)=.*/\1/p')
  while IFS= read -r n; do
    [ -n "$n" ] && unset "$n" 2>/dev/null || true
  done < <(env | sed -n 's/^\(CLAUDE_CODE_[A-Za-z0-9_]*\)=.*/\1/p')
  while IFS= read -r n; do
    [ -n "$n" ] && unset "$n" 2>/dev/null || true
  done < <(env | sed -n 's/^\(CKFF_[A-Za-z0-9_]*\)=.*/\1/p')
  while IFS= read -r n; do
    [ -n "$n" ] && unset "$n" 2>/dev/null || true
  done < <(env | sed -n 's/^\(ckff_[A-Za-z0-9_]*\)=.*/\1/p')
  unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_MODEL \
        ANTHROPIC_SMALL_FAST_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
        ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL \
        CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_API_KEY_HELPER_TTL_MS \
        CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS 2>/dev/null || true
  # Keep experimental betas ON: never export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS.
}

# ---- main ------------------------------------------------------------------
# Non-interactive overrides, handy for scripted/agent use:
#   ACS_MAIN_ID, ACS_ADVISOR_ID ("" = OFF), ACS_FOLDER
main() {
  command -v claude >/dev/null 2>&1 || die "claude CLI not on PATH (npm install -g @anthropic-ai/claude-code)"

  local main_id main_name advisor_id advisor_label folder seat_alias master rc
  if [ -n "${ACS_MAIN_ID:-}" ]; then
    local i found=""
    for (( i = 0; i < MODEL_COUNT; i++ )); do
      if [ "${MODEL_IDS[$i]}" = "$ACS_MAIN_ID" ]; then found="$ACS_MAIN_ID"; break; fi
    done
    [ -n "$found" ] || die "ACS_MAIN_ID '$ACS_MAIN_ID' is not in the IRE Top 20 table"
    main_id="$ACS_MAIN_ID"
    main_name="(preset)"
    advisor_id="${ACS_ADVISOR_ID:-}"
    advisor_label="${advisor_id:-(preset OFF)}"
    [ -n "$advisor_id" ] && advisor_label="$advisor_id (preset)"
    folder="${ACS_FOLDER:-$CLAUDE_ROOT}"
  else
    local main_idx adv_idx
    main_idx=$(select_main_model)
    main_id="${MODEL_IDS[$main_idx]}"
    main_name="${MODEL_NAMES[$main_idx]}"

    adv_idx=$(select_advisor_model)
    if [ "$adv_idx" -eq 0 ]; then
      advisor_id=""
      advisor_label="OFF"
    else
      advisor_id="${MODEL_IDS[$((adv_idx - 1))]}"
      advisor_label="${MODEL_NAMES[$((adv_idx - 1))]} (${MODEL_IDS[$((adv_idx - 1))]})"
    fi
    folder=$(select_project_folder)
  fi
  [ -d "$folder" ] || die "Project folder does not exist: $folder"

  apply_inferhub_seat "$main_id" "$advisor_id"
  ensure_litellm_proxy
  # Re-apply now that the venv/proxy definitely exists.
  apply_inferhub_seat "$main_id" "$advisor_id"
  note "Seat applied. If the proxy was already running with an old seat, restart it:"
  note "  cd $LITELLM_ROOT && ./stop-litellm.sh && ./start-litellm.sh -Background"

  seat_alias="sonnet"
  sync_model_picker "$seat_alias"
  master="${LITELLM_DUMMY_KEY:-litellm-local-no-auth}"
  # The proxy runs without a master key on loopback, so Claude Code still needs
  # *some* value here. LiteLLM ignores it; the real INFERHUB_API_KEY stays in the
  # proxy process only and is never re-exposed to the Claude child.

  clear_conflicting_env

  # Force InferHub-via-local-LiteLLM for this Claude child only.
  # Key = LiteLLM master/virtual key, NEVER CKFF.
  export ANTHROPIC_API_KEY="$master"
  export ANTHROPIC_BASE_URL="$PROXY_BASE"
  export ANTHROPIC_MODEL="$seat_alias"
  export ANTHROPIC_SMALL_FAST_MODEL="ih/ali/qwen3.8-flash"
  # Do NOT set ANTHROPIC_AUTH_TOKEN: it would win over ANTHROPIC_API_KEY and risk
  # resolving through CKFF.
  # Keep experimental betas ON (advisor_* orchestration runs through LiteLLM).

  cd "$folder"

  clear_screen
  ui "cwd=$(pwd)"
  ui "proxy=$ANTHROPIC_BASE_URL  (unified CKFF+InferHub LiteLLM)"
  ui "small_fast=$ANTHROPIC_SMALL_FAST_MODEL  (InferHub cheap side model for search/hooks)"
  ui "seat_alias=$seat_alias  behavesAs=claude-sonnet-5"
  ui "main=$main_id  ($main_name)"
  ui "advisor=$advisor_label"
  ui "permission=bypassPermissions (auto mode is Anthropic-only)"
  ui "betas=experimental ON (advisor_20260301 via LiteLLM orchestration)"
  ui "Starting Claude Code..."
  set +e
  claude --model "$seat_alias" --permission-mode bypassPermissions
  rc=$?
  set -e
  ui "claude exited $rc"
  if [ -t 0 ]; then
    ui "Press Enter to close..."
    read -r _ || true
  fi
}

# Guard: sourcing this file must not launch Claude.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  [ -t 0 ] && { stty -echo 2>/dev/null || true; trap "stty echo 2>/dev/null || true" EXIT; }
  main "$@"
fi