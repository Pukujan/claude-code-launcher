#!/usr/bin/env bash
# =============================================================================
# Launch Claude InferHub (Linux)
# Source of truth: Pukujan/claude-code-launcher linux/ (see SOURCES.md).
#
# The launcher body is shared with mac/ on purpose. "mac/Launch Claude InferHub.command"
# is bash, already branches on `uname -s` to use XDG paths off-macOS (logs under
# $XDG_STATE_HOME/claude-inferhub, state under $XDG_DATA_HOME/claude-inferhub),
# and CI already runs it on ubuntu-latest (launcher-ci.yml: mac-dry-run and the
# bash 3.2 job). Copying 1,200 lines here would only create drift, so this entry
# point does the Linux-specific parts and hands off:
#
#   1. refuses to run off Linux, so a mis-copied command fails loudly;
#   2. checks the checkout is complete before starting;
#   3. execs the shared body with every argument passed through unchanged.
#
# A follow-up (its own issue) proposes lifting the shared body into shared/ so
# that mac/ and linux/ are both thin entries. That touches mac/, so it is not
# done here.
#
# Everything the Mac launcher documents applies unchanged: CLAUDE_IH_PROJECT,
# CLAUDE_IH_MAIN and CLAUDE_IH_ADVISOR skip the pickers; --non-interactive or
# CCL_NONINTERACTIVE=1 runs without menus; --print-env json|dotenv prints the
# environment; CLAUDE_IH_SETUP_ONLY=1 stops after the installs (linux/setup.sh
# uses that).
# =============================================================================
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
LAUNCHER="$REPO_ROOT/mac/Launch Claude InferHub.command"

if [ "$(uname -s)" != "Linux" ]; then
  printf 'linux/launch-claude-inferhub.sh is for Linux (this is %s); use the launcher for your platform.\n' "$(uname -s)" >&2
  exit 2
fi

if [ ! -f "$LAUNCHER" ]; then
  printf 'The shared launcher is missing at:\n  %s\nRun this from a complete claude-code-launcher checkout (git pull).\n' "$LAUNCHER" >&2
  exit 1
fi

exec "${BASH:-/bin/bash}" "$LAUNCHER" "$@"
