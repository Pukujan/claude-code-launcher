# Spec: one-command Windows installer

Status: accepted for build (issue [#61](https://github.com/Pukujan/claude-code-launcher/issues/61), task CCL-0061).
Version this spec describes: `v1.0.0-windows`.

## Problem

Alex wants a friend to get his Claude Code setup on Windows (the LiteLLM proxy, the slot
chains, the IRE model list, the Claude Code config) by running one command. The only thing
the friend should need is his own InferHub API key. Today there's no installer. The launcher
expects a checkout, Claude Code and uv already installed, it hard-codes port 4000, it treats
any proxy on 4000 as its own, and it looks in places that only exist on Alex's PC.

## Shape

A single PowerShell script, `windows/install.ps1`, attached to the GitHub release
`v1.0.0-windows`. There's no zip. The script fetches the launcher files for its own tagged
version, does the setup, and leaves a `claude-inferhub` command on the user's PATH.

Main path (the repo is public):

```powershell
irm https://github.com/Pukujan/claude-code-launcher/releases/download/v1.0.0-windows/install.ps1 | iex
```

With parameters:

```powershell
& ([scriptblock]::Create((irm https://github.com/Pukujan/claude-code-launcher/releases/download/v1.0.0-windows/install.ps1))) -InferHubKey <key>
```

Download-and-run also works (`powershell -ExecutionPolicy Bypass -File .\install.ps1`). If the
repo ever goes private again, `gh release download v1.0.0-windows -R Pukujan/claude-code-launcher -p install.ps1`
gets the script, and the installer fetches the source through `gh` when it's logged in.

## Inputs

### `install.ps1` parameters (stable interface)

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `-InferHubKey` | string | none | The InferHub API key. Wins over every other source. |
| `-InstallDir` | path | `$env:CCL_INSTALL_DIR`, else `%LOCALAPPDATA%\claude-code-launcher` | Where everything goes. |
| `-Ref` | string | `v1.0.0-windows` | Git tag or branch of the launcher files to fetch. |
| `-Source` | path | none | Use this local checkout instead of fetching (tests, offline). |
| `-StartPort` | int | `4000` | First port tried for the proxy. |
| `-Uninstall` | switch | off | Remove the install (see Uninstall). |
| `-ChangeKey` | switch | off | Replace the stored key only, then restart the proxy if it runs. |
| `-SkipPrereqs` | switch | off | Only check uv, git, Node, pnpm and Claude Code and warn about missing ones; never install them. |
| `-SkipVenv` | switch | off | Don't build the LiteLLM venv (tests). |
| `-NoTask` | switch | off | Don't register the logon task. |
| `-NoPath` | switch | off | Don't add `bin\` to the user PATH. |
| `-NoStart` | switch | off | Don't start the proxy at the end. |
| `-NonInteractive` | switch | off | Never prompt. A missing key is an error (exit 4). |

### Environment variables

| Name | Meaning |
|---|---|
| `CCL_INFERHUB_KEY` | The key, when `-InferHubKey` isn't given. |
| `INFERHUB_API_KEY` | The key, when neither of the above is set. |
| `CCL_INSTALL_DIR` | Default for `-InstallDir`. |
| `CCL_INSTALL_LIBRARY_ONLY` | `1` = define the functions and return without doing anything (tests). |
| `CCL_HOME` | Set by the `claude-inferhub` shim to the install folder; makes the launcher run in packaged mode. |

Key precedence: `-InferHubKey`, then `CCL_INFERHUB_KEY`, then `INFERHUB_API_KEY`, then the
key already stored by an earlier install, then a masked prompt (`Read-Host -AsSecureString`).
A key is trimmed. It must be non-empty, at most 4096 characters, and contain no CR, LF, NUL
or double quote. Anything else is rejected with exit 2 and a message that doesn't echo the key.

## Outputs

### Install folder layout (`InstallDir`)

| Path | What |
|---|---|
| `app\` | The launcher files at `-Ref` (replaced on every install). |
| `install.json` | Install state (schema below). |
| `secrets\inferhub.env` | One line, `INFERHUB_API_KEY=<key>`, UTF-8 without BOM. ACL limited to the current user on Windows. |
| `state\last-picks.json` | The saved slot picks and the default start folder. |
| `state\local.env` | Optional per-user proxy settings (e.g. `TINYFISH_API_KEY`). Never created by the installer, never removed by a reinstall. |
| `venv\` | The LiteLLM venv, built with `uv venv --python 3.12` and the pinned requirements. |
| `logs\` | Proxy logs and PID file. |
| `bin\claude-inferhub.cmd` | The launch command. `bin\` is added to the user PATH once. |

`install.json` (schema `claude-code-launcher.install.v1`):

```json
{
  "schema": "claude-code-launcher.install.v1",
  "version": "1.0.0-windows",
  "ref": "v1.0.0-windows",
  "port": 4000,
  "instance_id": "<32 hex chars, made once and kept across reinstalls>",
  "task_name": "claude-code-launcher-proxy",
  "claude_settings_created": false
}
```

Nothing else in `install.json`. It never holds the key.

### `claude-inferhub` command

`claude-inferhub [launcher options] [-- claude args]` runs
`app\windows\launch-claude-inferhub.ps1` with `CCL_HOME` set. Extra verbs:

| Command | Does |
|---|---|
| `claude-inferhub --set-key` | Runs `install.ps1 -ChangeKey` against this install (prompt, flag or env as above). |
| `claude-inferhub --uninstall` | Runs `install.ps1 -Uninstall` against this install. |
| `claude-inferhub --non-interactive ...` | The launcher's existing non-interactive mode (Paseo, scripts). |

### Logon task

`claude-code-launcher-proxy`, a per-user logon task that runs
`conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File app\windows\litellm\start-litellm.ps1 -Home <InstallDir> -Port <port>`.
No window shows. It's re-registered whenever the port changes.

## Behavior

### Install (also re-install)

1. Check for uv, git, Node, pnpm and `claude`. Install what's missing unless `-SkipPrereqs`:
   uv from its official installer, git and Node LTS through winget, pnpm through
   corepack (falling back to its official installer), Claude Code through its official
   installer (`https://claude.ai/install.ps1`). Installers are downloaded to a temp file and
   run with `powershell -File`, never piped into `iex`. Prerequisites are never uninstalled.
2. Fetch the launcher files for `-Ref` into `app\`. Order: `-Source`, then the public tarball
   (`codeload.github.com`), then `gh api .../tarball/<ref>` when gh is logged in, then
   `git clone --depth 1 --branch <ref>`. Exit 5 if all of them fail.
3. Resolve and store the key (precedence above).
4. Build the venv unless `-SkipVenv`. Exit 6 if that fails.
5. Pick the port (below) and write `install.json`, keeping the existing `instance_id`.
6. Write `bin\claude-inferhub.cmd`, add `bin\` to the user PATH once (unless `-NoPath`).
7. Create Claude Code's `settings.json` if it's missing, and merge `advisorModel: "fable"`,
   `model: "sonnet"` and the `modelPicker` options into it (below). Install the planner
   sub-agent.
8. Register the logon task (unless `-NoTask`) and start the proxy (unless `-NoStart`), then
   wait until the proxy on the chosen port answers as ours.

Running install twice leaves the same state as running it once.

### Port choice and "is it ours"

The proxy answers `GET /ccl/identity` (loopback only) with
`{"app": "claude-code-launcher", "instance": "<CCL_INSTANCE_ID or empty>"}`.

A port's state is one of:

- `free`: nothing listens and 127.0.0.1:<port> can be bound.
- `ours`: something listens and `/ccl/identity` returns our app name and this install's `instance_id`.
- `foreign`: anything else listening (another LiteLLM, any other program).

`Select-CclPort -Start <int> -Saved <int> -Probe <scriptblock> [-Count 100]` returns the saved port
if its state is `free` or `ours`. Otherwise it returns the lowest port in `Start..Start+Count-1`
whose state is `free` or `ours`, and throws if there's none. It never returns a `foreign` port.
The launcher runs it on every packaged launch, so if another program takes our port later, it
moves to a new free port, saves it, re-registers the task and points Claude at it.

`ANTHROPIC_BASE_URL` is always `http://127.0.0.1:<chosen port>`.

### Packaged mode vs Alex's own setup

Packaged mode is on when `CCL_HOME` is set, or `install.json` sits in the folder above the
launcher's repo root. In packaged mode:

- The only env files read are `secrets\inferhub.env` and `state\local.env` (if present).
  No Desktop `configs\.env`, no `inference-recommendation-engine\.env`, no `D:\development`,
  no `C:\work`, no `shared\litellm\.env.local`, and no `CCL_ENV_ALIASES` default.
- The folder picker starts at the saved start folder, else the user's home.
- The venv, logs and picks live under `InstallDir`.
- The proxy health check requires `ours`, not just a live `/health` answer.

`Get-CclLaunchConfig` (in `launch-claude-inferhub.ps1`) returns this resolved configuration as a
hashtable: `Packaged`, `Home`, `Port`, `EnvFiles`, `ProjectRoots`, `StartDir`, `LastPicks`,
`VenvDir`, `LogDir`, `InstanceId`. In packaged mode no value in it contains `D:\`, `C:\work`,
`Desktop`, `inference-recommendation-engine`, `.env.local` or `pujan`.

Without packaged mode, everything behaves as before this change: port 4000, the old env file
order, `D:\development` and `C:\work` in the folder list, `.env.local` and `CCL_ENV_ALIASES`.
The folder picker falls back to home when `D:\development` doesn't exist.

### Claude Code settings

`shared/claude/settings_sync.py`:

- `sync(settings: dict, options: list) -> dict` returns a copy with `model = "sonnet"`,
  `advisorModel = "fable"` and `modelPicker = {"options": options}`. Every other key is kept
  as is. `sync(sync(s, o), o) == sync(s, o)`.
- `unsync(settings: dict) -> dict` removes `modelPicker` when every option's description says
  "via local LiteLLM" or "InferHub", removes `advisorModel` when it's `"fable"` and `model` when
  it's `"sonnet"`. Everything else is kept.
- CLI: `python settings_sync.py sync|unsync --settings PATH [--options-file FILE]`. `sync`
  creates the file (and its folder) when missing and prints `created` or `updated` or
  `unchanged` on stderr. A settings file that isn't valid JSON is left untouched (exit 1).
  The folder is `CLAUDE_CONFIG_DIR` when set, else `~/.claude`.

The launcher calls `sync` on every interactive launch and in non-interactive mode (including
`--print-env`, which is what Paseo uses), with nothing written to stdout.

### Web search

`web_search.chain_from_env(env)`: when `CCL_WEB_SEARCH_CHAIN` is unset or blank, the chain is
`tinyfish` (only when `TINYFISH_API_KEY` is non-blank), then `ddgs`, then `you_com`. An explicit
chain is used as given (aliases mapped, `duckduckgo` dropped, `["ddgs"]` if nothing is left).

### IRE

`ire_fetch.find_token` is unchanged. When there's no token, `get_recommendations` tries the
GitHub API without auth (the IRE repo is public). If that fails too, it uses the cache, then
`defaults.json`, as before. A token never appears in the output, logs or cache.

### Key handling

The key is never written to stdout, stderr, the install log, `install.json`, the task command
line or any file except `secrets\inferhub.env`. The proxy reads it from that file at start.

### Uninstall

`install.ps1 -Uninstall` (or `claude-inferhub --uninstall`):

1. Stops our proxy (by the PID file in `logs\`, never by port) and unregisters the task.
2. Runs `settings_sync.py unsync`; deletes `settings.json` only if the installer created it and
   it's now empty. Removes the planner sub-agent.
3. Removes `bin\` from the user PATH.
4. Deletes `InstallDir`.

uv, git, Node, pnpm and Claude Code stay. Install, then uninstall, then install gives the same
state as a fresh install, except for a new `instance_id`.

### PowerShell functions (library mode)

With `CCL_INSTALL_LIBRARY_ONLY=1`, dot-sourcing `install.ps1` defines these and does nothing else:

| Function | Contract |
|---|---|
| `Test-CclKeyShape -Key <string>` | `$true` when the trimmed key is valid (rules above). |
| `Resolve-CclInferHubKey -Flag <string> -Environment <IDictionary> -StoredPath <path> -Prompt <scriptblock> [-NonInteractive]` | Returns the key by the precedence above. Throws `CCL_NO_KEY` (non-interactive, nothing found) or `CCL_BAD_KEY`. |
| `Write-CclSecret -Path <path> -Key <string>` / `Read-CclSecret -Path <path>` | Write or read `secrets\inferhub.env`. |
| `New-CclInstanceId` | 32 lowercase hex characters. |
| `Read-CclInstallState -InstallDir <path>` / `Write-CclInstallState -InstallDir <path> -State <hashtable>` | `install.json`, exactly the schema keys. |
| `Get-CclPortState -Port <int> -InstanceId <string>` | `free`, `ours` or `foreign`. |
| `Select-CclPort -Start <int> -Saved <int> -Probe <scriptblock> [-Count <int>]` | As described under Port choice. |
| `Get-CclPrereqPlan -Have <IDictionary>` | The tools to install, in order (`uv`, `git`, `node`, `pnpm`, `claude`), for the ones whose value is false. |
| `Get-CclShimText -InstallDir <path>` | The text of `bin\claude-inferhub.cmd`. |
| `Get-CclTaskArguments -InstallDir <path> -Port <int>` | The logon task's argument string. Never contains the key. |
| `Invoke-CclInstall` / `Invoke-CclUninstall` | The install and uninstall flows. Take the script's parameters and return an exit code. |

### Exit codes

`0` ok, `2` bad arguments or bad key, `3` a prerequisite is missing and couldn't be installed,
`4` no key in non-interactive mode, `5` fetching the launcher files failed, `6` building the
venv failed. When the script runs through `iex` it never calls `exit` (that would close the
user's window); it writes the error and returns.

## Success conditions

1. On a clean Windows 10/11 user account, the one-liner plus a key gives a working
   `claude-inferhub` launch through the proxy, with all four slots routed and web search
   returning results.
2. With another LiteLLM already on 4000, the install picks 4001 (or the next free port), and
   `ANTHROPIC_BASE_URL` points there.
3. No Alex-specific path, name or secret is in `install.ps1` or used in packaged mode.
4. CI runs every test category and publishes `install.ps1` as a build artifact.
5. `install.ps1` is attached to the `v1.0.0-windows` release.

## Non-goals

- A zip, MSI or `.exe` installer.
- Uninstalling the prerequisites.
- macOS (the Mac launcher already has its own setup).
- Wiring IRE's live Top 20 into the Windows picker table (follow-up).
- Changing the seat or slot routing.
- Running the proxy as a Windows service or for other users.

## Tests

| Category | Where | Tag or marker |
|---|---|---|
| Spec (example-based) | `tests/test_pkg_*.py`, `tests/pester/*.Tests.ps1` | pytest `spec`, Pester `Spec` |
| Property-based | Hypothesis in `tests/test_pkg_*.py`; table invariants in Pester | pytest `property`, Pester `Property` |
| Metamorphic | both | pytest `metamorphic`, Pester `Metamorphic` |
| End-to-end on Windows | `.github/workflows/launcher-ci.yml` job `windows-installer` | Pester `E2E` |

Hidden holdout tests are written by another owner outside the repo, against the interfaces in
this spec: the `install.ps1` parameters, environment variables, exit codes, folder layout,
`install.json` schema, `claude-inferhub` verbs, `/ccl/identity`, `Select-CclPort`,
`Get-CclLaunchConfig`, `settings_sync.py`, and `chain_from_env`.
