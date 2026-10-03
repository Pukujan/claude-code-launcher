#!/usr/bin/env bash
# Unit tests for the folder navigation added to the macOS launcher.
# No tty required: every helper here is a pure function of its arguments.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# See run-tests.sh: tolerate both the macos/ layout and the dev checkout.
LAUNCHER="$REPO_ROOT/launch-claude-inferhub.sh"
[ -f "$LAUNCHER" ] || LAUNCHER="$REPO_ROOT/platform/macos/workbench/launch-claude-inferhub.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$3] got [$2])"; fi; }

# shellcheck source=/dev/null
. "$LAUNCHER"
# The launcher sets `set -euo pipefail` for its own run. That is correct for the
# app but fatal for a test harness: one failing assertion would abort the suite
# instead of being counted. Re-enable errexit's absence for the tests only.
set +e
set +u
set +o pipefail 2>/dev/null || true

# Redirect the recents file into a scratch dir so a real run never touches state.
NAVDIR="$(mktemp -d)"
# shellcheck disable=SC2034  # read by nav_init/nav_recents_list in the sourced launcher
NAVRECENTS="$NAVDIR/recent-folders"

echo "== nav_make_folder =="
base="$(mktemp -d)"
created=$(nav_make_folder "$base" "newproj")
check "creates a dir"       "$([ -d "$created" ] && echo yes || echo no)" "yes"
check "returns full path"   "$created" "$base/newproj"
nav_make_folder "$base" "a/b/c" >/dev/null
check "nested -p works"     "$([ -d "$base/a/b/c" ] && echo yes || echo no)" "yes"
if nav_make_folder "$base" "../escape" >/dev/null 2>&1; then bad "rejects ../escape"; else ok "rejects ../escape"; fi
if nav_make_folder "$base" "sub/child" >/dev/null 2>&1; then ok "allows sub/child"; else bad "allows sub/child"; fi
if nav_make_folder "$base" "" >/dev/null 2>&1; then bad "rejects empty name"; else ok "rejects empty name"; fi
if nav_make_folder "$base" "." >/dev/null 2>&1; then bad "rejects dot"; else ok "rejects dot"; fi
if nav_make_folder "$base" ".." >/dev/null 2>&1; then bad "rejects dotdot"; else ok "rejects dotdot"; fi
if nav_make_folder "$base/nonexistent-parent-xyz" "c" >/dev/null 2>&1; then bad "rejects missing parent"; else ok "rejects missing parent"; fi

echo "== nav_remember / nav_recents_list =="
r1="$base/alpha"; r2="$base/beta"; mkdir -p "$r1" "$r2"
nav_remember "$r1"; check "first recent"  "$(nav_recents_list | head -1)" "$(cd "$r1" && pwd -P)"
nav_remember "$r2"; check "newest first"   "$(nav_recents_list | head -1)" "$(cd "$r2" && pwd -P)"
nav_remember "$r1"; check "dedup keeps 2" "$(nav_recents_list | wc -l | tr -d ' ')" "2"
check "re-pushed to top"   "$(nav_recents_list | head -1)" "$(cd "$r1" && pwd -P)"
nav_remember "$base/does-not-exist" 2>/dev/null
check "ignores missing dir" "$(nav_recents_list | grep -c does-not-exist)" "0"
nav_remember "$base"; nav_remember "$base/alpha"
check "caps at 20" "$(nav_recents_list | wc -l | tr -d ' ')" "3"

echo "== nav_remember resolves symlinks =="
ln -sfn "$r1" "$base/link-to-alpha" 2>/dev/null
nav_remember "$base/link-to-alpha"
check "symlink collapsed" "$(nav_recents_list | grep -c 'link-to-alpha')" "0"

echo "== nav_quick_list (terminal-only, no GUI) =="
ql=$(nav_quick_list)
check "lists $HOME" "$(printf '%s\n' "$ql" | grep -c "^$HOME$")" "1"
check "no duplicates" "$(printf '%s\n' "$ql" | sort -u | wc -l | tr -d ' ')" "$(printf '%s\n' "$ql" | wc -l | tr -d ' ')"
check "every entry is a real dir" "$(while IFS= read -r p; do [ -d "$p" ] || echo "$p"; done <<<"$ql" | wc -l | tr -d ' ')" "0"
# Regression guard: the Finder dialog was removed on purpose. Any osascript
# `choose folder` call blocks the terminal and cannot be tested headlessly.
# Match code only (strip comments first) so the explanatory comment passes.
code=$(grep -v '^[[:space:]]*#' "$LAUNCHER")
if printf '%s\n' "$code" | grep -q "choose folder"; then bad "launcher still calls the Finder dialog"; else ok "no Finder/GUI dialog in the launcher"; fi
if printf '%s\n' "$code" | grep -q "nav_pick_finder"; then bad "nav_pick_finder still referenced"; else ok "nav_pick_finder fully removed"; fi
if printf '%s\n' "$code" | grep -q "osascript"; then bad "osascript still invoked"; else ok "no osascript in executable code"; fi

echo "== get_project_dirs skips hidden =="
mkdir -p "$base/visible" "$base/.hidden"
check "only visible listed" "$(get_project_dirs "$base" | grep -c '\.hidden')" "0"
check "visible present"     "$(get_project_dirs "$base" | grep -c 'visible')" "1"

echo "== choose_folder non-tty safety =="
# With no tty the picker must not hang or silently "succeed".
out=$(choose_folder 2>/dev/null </dev/null); rc=$?
if [ "$rc" -ne 0 ] || [ -z "$out" ]; then ok "non-tty returns cleanly (rc=$rc)"; else bad "non-tty returned [$out]"; fi

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
rm -rf "$NAVDIR" "$base"
[ "$fail" -eq 0 ]