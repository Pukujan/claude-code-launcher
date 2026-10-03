# InferHub Claude Code for macOS: module notes (v0.1.0)

The user guide is [README.md](README.md). This file is for whoever maintains the
module: what was ported from where, what is deliberately the same as Windows,
what is different, and how it was tested.

## Source of truth

ACS is the source of truth, as for the Windows module
([`../../inferhub-litellm/v0.2.0/NOTES.md`](../../inferhub-litellm/v0.2.0/NOTES.md),
[`POLICY.md`](../../../../POLICY.md)). The Mac runs the launcher straight from an
ACS git checkout, or from the raw URL, so there is no separate deploy copy to
keep in sync.

The LiteLLM workbench (`Pukujan/litellm-ckff-ops`) stays its own repo. The
launcher clones it if it is missing and never edits its tracked files. It only
writes the files that repo already gitignores: `.litellm-venv/`, `logs/`, and
the generated `config/inferhub_*.yaml`, `config/inferhub_seat.json` and
`config/runtime.yaml`.

## Ported from

| Source | Revision | Used for |
| --- | --- | --- |
| `modules/claude-code/inferhub-litellm/v0.2.0/launch-claude-inferhub.ps1` | ACS `3a381eb` | Model table, pickers, env clearing, env vars, claude command, model-picker sync |
| Desktop deploy mirror of the same `.ps1` | written 2026-10-02 18:07 ET | Newer behaviour (see below) |
| litellm-ckff-ops `start-litellm.ps1` | `f04adc8` | Startup order, env names, `PYTHONPATH`/`PYTHONUTF8`/`LITELLM_LOCAL_MODEL_COST_MAP` |
| litellm-ckff-ops `scripts/apply_inferhub_seat.py`, `merge_litellm_config.py`, `reload_runtime.py`, `sync_inferhub_top20.py`, `config/inferhub_fallbacks.yaml` | `f04adc8` | Called unchanged |

litellm-ckff-ops `main` at `f04adc8` already has the startup fix (#34) and the
generated seat fallback chains (#37), so the launcher just needs `main`.

### The Desktop copy is ahead of ACS v0.2.0

The Windows launcher on the Desktop is a deploy mirror, but it is newer than the
ACS copy:

- the default project root is `C:\work`, listed first as the root itself and
  then its subfolders, with `D:\claude` kept as `[legacy]` entries (ACS v0.2.0
  only lists `D:\claude` subfolders)
- the health wait is 300 s (ACS v0.2.0 waits 180 s)
- it stops right away if `start-litellm.ps1` exits non-zero (ACS v0.2.0 waits
  for the whole timeout)

Everything else is the same: the model table, the defaults, the seat aliases and
the environment handling. The Mac port follows the newer behaviour, with
`~/work` playing the part of `C:\work` (the Mac has no legacy root). Bringing the
Desktop change back into ACS as `inferhub-litellm` v0.3.0 is a separate
follow-up and is not part of this module.

## Same as Windows (on purpose)

- **Model routing.** The "shim" that maps Claude Code's model names to InferHub
  seats is `apply_inferhub_seat.py`, and the launcher runs it unchanged:
  - `main`, `sonnet`, `claude-sonnet-5`, `ih-main`, `ih-sonnet` and
    `inferhub-sonnet` go to the main seat
  - `advisor`, `opus`, `claude-opus-5-5`, `claude-fable-5`, `claude-fable-5-1`,
    `ih-advisor`, `ih-opus` and `inferhub-opus` go to the advisor seat
  - with the advisor OFF, the advisor names go to the main seat

  The fallback chains, retry policy and cooldowns come from
  `merge_litellm_config.py` and `inferhub_fallbacks.yaml`, also unchanged.
- **Model picker.** The same 20 rows, names, ids, eligible/gated tags and
  costs. The main default is DeepSeek V4.1 Flash (`*`). The advisor default is
  OFF.
- **Environment for claude.** Everything in the Windows clear-list is unset,
  then anything matching `^(ANTHROPIC_|CLAUDE_CODE_|CKFF_|ckff_)`. Then:
  - `ANTHROPIC_API_KEY` is the LiteLLM master key
  - `ANTHROPIC_BASE_URL` is `http://127.0.0.1:4000`
  - `ANTHROPIC_MODEL` is `sonnet`
  - `ANTHROPIC_SMALL_FAST_MODEL` is `ih/ali/qwen3.8-flash`

  `ANTHROPIC_AUTH_TOKEN` is never set, and experimental betas stay on.
- **Command.** `claude --model sonnet --permission-mode bypassPermissions`, run
  in the chosen folder.
- **`~/.claude/settings.json`.** As on Windows, this is touched only if the file
  already exists. It gets the same `modelPicker` options, `model: sonnet` and
  `advisorModel: opus` (including the `behavesAs: claude-opus-4-6` value the
  Windows script writes).
- **Health check.** `/health/liveliness`, then `/health/readiness`, then
  `/health/liveness`. It waits up to 300 s and stops early if the process dies.

## Different from Windows (and why)

| Area | Windows | Mac | Why |
| --- | --- | --- | --- |
| Order | models, then folder, then proxy | proxy, then folder, then models | Alex's Mac brief. The seat is hot-reloaded into the running proxy (`/workbench/reload_runtime`, litellm-ckff-ops #30), so there is no restart. |
| Setup | manual (venv made by `start-litellm.ps1`) | first run installs uv, Python, the venv, Claude Code, and clones the workbench | single entry point |
| LiteLLM version | `litellm[proxy]` unpinned, then fastapi/starlette/sse-starlette downgraded with pip | `litellm[proxy]==1.103.0` + `pyyaml==6.0.3`, with uv overrides `fastapi==0.115.14`, `starlette==0.41.3`, `sse-starlette==2.1.3` | These are exactly the versions in the working Windows venv. LiteLLM 1.103.0 declares `starlette>=1.0.1`, so the downgrade has to be an override, the same thing Windows does with pip. |
| Bind address | `--port` only (LiteLLM defaults to all interfaces) | `--host 127.0.0.1 --port 4000` | Local-only proxy |
| Secrets | Desktop `configs\.env` plus `D:\claude\inferhub\.env` | `<workbench>/.env`, then `~/.config/inferhub/.env` (600) | Mac layout. The key is asked for once, with hidden input. |
| `LITELLM_MASTER_KEY` | must already be in the Desktop `.env` | made locally (`sk-local-` + 24 random bytes) if missing | Only used between claude and 127.0.0.1 |
| CKFF keys | required by `start-litellm.ps1` | optional; passed through if present | The Mac is InferHub-only. The CKFF model groups still load and only fail if someone calls them. |
| Top 20 deployments | `sync_inferhub_top20.py` reads `D:\claude\inferhub\research_model_top20_recommendations.csv` | the same script, given `INFERHUB_TOP20_CSV` or `~/.config/inferhub/research_model_top20_recommendations.csv` if present, otherwise a CSV built from the launcher's own Top 20 table | There is no IRE CSV on the Mac. The `ih/` names and ids match. Only `input_cost_per_token` is rounded to the table's 3 decimals, and that does not change routing because each `ih/` group has a single deployment. |
| Picker UI | arrow keys | numbered list, Return = default, `b` = Finder `choose folder` | Reliable under bash 3.2 |
| After claude exits | prints the exit code and waits for a key | `exec claude` (the Terminal window just shows the process ended) | Brief asked for `exec` |
| Stale port owner | n/a | if something is on the port but is not healthy, it stops and leaves that process alone | Never touches port 4000 processes |

## Logs and secrets

- Launcher log: `~/Library/Logs/claude-inferhub/launcher.log`. It holds every
  step and the output of every installer and script. No key values go in it
  (checked: the fake key never appeared in any log).
- LiteLLM logs: `<workbench>/logs/litellm.{out,err}.log`, plus `litellm.pid`.
- Keys are handed to LiteLLM through its environment and never on a command
  line, so they don't show up in `ps`.

## Test evidence (Linux box, 2026-10-03 ET; not a Mac)

- `shellcheck -s bash` (0.11.0): no findings on the launcher or
  `tests/dry_run.sh`.
- `bash -n` passes on GNU bash 5.2.37 and on GNU bash 3.2.57 built from source
  (the same version macOS ships).
- `tests/dry_run.sh <litellm-ckff-ops checkout> 4110 <bash-3.2.57>` printed
  `DRY RUN: PASS`. That run used a mock claude, a real LiteLLM 1.103.0 on
  127.0.0.1:4110, folder 3, main 2 (GLM 5.3 Flash) and advisor 10 (MiniMax M3).
  The mock received:
  - argv `--model sonnet --permission-mode bypassPermissions`
  - cwd = the chosen folder
  - exactly the four `ANTHROPIC_*` vars, with the injected
    `ANTHROPIC_AUTH_TOKEN`, `CKFF_DEFAULT_KEY`, `ckff_api_url`,
    `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_DEFAULT_OPUS_MODEL` all cleared

  The env file was mode 600 and no key turned up in the logs.
- End to end through the proxy, with `INFERHUB_API_URL` pointed at a local mock
  upstream: `claude-sonnet-5`, `sonnet` and `main` reached the upstream as
  `cbcn/glm-5.3-flash`. `claude-opus-5-5`, `opus` and `advisor` reached it as
  `cbcn/minimax-m3`. `ih/ali/qwen3.8-flash` reached it as `ali/qwen3.8-flash`.
  Every request carried the InferHub key. The seat was hot-reloaded into the
  already-running proxy (`Reloaded scope=seat updated=14`).
- Second run: no installs, about 5 s to reach the pickers. Return at every
  prompt gave the root folder, DeepSeek V4.1 Flash and advisor OFF.
- Fail-fast paths each ended with a clear `ERROR:` line and the log path:
  - port taken by a process that isn't LiteLLM
  - LiteLLM exits during startup
  - health timeout
  - empty key (nothing written)
  - unknown model override
- First run on a clean HOME installed Claude Code with the real official
  installer (`~/.local/bin/claude`). The uv official installer, run with the
  launcher's flags, installed into `~/.local/bin` and left shell profiles
  alone.
- Not exercised on Linux: `osascript` (Finder picker), `xcode-select`, the
  Homebrew and nodejs.org Node fallback. The nodejs.org `latest-v24.x`
  `SHASUMS256.txt` lookup was checked and does list the darwin-arm64 and
  darwin-x64 tarballs.
