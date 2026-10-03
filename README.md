# claude-code-launcher

Double-click one file and Claude Code opens in your project, with every request
going through a LiteLLM proxy on your own machine to InferHub. This repository
holds that launcher for **Windows** and **Mac**, and the proxy files both of
them run.

Before this repository, the launcher lived in three places that had drifted
apart: a Desktop copy on the PC, a module in agent-custom-setup, and the
`litellm-ckff-ops` workbench it needed cloned next to it. Now one checkout is
enough.

![Claude Code talks to a LiteLLM proxy on the same machine, which forwards to InferHub](docs/assets/launcher-flow.svg)

## Start it

**Windows.** Clone this repository, then double-click
`windows\launch-claude-inferhub.cmd`. Pick the main model, the advisor (or OFF)
and a project folder with the arrow keys. The first run makes the Python venv
under `shared\litellm\.litellm-venv`; Python and Claude Code must already be
installed.

**Mac.** Clone this repository, then double-click
`mac/Launch Claude InferHub.command`. The first run installs what is missing
and asks once for your InferHub key. See [mac/README.md](mac/README.md).
**The Mac launcher has only been tested on Linux so far.**

Both launchers pick the same 20 models, default to DeepSeek V4.1 Flash with the
advisor OFF, and start Claude Code with
`claude --model sonnet --permission-mode bypassPermissions`.

**Two Mac launchers for now.** `mac/` is the port from agent-custom-setup and
runs the proxy from `shared/litellm/`. `macos/` arrived separately in PR #7 and
installs its own proxy under `~/litellm`. Both put the proxy on 127.0.0.1:4000
keyless. Which one stays is still open.

## Keys

Copy `.env.example` to `.env` in the repository root and fill in
`INFERHUB_API_KEY`. That is the only key you need on a Mac. On the PC the
launcher also reads `C:\Users\pujan\OneDrive\Desktop\configs\.env` for the CKFF
keys, and takes the InferHub key from the first of these that exists: the IRE
`.env` in `D:\development\inference-recommendation-engine`, this repository's
`.env`, `~\.config\inferhub\.env`.

**There is no proxy key.** The proxy runs without a `LITELLM_MASTER_KEY` and
listens on 127.0.0.1 only, so nothing outside the machine can reach it. Claude
Code still insists on some API key, so the launchers give it the dummy value
`local`. If you do set `LITELLM_MASTER_KEY` in one of the env files, the proxy
enforces it and the launchers pass it to Claude Code instead.

Only `.env.example` is tracked. `.env` is gitignored.

## How a request is routed

Claude Code only knows Anthropic model names. The proxy maps them to the two
InferHub seats you picked:

| Claude Code asks for | Goes to |
| --- | --- |
| `sonnet`, `main`, `claude-sonnet-5` | the main seat |
| `opus`, `advisor`, `claude-opus-5-5`, `claude-fable-5` | the advisor seat, or main when the advisor is OFF |
| `ih/<model id>` | that InferHub model directly |

If a seat fails, the proxy falls back along the chains in
`shared/litellm/config/inferhub_fallbacks.yaml`. Changing seats later
hot-reloads the running proxy; it does not restart it.

## What is where

| Folder | What it holds |
| --- | --- |
| `windows/` | The PowerShell launcher, and `litellm/` with the start and stop scripts |
| `mac/` | The Mac launcher ported from agent-custom-setup, its guide and its dry-run test |
| `macos/` | A separate Mac shim installer (`setup.sh`, `claude-acs`) with a live IRE model table, from PR #7 |
| `shared/litellm/` | Proxy config, seat and merge scripts, fallback chains, pinned requirements |
| `docs/` | [PARITY.md](docs/PARITY.md) compares the two launchers; [HOOKS.md](docs/HOOKS.md) lists where planned features plug in |
| `history/` | Older launcher versions, kept as a record |
| `SOURCES.md` | Where every copied file came from, with commit and hash |

## Boundaries

- **Port 4000 is the live proxy.** Tests use other ports, and
  `stop-litellm.ps1` stops only the process `start-litellm.ps1` recorded in
  `shared/litellm/logs/litellm.pid`, never whatever happens to hold the port.
- If a proxy started from the old `litellm-ckff-ops` checkout is still running
  on 4000, the launchers reuse it. It reads its own config files, so seat
  changes made from this repository do not reach it. Stop that one by hand once
  and let the launcher start its own.
- The routing scripts are copied from `litellm-ckff-ops` unchanged. Changing
  them needs its own issue.

## Status

| Check | State |
| --- | --- |
| Windows launcher | Taken from the PC on 2026-10-03, with small path and key edits listed in `SOURCES.md`. Linted in CI; the edits have not been run on Windows yet. |
| Mac launcher | Dry run passes on Linux under bash 5 and bash 3.2.57. Not yet run on a Mac. |
| CI | `gates` (stack validators), `lint`, `mac-dry-run` and `python-tests` are required on every pull request. |
