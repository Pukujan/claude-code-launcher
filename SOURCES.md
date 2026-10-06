# Where each file came from

Every file below was copied from somewhere else on 2026-10-03. The first commit
on the launcher branch adds them unchanged, so `git diff` against that commit
shows exactly what this repository changed. "Source SHA-256" is the hash of the
file as copied, before any edit here.

Source commits used:

- `litellm-ckff-ops`: `f04adc8a6140022ef0d2dbfea69be8e4e19ac2bd` (`main`, "add strict port 4000 protection") for the first copy. The PC checkout at `D:\development\litellm-ckff-ops` was on the same commit with no tracked changes; its `.ps1` files differ from GitHub only by CRLF line endings.
- `litellm-ckff-ops` again at `de69e68960eda867a784d751a3506e47f5110547` (PR #42, keyless 127.0.0.1 mode) for the shared proxy files, re-synced on 2026-10-03 in issue #11. See "Shared proxy files".
- This repository's own `macos/` folder at `b6a7f29` (PR #7) and `d197b4e` (PR #9), folded into `mac/` and deleted in issue #11. See "Mac".
- `agent-custom-setup` PR #65: head `20f82f853240e19da136ea9ed1df555f85631cd4` on `task/ACS-0008-macos-launcher` (still open when copied).
- `agent-custom-setup` `main`: `3a381eba11c6262c702f5d696878c371342e859a`.
- The PC launcher is not in git. Its commit column says `none (PC file)` and the hash identifies it.

## Windows

| File here | Source repo | Source path | Commit | Source SHA-256 | Changed here |
| --- | --- | --- | --- | --- | --- |
| `windows/launch-claude-inferhub.ps1` | Teresa-Pujan (PC) | `C:\Users\pujan\OneDrive\Desktop\configs\claude-code\launch-claude-inferhub.ps1`, written 2026-10-03 7:21 PM ET | none (PC file), taken at `9bf23ea` | `9bf23ea04522c73414bffce17e4b86a5766431691642848c7f18a988a843028a` | yes, see below |
| `windows/launch-claude-inferhub.cmd` | Teresa-Pujan (PC) | `C:\Users\pujan\OneDrive\Desktop\configs\claude-code\launch-claude-inferhub.cmd` | none (PC file), taken at `c80aab1` | `c80aab14488853a5bc51acb7afc121591d58232992b7da9f43382579ea03cc66` | no |
| `windows/litellm/start-litellm.ps1` | `Pukujan/litellm-ckff-ops` | `start-litellm.ps1` | `f04adc8` | `20521a68655b6b83e43273f78a168f6f853a353880d3cb09cdfe146cbaa0d889` | yes |
| `windows/litellm/stop-litellm.ps1` | `Pukujan/litellm-ckff-ops` | `stop-litellm.ps1` | `f04adc8` | `41cf244f85fb9ea8b12369ba4d790bf85099301576cb64e1aa44fb4d4d7cf1fd` | rewritten |

The PC launcher is expected to change again (another worker may fix it within
the hour), so it will be re-synced. To re-sync: copy the new PC file over the
first-commit version, then re-apply the edits listed here. They are small on
purpose:

- `$LiteLLMRoot` now points at `shared\litellm` in this checkout, and the start
  and stop scripts are found in `windows\litellm`.
- The repository `.env` candidate is the repo root, not the old workbench.
- `Read-LiteLLMMasterKey` returns a set `LITELLM_MASTER_KEY` or the dummy
  `local`; it no longer throws.
- The seat file fallback is written as UTF-8 without a BOM.
- `Ensure-LiteLLMProxy` passes `-DesktopEnvFile` (was `-CkffEnvFile`, CKFF
  off since 2026-10-04) and `-InferHubEnvFile` to the
  start script, and `Apply-InferHubSeat` sets `CLAUDE_IH_ENV_FILES` for the
  reload script.
- `HOOK(ire-models)` and `HOOK(fallback-ladder)` comments mark where later
  pull requests plug in.
- `ANTHROPIC_SMALL_FAST_MODEL` is `small-fast`, the fast seat alias, instead
  of `ih/ali/qwen3.8-flash` (issue #11).

`start-litellm.ps1` changes: paths moved to `shared\litellm`; env files come in
as parameters instead of the dead `D:\claude\inferhub\.env`; installs from the
pinned requirement files; `LITELLM_MASTER_KEY` is no longer required; Top 20
deployments are written from `top20-builtin.csv` when none exist; refuses a port
that is already listening; binds `--host 127.0.0.1`; records the LiteLLM PID in
`shared\litellm\logs\litellm.pid`. Since issue #11 it also sets
`LITELLM_DANGEROUSLY_PERMIT_WEAK_OR_UNSET_MASTER_KEY=true` in its own process
when no `LITELLM_MASTER_KEY` is set, as litellm-ckff-ops `de69e68` does.

Since issue #24 the desktop env default comes from the Desktop known folder
instead of a hardcoded user path, a missing desktop env prints a note instead
of stopping the script, and the venv is made and filled with uv (`uv venv`,
then `uv pip install --override`), falling back to `python -m venv` and pip
only when uv is not installed. The launcher picks the first desktop env that
exists of the Desktop known folder, `%USERPROFILE%\Desktop` and
`%OneDrive%\Desktop`, and looks for the IRE `.env` next to this checkout
before `D:\development`.

Since issue #64 both scripts treat the repository's `.env` as the one key file
when it exists: the launcher passes it as both env files, `start-litellm.ps1`
loads it alone (label `launcher`) and skips the desktop and IRE files, which are
only a fallback when it is missing. `-ShowEnvSources` prints the files read and
the key names set, then exits. Packaged mode is unchanged.

Since issue #51 it also loads an optional machine-local `shared\litellm\.env.local`
(`-LocalEnvFile`, gitignored) after the two env files, forwards it in
`-Background` mode, and applies `CCL_ENV_ALIASES` (copies an already-loaded
value to the name LiteLLM reads, printing names only).

`stop-litellm.ps1` was rewritten. The old one stopped every python or litellm
process whose path looked related and then killed whatever owned port 4000. The
new one stops only the PID in `litellm.pid`, and only if that process is this
repository's venv LiteLLM.

Issue #61 (the one-command Windows installer, `windows/install.ps1`, written
here, not copied) added a packaged mode to both copied scripts. The launcher
notices an install folder (`CCL_HOME`, or `install.json` above the repository)
and then reads the key, port, venv, logs and picks from there, skips every
PC-specific path, checks `/ccl/identity` before trusting a proxy, and syncs
`settings.json` through `shared/claude/settings_sync.py`. `start-litellm.ps1`
takes `-CclHome` for the same layout and creates its venv with Python 3.12.
Without an install folder both behave as before. See
`docs/specs/windows-package.md`.

## Mac

| File here | Source repo | Source path | Commit | Source SHA-256 | Changed here |
| --- | --- | --- | --- | --- | --- |
| `mac/Launch Claude InferHub.command` | `Pukujan/agent-custom-setup` | `modules/claude-code/inferhub-litellm-macos/v0.1.0/Launch Claude InferHub.command` | `20f82f8` | `fc18ab6f20f5af2204b3d464f86ecc3fbfb4ca89b1cf09f16b6bf1f283d75d48` | yes |
| `mac/tests/dry_run.sh` | `Pukujan/agent-custom-setup` | `modules/claude-code/inferhub-litellm-macos/v0.1.0/tests/dry_run.sh` | `20f82f8` | `c7b1be1044ca1978b0c191e3f084078dcad2f93353faf52e5b42def9ca2ca55c` | rewritten |
| `mac/README.md` | `Pukujan/agent-custom-setup` | `modules/claude-code/inferhub-litellm-macos/v0.1.0/README.md` | `20f82f8` | `25a291beffd9a88f1f5d1a918ca36e40c38dbf990a0fdd16f6be403a1dff1ca4` | rewritten |
| `mac/NOTES.md` | `Pukujan/agent-custom-setup` | `modules/claude-code/inferhub-litellm-macos/v0.1.0/NOTES.md` | `20f82f8` | `d94bf80afbf08642691b9d3efe8af81a3f1b906438173b39e7bba43440df0de6` | new first section |
| `mac/lib/nav.sh` | this repository | `macos/launch-claude-inferhub.sh` (the terminal UI and folder functions) | `b6a7f29` | `d827ef9e13874ba68e2b8695c5e0467be662500211b021b9ff2f4ac79557389a` | yes |
| `mac/setup.sh` | this repository | `macos/setup.sh` | `b6a7f29` | `04088aef767c2a97ec2a269c09a8d5accc5f1f0aa8624fdb58b5b4e2d4580bf2` | rewritten |
| `mac/stop-litellm.sh` | written here | (`macos/proxy/stop-litellm.sh` did the same job for `~/litellm`) | | | new |
| `mac/tests/unit_tests.sh` | this repository | `macos/tests/run-tests.sh` and `macos/tests/nav-tests.sh` | `b6a7f29` | `0eea7385c1cdfcaeef8885500f9e6b44a900c1f70070c16ac1b8f8fc50eb1ee6`, `a751c1f87d0649ed6edd0e77f133a64998511d135e00e1dfe0db5b6b09bc3a0b` | rewritten |

The Mac changes are listed at the top of `mac/NOTES.md`. `module.json` from the
ACS module was not copied; `SOURCES.md` replaces it.

### What came over from `macos/` (issue #11)

`macos/` (PR #7, then PR #9) was a second Mac launcher with its own proxy copy
under `~/litellm`. It is gone; these parts now live in `mac/`:

- **Folder navigation** (`mac/lib/nav.sh`): the arrow-key browser, quick
  picks, recent folders, new folder and the helpers they need, taken from
  `macos/launch-claude-inferhub.sh`. Changes: `s` picks the folder you are in
  (the old browser had no way to finish), the new-folder name is read from the
  terminal, `~/Documents/secrets` is no longer a quick pick, and the quick
  picks use `~/work` instead of `~/claude`. The numbered menu in the launcher
  calls these as `b`, `q`, `t` and `n`, and lists recent folders.
- **Installer** (`mac/setup.sh`): same three modes (install, `--check`,
  `--uninstall`) and the same `claude-acs` command. It no longer downloads
  scripts from raw.githubusercontent.com (that can't work, because the
  repository is private) or installs a second LiteLLM under `~/litellm`. It runs
  the launcher in setup-only mode and writes `claude-acs` pointing at this
  checkout. It also no longer runs `npm install` once per Node prefix, because
  the launcher installs Claude Code with Anthropic's installer into
  `~/.local/bin`, which works whichever Node the shell picks.
- **Live model table**: `macos/ire_live_models.py` fetched IRE from
  raw.githubusercontent.com with no token. IRE is private, so that always fell
  back to its cache. The launcher now gets the table from
  `shared/ire/ire_fetch.py` (PR #10), which authenticates.
- **Not kept**: `macos/proxy/apply_seat.py` (its own seat format and, after
  PR #9, vendor-fallback deployments; seats now go through
  the shared `apply_inferhub_seat.py` like Windows), the `~/litellm`
  start and stop scripts, the hardcoded table in `launch-claude-inferhub.sh`,
  and the `macos-shim.yml` workflow (its bash 3.2 job now lives in
  `launcher-ci.yml`).

## Shared proxy files

| File here | Source repo | Source path | Commit | Source SHA-256 | Changed here |
| --- | --- | --- | --- | --- | --- |
| `shared/litellm/config/config.yaml` | `Pukujan/litellm-ckff-ops` | `config/config.yaml` | `de69e68` | `365d2f308e9e7cafdfc789390102563163a4fb874f9d4e8045cc2e9690bc2da7` | no |
| `shared/litellm/config/inferhub_fallbacks.yaml` | `Pukujan/litellm-ckff-ops` | `config/inferhub_fallbacks.yaml` | `de69e68` | `b258eb03774a06a781df25a17144eae8bd97fe95b170ce185b5ccec98e12cec2` | no |
| `shared/litellm/scripts/apply_inferhub_seat.py` | `Pukujan/litellm-ckff-ops` | `scripts/apply_inferhub_seat.py` | `de69e68` | `6bba74f851e6ab729c368c24d711b5792342e1b93cd8a48e4d0d00013dd5a37e` | cx Responses mode (`litellm_model()`) |
| `shared/litellm/scripts/merge_litellm_config.py` | `Pukujan/litellm-ckff-ops` | `scripts/merge_litellm_config.py` | `de69e68` | `b77190bb7060c57fbb567bd8fd22af321fa2740add5c566e9b9cff625a1871e2` | strips `openai/responses/` too |
| `shared/litellm/sitecustomize.py` | `Pukujan/litellm-ckff-ops` | `sitecustomize.py` | `de69e68` | `bf627afc9bc610ecea7d633a62fb34c9145e3076efaf969be22a1ea47651d8d3` | ladder scope |
| `shared/litellm/scripts/reload_runtime.py` | `Pukujan/litellm-ckff-ops` | `scripts/reload_runtime.py` | `f04adc8` | `6d177c687e7509196162c0bc9eaf1c01fea42f0af70eaa876e96f563d7ebbfaa` | yes; checked against `de69e68` (`d858f9a9…`), kept |
| `shared/litellm/scripts/sync_inferhub_top20.py` | `Pukujan/litellm-ckff-ops` | `scripts/sync_inferhub_top20.py` | `f04adc8` | `0f5a52d8706ef588d722d2bfd3d0bdcb7eb394b94833a372859be51b1aa66b64` | default CSV only; price read/write ported from `fcc2de7` (`5235de06…`); checked against `de69e68` (`0254c188…`), kept |

**CKFF off (litellm-ckff-ops PR #44, `768c9df`).** `scripts/provider_switch.py`
and `config/providers.yaml` are copied unchanged from `768c9df`, except that
`is_ckff_deployment()` also counts lower-case `ckff*` key names (`ckff_astra`).
`merge_litellm_config.py` (no CKFF deployments, `prune_router_refs()`),
`apply_inferhub_seat.py` (`claude-haiku-4-5` to the fast seat while CKFF is
off), `inferhub_fallbacks.yaml` (`claude-haiku-4-5` in the fast role) and
`sitecustomize.py` (`claude-haiku-4-5` in the seat aliases) take the same
change on top of the local edits; our fast seat pins are kept.
`start-litellm.ps1` takes the same switch, but with CKFF off it still reads
the desktop env without its `ckff*` names (the web search keys live there).

`reload_runtime.py` and `sync_inferhub_top20.py` were not on the original list,
but `apply_inferhub_seat.py` and `merge_litellm_config.py` call the first, and
both launchers need the second to write the `ih/` deployments, so they came too.

**Re-sync to `de69e68` (PR #42, issue #11).** `config.yaml` and
`inferhub_fallbacks.yaml` are byte-for-byte the `de69e68` versions;
`apply_inferhub_seat.py`, `merge_litellm_config.py` and `sitecustomize.py` are
the `de69e68` versions plus the small local edits listed below. What `de69e68`
brings in:

- `apply_inferhub_seat.py`: the fast seat. `haiku`, `claude-haiku-5`,
  `claude-haiku-4-5-20251001`, `small-fast`, `ih-haiku`, `ih-small-fast` and `inferhub-haiku` go to
  `ali/qwen3.8-flash` by default (`--fast`, or `fast_inferhub_id` in the seat
  file; empty means the main seat). `claude-haiku-4-5` stays with CKFF. The seat
  file is read as `utf-8-sig`, so the BOM Windows PowerShell 5.1 writes no
  longer breaks it. `cx/gpt-6.1-sol` is allowed as an opt-in seat and only
  prints a note.
- `merge_litellm_config.py`: with no `LITELLM_MASTER_KEY`, `runtime.yaml` gets
  no `master_key` at all, instead of a reference to an empty variable.
- `sitecustomize.py`: upstream now has the same keyless rule this repository
  had added (no key: only 127.0.0.1 or ::1 may call
  `/workbench/reload_runtime`; with a key the token must match, compared in
  constant time), and it reports `haiku` after a reload. The local auth edit
  is no longer needed.
- `config.yaml` and `inferhub_fallbacks.yaml` didn't change upstream.

Not taken from `de69e68`:

- `reload_runtime.py` there finds env files through a new
  `scripts/local_paths.py` with PC defaults (`D:\development\...`). Here the
  launchers pass `CLAUDE_IH_ENV_FILES`, then the repository `.env`, so the
  local version stays. Both send no `Authorization` header when there is no
  key.
- `sync_inferhub_top20.py` there reads IRE from a local clone or `gh api`. Here
  `shared/ire/ire_fetch.py` does that and writes `config/top20.csv`, so the
  local version (default CSV only) stays.
- `start-litellm.ps1` and `stop-litellm.ps1` there: `windows/litellm/` already
  has its own keyless start and PID-only stop. The one thing ported is the
  `LITELLM_DANGEROUSLY_PERMIT_WEAK_OR_UNSET_MASTER_KEY=true` flag, set for the
  proxy process only and only with no key. LiteLLM 1.104 needs it to start
  keyless. The pinned 1.103.0 doesn't read it (no reference in the installed
  package) and starts keyless without it; the flag is there for the next bump.

Local edits kept on top of `de69e68` (diff against upstream shows only these):

- `apply_inferhub_seat.py`: `litellm_model()` seats `cx/` routes as
  `openai/responses/cx/...`, so they go through LiteLLM's Responses mode
  (issue #13). Every other route is written exactly as upstream writes it;
  `tests/fixtures/seat/` holds output from the unmodified `de69e68` script.
- `merge_litellm_config.py`: strips `openai/responses/` as well as `openai/`
  when it reads seat targets back.
- `sitecustomize.py`: the `ladder` scope on `/workbench/reload_runtime`, which
  hands the launcher's fallback-ladder plan to `shared/ladder/proxy_apply.py`
  (issue #5).
  It also loads `bench_after_retries.py` on the first request (issue #21, see
  below).
- `reload_runtime.py` (kept from `f04adc8`): the env file list is whatever the
  launcher puts in `CLAUDE_IH_ENV_FILES`, then the repository `.env`, instead
  of a hardcoded Desktop path. With no master key it calls the reload endpoint
  without an `Authorization` header.
- `sync_inferhub_top20.py` (kept from `f04adc8`): the default CSV is
  `config/top20-builtin.csv`. The price read and write are the `fcc2de7`
  version (IRE #94): the row's `best_route_min_ask_in/out_usdc_per_1m` are read
  first and both `input_cost_per_token` and `output_cost_per_token` are
  written, with the supply blend as the fallback for a CSV that predates the
  ask columns. Nothing else reads these fields: the role fallbacks come from
  `inferhub_fallbacks.yaml`'s own `models:` block (vendor/cost/eligible), and
  the generated file is used only for the `model_name` to route map, so the
  fallback chains are untouched.

Written here, not copied: `shared/litellm/bench_after_retries.py`, which
benches a seat or rung once it has used up its retries. LiteLLM 1.103.0's own
allowed-fails counter can't do that on the proxy, because it counts all the
retries of one request as a single failure.
`shared/litellm/requirements.txt` and
`requirements-overrides.txt` (pins from the working Windows venv, the same ones
the Mac port used), and `shared/litellm/config/top20-builtin.csv` (generated
from the Mac launcher's `MODELS` table, which matches the Windows `$Models`
table row for row).

## IRE

`shared/ire/ire_fetch.py` reads these from the private
`Pukujan/inference-recommendation-engine` at run time; none of them are copied
here. The frontier files were added by IRE PR #68 (`9a8fba0`) and are optional:
the bundle's `frontier` key uses the JSON if it's there, else the routes CSV
(eligibility from the recommendations CSV when it can be read), else the
recommendations CSV alone, else stays empty. None of them can change the Top 20.

| What | IRE path | Since |
| --- | --- | --- |
| Top 20 | `operational/telemetry/gravebuster/pipeline/ihub/lists/research_model_top20_recommendations.csv` | PR #10 here |
| Price policy | `docs/INFERHUB-API-SETUP.md` | PR #10 here |
| Fallback picks (optional) | `operational/recommendations/claude-code-fallbacks.v1.json` | PR #10 here |
| Frontier models (optional) | `operational/telemetry/gravebuster/pipeline/ihub/lists/research_model_frontier_recommendations.csv` and `.json` | issue #11 |
| Frontier routes (optional) | `operational/telemetry/gravebuster/pipeline/ihub/lists/research_model_frontier_routes.csv` | issue #11 |

The test fixture `tests/fixtures/ire/frontier_recommendations.csv` (header and
2 rows) is cut from the `9a8fba0` file. `frontier.json` and `frontier_routes.csv`
next to it are small hand-written samples in the same shape (issue #13).

## History

| File here | Source repo | Source path | Commit | Source SHA-256 | Changed here |
| --- | --- | --- | --- | --- | --- |
| `history/acs-inferhub-litellm-v0.2.0/launch-claude-inferhub.ps1` | `Pukujan/agent-custom-setup` | `modules/claude-code/inferhub-litellm/v0.2.0/launch-claude-inferhub.ps1` | `3a381eb` | `a7ec703390c0e83a639e1c0f391b58ba6e28b6bc12b32bc62ce78311f6d9ce2c` | no |
| `history/acs-inferhub-litellm-v0.2.0/launch-claude-inferhub.cmd` | `Pukujan/agent-custom-setup` | `modules/claude-code/inferhub-litellm/v0.2.0/launch-claude-inferhub.cmd` | `3a381eb` | `c80aab14488853a5bc51acb7afc121591d58232992b7da9f43382579ea03cc66` | no |
| `history/acs-inferhub-litellm-v0.2.0/NOTES.md` | `Pukujan/agent-custom-setup` | `modules/claude-code/inferhub-litellm/v0.2.0/NOTES.md` | `3a381eb` | `800d3ceca14bfb9e3e4b029548116c92dafa1b31a7f83264deea72eee95b9088` | no |
| `history/acs-inferhub-litellm-v0.2.0/module.json` | `Pukujan/agent-custom-setup` | `modules/claude-code/inferhub-litellm/v0.2.0/module.json` | `3a381eb` | `95ef8ef2bd3ff24c940558f8a8453588de4cc443d5a28f077fa2679ecb95f7fc` | no |

These are a record only. Nothing runs them, and lint and tests skip them.
