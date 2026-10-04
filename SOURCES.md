# Where each file came from

Every file below was copied from somewhere else on 2026-10-03. The first commit
on the launcher branch adds them unchanged, so `git diff` against that commit
shows exactly what this repository changed. "Source SHA-256" is the hash of the
file as copied, before any edit here.

Source commits used:

- `litellm-ckff-ops`: `f04adc8a6140022ef0d2dbfea69be8e4e19ac2bd` (`main`, "add strict port 4000 protection"). The PC checkout at `D:\development\litellm-ckff-ops` was on the same commit with no tracked changes; its `.ps1` files differ from GitHub only by CRLF line endings.
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
- `Ensure-LiteLLMProxy` passes `-CkffEnvFile` and `-InferHubEnvFile` to the
  start script, and `Apply-InferHubSeat` sets `CLAUDE_IH_ENV_FILES` for the
  reload script.
- `HOOK(ire-models)` and `HOOK(fallback-ladder)` comments mark where later
  pull requests plug in.

`start-litellm.ps1` changes: paths moved to `shared\litellm`; env files come in
as parameters instead of the dead `D:\claude\inferhub\.env`; installs from the
pinned requirement files; `LITELLM_MASTER_KEY` is no longer required; Top 20
deployments are written from `top20-builtin.csv` when none exist; refuses a port
that is already listening; binds `--host 127.0.0.1`; records the LiteLLM PID in
`shared\litellm\logs\litellm.pid`.

`stop-litellm.ps1` was rewritten. The old one stopped every python or litellm
process whose path looked related and then killed whatever owned port 4000. The
new one stops only the PID in `litellm.pid`, and only if that process is this
repository's venv LiteLLM.

## Mac

| File here | Source repo | Source path | Commit | Source SHA-256 | Changed here |
| --- | --- | --- | --- | --- | --- |
| `mac/Launch Claude InferHub.command` | `Pukujan/agent-custom-setup` | `modules/claude-code/inferhub-litellm-macos/v0.1.0/Launch Claude InferHub.command` | `20f82f8` | `fc18ab6f20f5af2204b3d464f86ecc3fbfb4ca89b1cf09f16b6bf1f283d75d48` | yes |
| `mac/tests/dry_run.sh` | `Pukujan/agent-custom-setup` | `modules/claude-code/inferhub-litellm-macos/v0.1.0/tests/dry_run.sh` | `20f82f8` | `c7b1be1044ca1978b0c191e3f084078dcad2f93353faf52e5b42def9ca2ca55c` | rewritten |
| `mac/README.md` | `Pukujan/agent-custom-setup` | `modules/claude-code/inferhub-litellm-macos/v0.1.0/README.md` | `20f82f8` | `25a291beffd9a88f1f5d1a918ca36e40c38dbf990a0fdd16f6be403a1dff1ca4` | rewritten |
| `mac/NOTES.md` | `Pukujan/agent-custom-setup` | `modules/claude-code/inferhub-litellm-macos/v0.1.0/NOTES.md` | `20f82f8` | `d94bf80afbf08642691b9d3efe8af81a3f1b906438173b39e7bba43440df0de6` | new first section |

The Mac changes are listed at the top of `mac/NOTES.md`. `module.json` from the
ACS module was not copied; `SOURCES.md` replaces it.

## Shared proxy files

| File here | Source repo | Source path | Commit | Source SHA-256 | Changed here |
| --- | --- | --- | --- | --- | --- |
| `shared/litellm/config/config.yaml` | `Pukujan/litellm-ckff-ops` | `config/config.yaml` | `f04adc8` | `365d2f308e9e7cafdfc789390102563163a4fb874f9d4e8045cc2e9690bc2da7` | no |
| `shared/litellm/config/inferhub_fallbacks.yaml` | `Pukujan/litellm-ckff-ops` | `config/inferhub_fallbacks.yaml` | `f04adc8` | `b258eb03774a06a781df25a17144eae8bd97fe95b170ce185b5ccec98e12cec2` | no |
| `shared/litellm/scripts/apply_inferhub_seat.py` | `Pukujan/litellm-ckff-ops` | `scripts/apply_inferhub_seat.py` | `f04adc8` | `ca2734ce82448a1c84db89700b5155a56e210ec82502b5f1ae3559741585ac27` | no |
| `shared/litellm/scripts/merge_litellm_config.py` | `Pukujan/litellm-ckff-ops` | `scripts/merge_litellm_config.py` | `f04adc8` | `54d7dd8221a5f6b7ed09029d53506625d77ac0aecdb04dbbd65f5ef7db181d28` | no |
| `shared/litellm/scripts/reload_runtime.py` | `Pukujan/litellm-ckff-ops` | `scripts/reload_runtime.py` | `f04adc8` | `6d177c687e7509196162c0bc9eaf1c01fea42f0af70eaa876e96f563d7ebbfaa` | yes |
| `shared/litellm/scripts/sync_inferhub_top20.py` | `Pukujan/litellm-ckff-ops` | `scripts/sync_inferhub_top20.py` | `f04adc8` | `0f5a52d8706ef588d722d2bfd3d0bdcb7eb394b94833a372859be51b1aa66b64` | default CSV only |
| `shared/litellm/sitecustomize.py` | `Pukujan/litellm-ckff-ops` | `sitecustomize.py` | `f04adc8` | `d2cc86258b0fb223cd0d0ad9ec7d4c532d7b6da323e184f3f2dcad24e91ae85e` | reload auth, ladder scope |

`reload_runtime.py` and `sync_inferhub_top20.py` were not on the original list,
but `apply_inferhub_seat.py` and `merge_litellm_config.py` call the first, and
both launchers need the second to write the `ih/` deployments, so they came too.

The routing itself is untouched: `apply_inferhub_seat.py`,
`merge_litellm_config.py`, `config.yaml` and `inferhub_fallbacks.yaml` are
byte-for-byte the `f04adc8` files. The changes are elsewhere:

- `reload_runtime.py`: the env file list was a hardcoded Desktop path plus the
  dead `D:\claude\inferhub\.env`. It is now whatever the launcher puts in
  `CLAUDE_IH_ENV_FILES`, then the repository `.env`. With no master key it
  calls the reload endpoint without an `Authorization` header instead of
  skipping.
- `sync_inferhub_top20.py`: the default CSV was
  `D:\claude\inferhub\research_model_top20_recommendations.csv`. It is now
  `config/top20-builtin.csv`.
- `sitecustomize.py`: `/workbench/reload_runtime` used to require the master
  key. With a key set, it still does. With no key, it accepts requests from
  127.0.0.1 or ::1 only, whatever token they send. It also takes a `ladder`
  scope, which hands the launcher's fallback-ladder plan to
  `shared/ladder/proxy_apply.py` (issue #5).

Written here, not copied: `shared/litellm/requirements.txt` and
`requirements-overrides.txt` (pins from the working Windows venv, the same ones
the Mac port used), and `shared/litellm/config/top20-builtin.csv` (generated
from the Mac launcher's `MODELS` table, which matches the Windows `$Models`
table row for row).

## History

| File here | Source repo | Source path | Commit | Source SHA-256 | Changed here |
| --- | --- | --- | --- | --- | --- |
| `history/acs-inferhub-litellm-v0.2.0/launch-claude-inferhub.ps1` | `Pukujan/agent-custom-setup` | `modules/claude-code/inferhub-litellm/v0.2.0/launch-claude-inferhub.ps1` | `3a381eb` | `a7ec703390c0e83a639e1c0f391b58ba6e28b6bc12b32bc62ce78311f6d9ce2c` | no |
| `history/acs-inferhub-litellm-v0.2.0/launch-claude-inferhub.cmd` | `Pukujan/agent-custom-setup` | `modules/claude-code/inferhub-litellm/v0.2.0/launch-claude-inferhub.cmd` | `3a381eb` | `c80aab14488853a5bc51acb7afc121591d58232992b7da9f43382579ea03cc66` | no |
| `history/acs-inferhub-litellm-v0.2.0/NOTES.md` | `Pukujan/agent-custom-setup` | `modules/claude-code/inferhub-litellm/v0.2.0/NOTES.md` | `3a381eb` | `800d3ceca14bfb9e3e4b029548116c92dafa1b31a7f83264deea72eee95b9088` | no |
| `history/acs-inferhub-litellm-v0.2.0/module.json` | `Pukujan/agent-custom-setup` | `modules/claude-code/inferhub-litellm/v0.2.0/module.json` | `3a381eb` | `95ef8ef2bd3ff24c940558f8a8453588de4cc443d5a28f077fa2679ecb95f7fc` | no |

These are a record only. Nothing runs them, and lint and tests skip them.
