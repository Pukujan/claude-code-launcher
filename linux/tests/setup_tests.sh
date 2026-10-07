#!/usr/bin/env bash
# Tests for linux/setup.sh. Uses a throwaway HOME and a stub launcher, so it
# never touches the real home directory, the InferHub key, or port 4000.
#
#   bash linux/tests/setup_tests.sh
#
# Run by CI in the `linux-dry-run` job (launcher-ci.yml).
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0
fail=0
chk() { # chk <label> <got> <want>
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  FAIL %s (want [%s] got [%s])\n' "$1" "$3" "$2"; fail=$((fail + 1))
  fi
}

# A throwaway checkout: the real setup.sh, a stub launcher that just exits 0.
mk() { # mk <name> -> prints the fake HOME
  local d="$T/$1"
  mkdir -p "$d/linux" "$d/home"
  cp "$REPO_ROOT/linux/setup.sh" "$d/linux/setup.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/linux/launch-claude-inferhub.sh"
  chmod 755 "$d/linux/setup.sh" "$d/linux/launch-claude-inferhub.sh"
  printf '%s' "$d/home"
}

run() { # run <home> <shell> [args...]
  local home="$1" shell="$2"; shift 2
  env -i HOME="$home" SHELL="$shell" PATH=/usr/bin:/bin bash "$home/../linux/setup.sh" "$@"
}

printf '== bash: PATH goes to ~/.bashrc ==\n'
H="$(mk bash)"
run "$H" /bin/bash >/dev/null 2>&1
chk "claude-acs written" "$([ -x "$H/.local/bin/claude-acs" ] && echo yes || echo no)" "yes"
chk "bashrc has one PATH line" "$(grep -c '\.local/bin' "$H/.bashrc" 2>/dev/null)" "1"
chk "no zshrc created" "$([ -e "$H/.zshrc" ] && echo yes || echo no)" "no"

printf '== re-running does not duplicate the PATH line ==\n'
run "$H" /bin/bash >/dev/null 2>&1
chk "bashrc still one PATH line" "$(grep -c '\.local/bin' "$H/.bashrc")" "1"

printf '== zsh: PATH goes to ~/.zshrc ==\n'
H="$(mk zsh)"
run "$H" /usr/bin/zsh >/dev/null 2>&1
chk "zshrc has one PATH line" "$(grep -c '\.local/bin' "$H/.zshrc" 2>/dev/null)" "1"
chk "no bashrc created" "$([ -e "$H/.bashrc" ] && echo yes || echo no)" "no"

printf '== fish: uses fish_add_path ==\n'
H="$(mk fish)"
run "$H" /usr/bin/fish >/dev/null 2>&1
chk "fish config created" "$([ -f "$H/.config/fish/config.fish" ] && echo yes || echo no)" "yes"
chk "fish_add_path used once" "$(grep -c 'fish_add_path' "$H/.config/fish/config.fish" 2>/dev/null)" "1"

printf '== --check reports the installed shim ==\n'
H="$(mk check)"
run "$H" /bin/bash >/dev/null 2>&1
run "$H" /bin/bash --check > "$T/check.out" 2>&1
chk "--check exits 0" "$?" "0"
chk "--check names claude-acs" "$(grep -c 'claude-acs: ' "$T/check.out")" "1"

printf '== --uninstall removes the shim ==\n'
run "$H" /bin/bash --uninstall >/dev/null 2>&1
chk "claude-acs removed" "$([ -e "$H/.local/bin/claude-acs" ] && echo yes || echo no)" "no"

printf '== --help ==\n'
mkdir -p "$T/h"
env -i HOME="$T/h" SHELL=/bin/bash PATH=/usr/bin:/bin bash "$REPO_ROOT/linux/setup.sh" --help > "$T/help.out" 2>&1
chk "--help exits 0" "$?" "0"
chk "--help documents --uninstall" "$(grep -c -- '--uninstall' "$T/help.out")" "1"

printf '\npass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" = 0 ]
