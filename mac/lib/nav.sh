#!/bin/bash
# Terminal folder navigation for the Mac launcher, sourced by
# "Launch Claude InferHub.command". Taken from the macos/ shim (PR #7) and
# kept for the bash 3.2 that ships with macOS.
#
# Everything the user sees goes to the terminal (/dev/tty), never to stdout,
# because callers capture the chosen path with $(...). No Finder or GUI dialog:
# those block the terminal and can't be scripted or tested.
#
# Sourcing this file defines functions and two variables; it runs nothing.

NAVDIR="${CLAUDE_IH_NAV_DIR:-$HOME/.local/state/claude-acs}"
NAVRECENTS="$NAVDIR/recent-folders"

# Does a controlling terminal actually open? `-r /dev/tty` is not a reliable
# test: it succeeds even with no controlling terminal. Probe by opening a real
# fd inside a subshell (so the fd closes with it) and swallow stderr there.
_have_tty() {
  [ -n "${ACS_HAVE_TTY:-}" ] && return "$ACS_HAVE_TTY"
  if ( exec 3</dev/tty ) 2>/dev/null; then ACS_HAVE_TTY=0; else ACS_HAVE_TTY=1; fi
  return "$ACS_HAVE_TTY"
}

# tty_read <varname> <read-args...>: read from the controlling terminal when
# one exists, otherwise from stdin.
tty_read() {
  local __var="$1"; shift
  if _have_tty; then
    # shellcheck disable=SC2229  # `read "$__var"` (no `$`) is the correct bash
    # idiom for a dynamic varname; verified to assign. The alternative,
    # ${__var?}, is what shellcheck suggests but it reads wrong here.
    # shellcheck disable=SC2162  # callers pass -r themselves where it matters
    IFS= read "$@" "$__var" </dev/tty
  else
    # shellcheck disable=SC2229
    # shellcheck disable=SC2162
    IFS= read "$@" "$__var"
  fi
}

# ui <text...>: write to the terminal, never to stdout.
ui() {
  if _have_tty; then
    printf '%s\n' "$@" >/dev/tty
  else
    printf '%s\n' "$@"
  fi
}

note() { ui "$(printf '\033[90m%s\033[0m' "$*")"; }

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

# show_picker <total> <index> <title> <help-line>...: draw a scrolling list
# from PICKER_LINES on the terminal.
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

# Read one keypress and print a token: UP DOWN LEFT RIGHT PGUP PGDN HOME END
# ENTER ESC BACKSPACE OTHER, or a lowercase letter for the hotkeys.
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

get_project_dirs() {
  find "$1" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | LC_ALL=C sort
}

nav_init() {
  mkdir -p "$NAVDIR" 2>/dev/null || true
  chmod 700 "$NAVDIR" 2>/dev/null || true
}

# Add to the recents list, newest first, de-duplicated, at most 20.
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

# Likely starting points, so the common case is one keystroke.
nav_quick_list() {
  local -a cands=(
    "$HOME"
    "$HOME/Desktop"
    "$HOME/Documents"
    "$HOME/Developer"
    "$HOME/src"
    "$HOME/code"
    "$HOME/projects"
    "$HOME/work"
    "${WORK_ROOT:-$HOME/work}"
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

# nav_make_folder <parent> <name>: mkdir -p under an existing parent and print
# the new path. Nested names (a/b/c) are fine; absolute paths, ~ and any ".."
# component are refused.
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

# nav_browse [start]: walk the filesystem from the terminal and print the
# chosen folder on stdout.
#   Up/Down             move
#   Right or Enter      go into the highlighted folder
#   Left or Backspace   go up to the parent
#   s                   use the folder you're in
#   n                   make a new folder here and go into it
#   b or Esc            back to the folder menu (returns 10)
# Needs a terminal; without one it returns 2 straight away.
nav_browse() {
  local start="${1:-$HOME}"
  [ -d "$start" ] || start="$HOME"
  start=$(cd "$start" 2>/dev/null && pwd -P)

  if ! _have_tty; then
    printf 'browsing needs a terminal\n' >&2
    return 2
  fi

  local cur="$start" highlight="" idx key i d up target name created
  local -a entries labels
  while :; do
    entries=()
    while IFS= read -r d; do [ -n "$d" ] && entries+=("$d"); done < <(get_project_dirs "$cur")
    labels=()
    for (( i = 0; i < ${#entries[@]}; i++ )); do
      labels+=("$(basename "${entries[$i]}")/")
    done
    [ ${#entries[@]} -gt 0 ] || labels+=("(no subfolders)")
    PICKER_LINES=("${labels[@]}")
    idx=0
    # Coming back up from a child: put the highlight on that child.
    if [ -n "$highlight" ]; then
      for (( i = 0; i < ${#entries[@]}; i++ )); do
        [ "$(basename "${entries[$i]}")" = "$highlight" ] && idx=$i
      done
      highlight=""
    fi
    while :; do
      show_picker "${#PICKER_LINES[@]}" "$idx" "Browse: $cur" \
        "Up/Down move. Right or Enter opens a folder. Left goes up." \
        "s = use this folder. n = new folder here. b or Esc = back to the menu."
      key=$(read_menu_key)
      case "$key" in
        UP|DOWN|PGUP|PGDN|HOME|END)
          idx=$(move_index "$idx" "${#PICKER_LINES[@]}" "$key" 10) ;;
        LEFT|BACKSPACE)
          up=$(dirname "$cur")
          if [ "$up" != "$cur" ]; then
            highlight="$(basename "$cur")"
            cur="$up"
          fi
          break ;;
        RIGHT|ENTER)
          [ ${#entries[@]} -gt 0 ] || continue
          target="${entries[$idx]}"
          [ -n "$target" ] && [ -d "$target" ] || continue
          cur="$target"
          break ;;
        s)
          printf '%s' "$cur"
          return 0 ;;
        n)
          name=""
          ui "New folder name under $cur: "
          tty_read name -r || name=""
          if [ -n "$name" ] && created=$(nav_make_folder "$cur" "$name"); then
            cur="$created"
          else
            ui "Could not create that folder."
          fi
          break ;;
        b|ESC) return 10 ;;
        *) : ;;
      esac
    done
  done
}

# nav_tilde <path>: the path with $HOME shown as ~ (display only).
nav_tilde() {
  # The leading ~ is a literal display prefix, not an expansion.
  # shellcheck disable=SC2088
  case "$1" in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# nav_expand <path>: expand a leading ~ or ~/ to $HOME (nothing else).
nav_expand() {
  # These are literal ~ patterns to match, not expansions.
  # shellcheck disable=SC2088
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#"~/"}" ;;
    *) printf '%s' "$1" ;;
  esac
}
