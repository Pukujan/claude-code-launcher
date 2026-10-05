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

**Windows, one command.** In PowerShell:

```powershell
irm https://github.com/Pukujan/claude-code-launcher/releases/download/v1.0.0-windows/install.ps1 | iex
```

That installs whatever is missing (uv, Git, Node, pnpm, Claude Code), asks for
the InferHub key and a free TinyFish Search key (skippable), puts the launcher in `%LOCALAPPDATA%\claude-code-launcher`
and adds a `claude-inferhub` command. See
[windows/README-friend.md](windows/README-friend.md) for the details,
`--set-key` and `--uninstall`, and [docs/specs/windows-package.md](docs/specs/windows-package.md)
for how it works.

**Windows, from a clone.** Clone this repository, then double-click
`windows\launch-claude-inferhub.cmd`. Pick a model chain for each of Claude
Code's four slots (or keep the saved ones) and a project folder with the arrow
keys. The first run makes the Python venv
under `shared\litellm\.litellm-venv` with uv (or with `python -m venv` and
pip if uv is not installed); Claude Code and either uv or Python must already
be installed.

**Mac.** Clone this repository, then double-click
`mac/Launch Claude InferHub.command`, or run `mac/setup.sh` once and use the
`claude-acs` command after that. The first run installs what is missing and asks
once for your InferHub key. Folders can be picked from a list, browsed with the
arrow keys in the terminal, or typed. See [mac/README.md](mac/README.md).
**The Mac launcher has only been tested on Linux so far.**

Both launchers start Claude Code with
`claude --model sonnet --permission-mode bypassPermissions`. Plan mode is never
switched on; planning goes to a planner sub-agent instead (see "Slots" below).
The model list is the IRE Top 20, fetched at start-up by `shared/ire/` (see
below).

## Non-interactive mode (for other tools)

Some tools start Claude Code themselves, for example
[Paseo](https://github.com/getpaseo/paseo) on a phone. They can still go through
the local LiteLLM with the same seats, aliases and fallback chains. Non-interactive
mode shows no menus and never prompts. It also never starts, restarts or reloads
the proxy: the proxy keeps the seat from the last interactive launch, and if the
proxy is down the command stops with exit code 3.

```powershell
# Windows: print the variables, or run claude with them
.\windows\launch-claude-inferhub.ps1 -NonInteractive -PrintEnv json
.\windows\launch-claude-inferhub.ps1 -NonInteractive -Folder D:\development\app -- -p "hello"
```

```bash
# Mac
"mac/Launch Claude InferHub.command" --non-interactive --print-env dotenv
"mac/Launch Claude InferHub.command" --non-interactive -- -p "hello"
```

Both launchers accept `--non-interactive`, `--print-env json|dotenv` and
`--folder DIR`. Windows also takes the `-NonInteractive`, `-PrintEnv` and
`-Folder` spellings. The `CCL_NONINTERACTIVE=1` and `CCL_PRINT_ENV=json`
environment variables do the same thing. Launcher options go first, and `--`
ends them. The JSON output has four parts:

- `set`: the variables Claude Code gets, the same ones an interactive launch
  sets (base URL, auth, `sonnet` as the model, the four slot pins,
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW` and `CLAUDE_CODE_WORKFLOWS`)
- `unset`: names to clear first
- `unset_prefixes`: prefixes whose leftover variables should be cleared too
- `info`: the seat, where it was read from, whether the proxy is healthy and
  which auth is used

Non-interactive mode uses the slots saved by the last interactive launch and
never shows a menu. `last-picks.json` is only reported; if it disagrees with
what the proxy has, you get a warning. To change the slots, run the launcher
interactively.

Passing arguments that contain double quotes (JSON) through Windows PowerShell
5.1 loses the quotes. For tools that do that, use
`node shared/integrations/claude-env-exec.mjs [claude args...]`. It reads the
JSON, applies it and starts claude with the arguments exactly as given. It keeps
the `CLAUDE_CODE_*` control variables an SDK host sets, skips the launcher for
`--version` and `auth` probes, and passes claude's exit code back. Set
`CCL_CLAUDE_BIN` to choose the claude executable. It also turns
`--permission-mode default` (which Paseo sends when it resumes a session that
started in default mode) into `--permission-mode auto`; set
`CCL_KEEP_DEFAULT_PERMISSION_MODE=1` to keep default. Other modes pass through.

## CKFF is off

Since 2026-10-04 CKFF is turned off everywhere (Alex: never use CKFF routes,
`ckff_astra` included). The proxy serves InferHub only: `runtime.yaml` gets no
CKFF models or fallbacks, `start-litellm.ps1` loads no `ckff*` keys, and
`claude-haiku-4-5` goes to the haiku slot like `haiku`. The pickers, defaults
and ladders drop every CKFF route (any id with `ckff` in it) from the IRE lists,
and a saved pick that is a CKFF model falls back to the default. InferHub's own
Astra routes (`cb/gpt-6-astra`, `cx/gpt-6-astra`) are not CKFF and stay. The
switch is `ckff_enabled` in `shared/litellm/config/providers.yaml`
(`LITELLM_ENABLE_CKFF=1` overrides it); the CKFF config stays in the repo but
is not used.

## Keys

Copy `.env.example` to `.env` in the repository root and fill in
`INFERHUB_API_KEY`, plus any web search keys you have (`TINYFISH_API_KEY`,
`TAVILY_API_KEY`, `EXA_API_KEY`), under those standard names. That one file is
all the launchers need.

**On the PC that file is the only one read when it exists** (issue #64): the
launcher and `start-litellm.ps1` load the repository's `.env` and then the
per-PC settings in `shared\litellm\.env.local`, and nothing else. Only when the
repository has no `.env` do they fall back to the old places: `configs\.env` on
your Desktop (the first that exists of the Desktop known folder,
`%USERPROFILE%\Desktop` and `%OneDrive%\Desktop`) for other keys such as the web
search ones, never its `ckff*` names, and for the InferHub key the first of the
IRE `.env` in `inference-recommendation-engine` next to this repository or under
`D:\development`, then `~\.config\inferhub\.env`. To see which file a proxy
start would read, run `windows\litellm\start-litellm.ps1 -ShowEnvSources`: it
prints the files and which key names are set, never their values, and starts
nothing. The Mac launcher reads the repository's `.env` first and then
`~/.config/inferhub/.env`. A packaged install keeps its own keys in its install
folder (`secrets\inferhub.env`, `secrets\tinyfish.env`) and never reads either.

**There is no proxy key.** The proxy runs without a `LITELLM_MASTER_KEY` and
listens on 127.0.0.1 only, so nothing outside the machine can reach it. Claude
Code still insists on some API key, so the launchers give it the dummy value
`local`. If you do set `LITELLM_MASTER_KEY` in one of the env files, the proxy
enforces it and the launchers pass it to Claude Code instead.

Only `.env.example` is tracked. `.env` is gitignored.

## How a request is routed

Claude Code has four model slots, and each one gets its own InferHub chain: a
first model plus up to two fallbacks. The defaults:

| Slot | Used for | Default chain |
| --- | --- | --- |
| `sonnet` | the main chat (`--model sonnet`) | DeepSeek V4.1 Flash, Qwen3.8 Flash, GLM-5.3 Flash |
| `opus` | planning (the planner sub-agent) and `model: opus` sub-agents | GPT-6 Astra, GPT-6.1 Sol, Qwen3.8 Max |
| `fable` | the advisor (`advisorModel: fable`) | GLM-5.3 Flash, Qwen3.8 Flash, DeepSeek V4.1 Flash |
| `haiku` | background calls (titles, summaries, Explore) | the same chain as sonnet |

The proxy answers to the slot word and to the Claude names Claude Code sends for
it (`claude-sonnet-5`, `claude-opus-5-5`, `claude-fable-5`,
`claude-haiku-4-5-20251001`, and older ones like `main`, `advisor` and
`small-fast`). A `claude-*` name it has never seen goes to the slot in its name
(`claude-opus-4-8` goes to opus); one with no slot word goes to sonnet and logs a
warning. `ih/<model id>` still reaches that InferHub model directly. The full
list is in `shared/litellm/scripts/slots.py`.

When a model fails, its retries are spent first, then the slot moves to its next
model. A model that keeps failing is benched for a few minutes, except the last
one in each chain, which is never benched, so a slot always has somewhere to go.
An empty reply is retried once on the same model, then the slot moves on; empty
replies never bench anything. Changing the slots later hot-reloads the running
proxy; it does not restart it.

GPT-6 Astra in the opus slot is InferHub's `cb/gpt-6-astra`, not CKFF (see "CKFF
is off" above). It was picked from IRE's frontier list (rank 1, best route) on
2026-10-04: about $0.07 in / $0.35 out per 1M tokens at the cheapest ask, 272K
context, tools and streaming checked live.

### Planner sub-agent

Each launch makes sure `~/.claude/agents/planner.md` and a short block in
`~/.claude/CLAUDE.md` exist (`shared/claude/install_planner.py`). The planner is
read-only and runs on the opus slot; the CLAUDE.md block tells the main session
to hand non-trivial planning to it. Plan mode stays off. Your own `planner.md`,
if you have one, is left alone. `CCL_PLANNER=off` skips the install, and
`--uninstall-planner` (Windows `-UninstallPlanner`) removes both again.

## Where the model list comes from

`shared/ire/ire_fetch.py` reads the IRE Top 20 from the private
`inference-recommendation-engine` repository each time a launcher starts. It
signs in with `GH_TOKEN`, `GITHUB_TOKEN` or `gh auth token`. If that fails, it
uses the last list it fetched, and if there is none yet, a built-in list. It
never stops a launch. The Mac launcher shows the fetched list in its picker;
Windows still shows its built-in table and passes the fetched one on as
`CCL_IRE_JSON`.

It also reads IRE's newer frontier list (stronger models with live route
prices, IRE PR #68) when it's there, and keeps it in the same answer. Both
pickers can seat from it: `f` at the Mac prompts, Tab on Windows. A `cx/` seat
goes through the proxy's Responses mode (`/v1/responses`), which is what those
routes ask for.

## What is where

| Folder | What it holds |
| --- | --- |
| `windows/` | The PowerShell launcher, and `litellm/` with the start and stop scripts |
| `mac/` | The Mac launcher, `setup.sh` (installs it and the `claude-acs` command), `stop-litellm.sh`, the folder navigation in `lib/`, and its tests |
| `shared/litellm/` | Proxy config, seat and merge scripts, fallback chains, pinned requirements |
| `shared/ire/` | The IRE fetch, its cache rules and its built-in defaults |
| `shared/integrations/` | `claude-env-exec.mjs`, which runs claude with the non-interactive launcher env for other tools |
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
- The routing scripts are copied from `litellm-ckff-ops` unchanged (now at
  `de69e68`). Changing them needs its own issue.

## Status

| Check | State |
| --- | --- |
| Windows launcher | Taken from the PC on 2026-10-03, with small path and key edits listed in `SOURCES.md`. Linted in CI; the edits have not been run on Windows yet. |
| Mac launcher | Unit tests and the dry run (installer, `claude-acs`, launcher) pass on Linux under bash 5 and bash 3.2.57. Not yet run on a Mac. |
| CI | `gates` (stack validators), `lint`, `mac-dry-run`, `bash 3.2 compatibility` and `python-tests` are required on every pull request. |
