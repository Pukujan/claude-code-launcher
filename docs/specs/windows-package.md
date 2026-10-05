# Spec: one-command Windows installer

Status: accepted for build (issue [#61](https://github.com/Pukujan/claude-code-launcher/issues/61), task CCL-0061;
fixes in issue [#63](https://github.com/Pukujan/claude-code-launcher/issues/63), task CCL-0063).
Version this spec describes: `v1.0.1-windows`. The changes from `v1.0.0-windows` are listed at the end.

## Problem

Alex wants a friend to get his Claude Code setup on Windows (the LiteLLM proxy, the slot
chains, the IRE model list, the Claude Code config) by running one command. The only thing
the friend should need is his own InferHub API key. Today there's no installer. The launcher
expects a checkout, Claude Code and uv already installed, it hard-codes port 4000, it treats
any proxy on 4000 as its own, and it looks in places that only exist on Alex's PC.

## Shape

A single PowerShell script, `windows/install.ps1`, attached to each GitHub release
(`v1.0.1-windows` now). There's no zip. The script fetches the launcher files for its own tagged
version, does the setup, and leaves a `claude-inferhub` command. Everything it installs lives in
ONE folder the user picks (see "Self-contained install"), so uninstalling is deleting that folder
plus the logon task and the optional PATH entry.

Main path (the repo is public). `latest` always points at the newest Windows release:

```powershell
irm https://github.com/Pukujan/claude-code-launcher/releases/latest/download/install.ps1 | iex
```

With parameters:

```powershell
& ([scriptblock]::Create((irm https://github.com/Pukujan/claude-code-launcher/releases/latest/download/install.ps1))) -InferHubKey <key>
```

A pinned version works the same way:
`https://github.com/Pukujan/claude-code-launcher/releases/download/v1.0.1-windows/install.ps1`. Every published
release keeps its asset, so the `v1.0.0-windows` one-liner keeps working (it installs 1.0.0; run
the `latest` one-liner over it to update). Each new Windows release is marked latest.

Download-and-run also works (`powershell -ExecutionPolicy Bypass -File .\install.ps1`). If the
repo ever goes private again, `gh release download v1.0.1-windows -R Pukujan/claude-code-launcher -p install.ps1`
gets the script, and the installer fetches the source through `gh` when it's logged in.

## Inputs

### `install.ps1` parameters (stable interface)

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `-InferHubKey` | string | none | The InferHub API key. Wins over every other source. |
| `-InstallDir` | path | `$env:CCL_INSTALL_DIR`, else asked (see below) | The one folder everything goes into. Any path; created when missing. |
| `-PortableOnly` | switch | off | Never reuse a tool already on the PC; put private copies of every tool in the folder. |
| `-UseSystemTools` | switch | off | Also reuse a git and a Claude Code already on the PC (by default those are always private copies). |
| `-ClaudeConfigDir` | path | `<InstallDir>\claude-config` | Claude Code's config folder for launcher sessions (`CLAUDE_CONFIG_DIR`). Only for tests and special setups; the default keeps it inside the folder. |
| `-Ref` | string | `v1.0.1-windows` | Git tag or branch of the launcher files to fetch. |
| `-Source` | path | none | Use this local checkout instead of fetching (tests, offline). |
| `-StartPort` | int | `4000` | First port tried for the proxy. Any TCP port, 1 to 65535; anything else is exit 2. The search never goes past 65535. |
| `-Uninstall` | switch | off | Remove the install (see Uninstall). |
| `-ChangeKey` | switch | off | Replace the stored key only, then restart the proxy if it runs. |
| `-TinyFishKey` | string | none | The TinyFish Search API key (free). Wins over every other TinyFish source. |
| `-SkipTinyFish` | switch | off | Don't ask for a TinyFish key; keep a stored one if there is one. |
| `-ChangeTinyFishKey` | switch | off | Replace (or, with an empty answer, remove) the stored TinyFish key only, then restart the proxy if it runs. |
| `-SkipPrereqs` | switch | off | Don't set up any tools; use whatever is on PATH (tests). Nothing is downloaded and `install.json` records no tools. |
| `-SkipVenv` | switch | off | Don't build the LiteLLM venv (tests). |
| `-NoTask` | switch | off | Don't register the logon task. |
| `-NoPath` | switch | off | Don't add `bin\` to the user PATH (then run `<InstallDir>\bin\claude-inferhub.cmd` directly). |
| `-NoStart` | switch | off | Don't start the proxy at the end. |
| `-NonInteractive` | switch | off | Never prompt. A missing InferHub key is an error (exit 4); a missing TinyFish key is only a warning. |

### Environment variables

| Name | Meaning |
|---|---|
| `CCL_INFERHUB_KEY` | The key, when `-InferHubKey` isn't given. |
| `INFERHUB_API_KEY` | The key, when neither of the above is set. |
| `CCL_TINYFISH_KEY` | The TinyFish key, when `-TinyFishKey` isn't given. |
| `TINYFISH_API_KEY` | The TinyFish key, when neither of the above is set. |
| `CCL_INSTALL_DIR` | Default for `-InstallDir` (no prompt then). |
| `CCL_INSTALL_LIBRARY_ONLY` | `1` = define the functions and return without doing anything (tests). |
| `CCL_HOME` | Set by the `claude-inferhub` shim to the install folder; makes the launcher run in packaged mode. |

Key precedence: `-InferHubKey`, then `CCL_INFERHUB_KEY`, then `INFERHUB_API_KEY`, then the
key already stored by an earlier install, then a masked prompt (`Read-Host -AsSecureString`).
A key is trimmed. It must be non-empty, at most 4096 characters, and contain no CR, LF, NUL
or double quote. Anything else is rejected with exit 2 and a message that doesn't echo the key.

TinyFish key precedence: `-TinyFishKey`, then `CCL_TINYFISH_KEY`, then `TINYFISH_API_KEY`, then
the key stored by an earlier install, then a masked prompt. The prompt says the key is free and
where to get it (`https://agent.tinyfish.ai/api-keys`), and an empty answer skips it. Skipping
(empty answer, `-SkipTinyFish`, or `-NonInteractive` with no key found) is never an error: the
install goes on and prints a warning that web search can be unreliable without it and how to
add it later (`claude-inferhub --set-tinyfish-key`). The same shape rules apply; a bad TinyFish
key is exit 2 and checked before anything changes on disk.

### Choosing the folder

When neither `-InstallDir` nor `CCL_INSTALL_DIR` is given, an install asks
`Install folder [<suggestion>]`. An empty answer takes the suggestion; any other answer is used as
typed (relative paths are made absolute, the folder is created when missing). The suggestion is
the folder of an existing v1.0.0 install (`%LOCALAPPDATA%\claude-code-launcher` with an
`install.json`) when there is one, else `%USERPROFILE%\claude-code-launcher`. With `-NonInteractive`
the suggestion is used without asking.

The folder must be missing, empty, or an earlier install (has `install.json` or `app\windows\install.ps1`).
Any other non-empty folder is refused, so a typo like `C:\Users\me\Documents` can't scatter files
into it: the prompt asks again (up to three times), and with `-NonInteractive` or `-InstallDir` it's
exit 2 with a message.

`-Uninstall`, `-ChangeKey` and `-ChangeTinyFishKey` without `-InstallDir` never ask: they use
`CCL_INSTALL_DIR`, else the folder named by the logon task (`-CclHome "<folder>"`), else the
v1.0.0 folder when it has an `install.json`, else `%USERPROFILE%\claude-code-launcher`. The
`claude-inferhub` verbs always pass their own folder.

### Self-contained install

Every tool the launcher needs, and all of their data, lives in the folder:

| Tool | Reused when (unless `-PortableOnly`) | Otherwise, private copy in |
|---|---|---|
| Python | a Python 3.10 to 3.13 is found (`py -3.13` .. `py -3.10`, then `python`/`python3` on PATH, not the Microsoft Store stub). The venv is made with `uv venv --python <that python>`. | `tools\python\` (uv-managed CPython 3.12, `UV_PYTHON_INSTALL_DIR`) |
| Node | `node` on PATH reports v18 or newer | `tools\node\` (official zip, Node 24 LTS) |
| uv | `uv` is on PATH | `tools\uv\` (official zip) |
| pnpm | `pnpm` is on PATH | `tools\pnpm\` (standalone `pnpm.exe` from the official release) |
| git | `-UseSystemTools` and `git` is on PATH | `tools\git\` (Git for Windows PortableGit; MinGit has no `bash.exe`, which Claude Code needs) |
| Claude Code | `-UseSystemTools` and `claude` is on PATH | `tools\claude\claude.exe` (the native build from `downloads.claude.ai`, stable channel, checked against its manifest SHA-256) |

Every download is checked against a pinned SHA-256 (Claude Code: the manifest's). A failed or
mismatched download is exit 3 and leaves no half-extracted tool. Winget and the global installers
are never used, and nothing is added to the PATH except the optional `bin\`.

Whether a tool is reused or private doesn't change where data goes. The installer and every
launcher session set:

| Variable | Value |
|---|---|
| `UV_CACHE_DIR` | `<InstallDir>\cache\uv` |
| `UV_PYTHON_INSTALL_DIR` | `<InstallDir>\tools\python` |
| `UV_PYTHON_BIN_DIR`, `UV_TOOL_BIN_DIR` | `<InstallDir>\tools\bin` |
| `UV_TOOL_DIR` | `<InstallDir>\tools\uv-tools` |
| `UV_INSTALL_DIR` | `<InstallDir>\tools\uv` |
| `PNPM_HOME` | `<InstallDir>\tools\pnpm` |
| `npm_config_store_dir` | `<InstallDir>\cache\pnpm-store` |
| `npm_config_cache_dir`, `npm_config_state_dir` | `<InstallDir>\cache\pnpm` |
| `npm_config_cache` | `<InstallDir>\cache\npm` |
| `CLAUDE_CONFIG_DIR` | `<InstallDir>\claude-config` (or `-ClaudeConfigDir`) |
| `CLAUDE_CODE_GIT_BASH_PATH` | the private git's `bin\bash.exe`, when git is private |
| `DISABLE_AUTOUPDATER` | `1`, so Claude Code never updates itself into the profile |
| `PATH` | the tool folders in front: `tools\claude`, `tools\node`, `tools\pnpm`, `tools\uv`, `tools\git\cmd`, then the reused tools' folders |

`CLAUDE_CONFIG_DIR` puts all of Claude Code's own data for launcher sessions in the folder:
`settings.json`, `.claude.json`, sessions, projects, todos, plans, the scratchpad and shell
snapshots. The friend's other Claude Code use (plain `claude`, with `~\.claude`) isn't touched.
`TEMP`/`TMP` stay at the Windows default.

Apart from the folder, an install writes only the logon task and, unless `-NoPath`, the `bin\`
entry in the user PATH. CI checks this by snapshotting the whole user profile before and after a
real install on `windows-latest` (both the reuse and the private-copy paths), ignoring `%TEMP%`.

## Outputs

### Install folder layout (`InstallDir`)

| Path | What |
|---|---|
| `app\` | The launcher files at `-Ref` (replaced on every install). |
| `install.json` | Install state (schema below). |
| `secrets\inferhub.env` | One line, `INFERHUB_API_KEY=<key>`, UTF-8 without BOM. ACL limited to the current user on Windows. |
| `secrets\tinyfish.env` | One line, `TINYFISH_API_KEY=<key>`, same format and ACL. Only there when a TinyFish key was given. |
| `state\last-picks.json` | The saved slot picks and the default start folder. |
| `state\local.env` | Optional per-user proxy settings (e.g. `CCL_WEB_SEARCH_CHAIN`). Never created by the installer, never removed by a reinstall. |
| `venv\` | The LiteLLM venv, built with `uv venv --python 3.12` and the pinned requirements. |
| `logs\` | Proxy logs and PID file. |
| `bin\claude-inferhub.cmd` | The launch command. `bin\` is added to the user PATH once (unless `-NoPath`). Pure ASCII and holds no path: it finds the install folder from its own location (see below). |
| `tools\` | Private copies of the tools (only the ones not reused), see above. |
| `cache\` | uv's cache, the pnpm store and caches. |
| `claude-config\` | Claude Code's config and data for launcher sessions (`CLAUDE_CONFIG_DIR`): `settings.json`, the planner sub-agent, sessions. |

`install.json` (schema `claude-code-launcher.install.v2`; v1.0.0 wrote `v1`, which is still read):

```json
{
  "schema": "claude-code-launcher.install.v2",
  "version": "1.0.1-windows",
  "ref": "v1.0.1-windows",
  "port": 4000,
  "instance_id": "<32 hex chars, made once and kept across reinstalls>",
  "task_name": "claude-code-launcher-proxy",
  "claude_settings_created": false,
  "claude_config_dir": "<InstallDir>\\claude-config",
  "tools": {
    "python": { "source": "reused", "path": "C:\\Python312\\python.exe", "version": "3.12.10" },
    "node":   { "source": "bundled", "path": "<InstallDir>\\tools\\node\\node.exe", "version": "24.21.0" },
    "uv": { "...": "..." }, "pnpm": { "...": "..." }, "git": { "...": "..." }, "claude": { "...": "..." }
  }
}
```

`source` is `reused` or `bundled`. `tools` is `{}` with `-SkipPrereqs`. Nothing else is in
`install.json`, and it never holds a key. The launcher keeps `tools` and `claude_config_dir` when
it rewrites the file for a new port.

### `claude-inferhub` command

`claude-inferhub [launcher options] [-- claude args]` runs
`app\windows\launch-claude-inferhub.ps1` with `CCL_HOME` set to the install folder. The shim
works that folder out from its own location (`for %%I in ("%~dp0..") do set "CCL_HOME=%%~fI"`), so
the file holds no path at all and is pure ASCII. cmd.exe reads `.cmd` files in the console's OEM
code page, so a path written into the file would break for a profile like `C:\Users\José`; this
way it works for any folder name, and the install folder can even be moved. Extra verbs:

| Command | Does |
|---|---|
| `claude-inferhub --set-key` | Runs `install.ps1 -ChangeKey` against this install (prompt, flag or env as above). |
| `claude-inferhub --set-tinyfish-key` | Runs `install.ps1 -ChangeTinyFishKey` against this install. |
| `claude-inferhub --uninstall` | Runs `install.ps1 -Uninstall` against this install. |
| `claude-inferhub --non-interactive ...` | The launcher's existing non-interactive mode (Paseo, scripts). |

### Logon task

`claude-code-launcher-proxy`, a per-user logon task that runs
`conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File app\windows\litellm\start-litellm.ps1 -CclHome <InstallDir> -Port <port>`.
No window shows. It's re-registered whenever the port changes.

## Behavior

### Install (also re-install)

1. Resolve and check the InferHub key, then the TinyFish key (precedence above), before
   changing anything, so a missing or bad key leaves no partial install.
2. Choose and check the folder (above). Then, unless `-SkipPrereqs`, find or fetch the tools as
   described under "Self-contained install". Exit 3 if one can't be set up.
3. Fetch the launcher files for `-Ref` into `app\`. Order: `-Source`, then the public tarball
   (`codeload.github.com`), then `gh repo clone` when gh is logged in, then
   `git clone --depth 1 --branch <ref>`. Exit 5 if all of them fail. Copying skips `.git`,
   `.env` files (except `.env.example`), `last-picks.json`, venvs, logs, tests and caches.
   Then store the keys (`secrets\tinyfish.env` only when there is a TinyFish key).
4. Build the venv unless `-SkipVenv`: `uv venv --python <reused python, or 3.12 managed in tools\python>`,
   then `uv pip install` with the pinned requirements, with the uv variables above. Exit 6 if that fails.
5. Pick the port (below) and write `install.json`, keeping the existing `instance_id`.
6. Write `bin\claude-inferhub.cmd`, add `bin\` to the user PATH once (unless `-NoPath`).
7. Create Claude Code's `settings.json` in `claude-config\` if it's missing, and merge
   `advisorModel: "fable"`, `model: "sonnet"` and the `modelPicker` options into it (below). Install
   the planner sub-agent there. When upgrading a v1.0.0 install (its `install.json` has no
   `claude_config_dir`), first remove what v1.0.0 put into `~\.claude` (`settings_sync.py unsync`
   and the planner), so nothing of ours stays in the profile.
8. Register the logon task (unless `-NoTask`) and start the proxy (unless `-NoStart`), then
   wait until the proxy on the chosen port answers as ours.

Running install twice leaves the same state as running it once. (State means every file under
`InstallDir` except `logs\`, `cache\` and `tools\`, plus the Claude Code config folder.)

### Port choice and "is it ours"

The proxy answers `GET /ccl/identity` only to loopback callers (`ccl_identity.is_loopback`:
any address in `127.0.0.0/8`, `::1`, those addresses written v4-mapped such as
`::ffff:127.0.0.2`, bracketed or with an IPv6 zone, and `localhost`) with
`{"app": "claude-code-launcher", "instance": "<CCL_INSTANCE_ID or empty>"}`.

A port's state is one of:

- `free`: nothing listens and 127.0.0.1:<port> can be bound.
- `ours`: something listens and `/ccl/identity` returns our app name and this install's `instance_id`.
- `foreign`: anything else listening (another LiteLLM, any other program).

`Select-CclPort -Start <int> -Saved <int> -Probe <scriptblock> [-Count 100]` returns the saved port
if it's a valid port (1 to 65535) and its state is `free` or `ours`. Otherwise it returns the lowest
port in `Start..min(Start+Count-1, 65535)` whose state is `free` or `ours`, and throws
`CCL_NO_PORT` if there's none. A `Start` outside 1 to 65535 throws `CCL_BAD_PORT`. It never returns a `foreign` port.
The launcher runs it on every packaged launch, so if another program takes our port later, it
moves to a new free port, saves it, re-registers the task and points Claude at it.

`ANTHROPIC_BASE_URL` is always `http://127.0.0.1:<chosen port>`.

### Packaged mode vs Alex's own setup

Packaged mode is on when `CCL_HOME` is set, or `install.json` sits in the folder above the
launcher's repo root. In packaged mode:

- The only env files read are `secrets\inferhub.env`, `secrets\tinyfish.env` and
  `state\local.env` (each if present), in that order.
  No Desktop `configs\.env`, no `inference-recommendation-engine\.env`, no `D:\development`,
  no `C:\work`, no `shared\litellm\.env.local`, and no `CCL_ENV_ALIASES` default.
- The folder picker starts at the saved start folder, else the user's home.
- The venv, logs and picks live under `InstallDir`.
- The proxy health check requires `ours`, not just a live `/health` answer.
- The variables under "Self-contained install" are set for the session (from `install.json`'s
  `tools` and `claude_config_dir`), so `claude`, uv, Python and Node come from the folder or the
  reused copies, and Claude Code keeps its data in `claude-config\`. UltraCode's cache goes to
  `state\ultracode-shim\`.
- `--print-env` also hands over `CLAUDE_CONFIG_DIR`, `DISABLE_AUTOUPDATER`, `CLAUDE_CODE_GIT_BASH_PATH`
  (when set), `CCL_CLAUDE_BIN` (the `claude` to run) and `PATH`, so integrations such as
  `app\shared\integrations\claude-env-exec.mjs` run the folder's Claude Code with the folder's config.

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
- `unsync(settings: dict) -> dict` removes `modelPicker` when every option's description or label says
  "via local LiteLLM" or "InferHub", removes `advisorModel` when it's `"fable"` and `model` when
  it's `"sonnet"`. Everything else is kept.
- CLI: `python settings_sync.py sync|unsync --settings PATH [--options-file FILE]`. `sync`
  creates the file (and its folder) when missing and prints `created` or `updated` or
  `unchanged` on stderr. The folder is `CLAUDE_CONFIG_DIR` when set, else `~/.claude`.
- An existing file that is empty (0 bytes) or holds only whitespace counts as `{}`: `sync`
  writes the launcher's keys into it, and `unsync` has nothing to remove and leaves it as it is.
- A file that isn't valid JSON, or whose JSON isn't an object, is left untouched (exit 1).
- A read-only file is never changed or replaced: the read-only attribute on Windows, or no
  owner write bit / no write access on Linux and macOS. The helper prints
  `settings_sync: <path> is read-only; left untouched` and exits 3. This is checked only
  when there's something to change, so an unchanged read-only file is still exit 0.
- Exit codes: `0` ok or unchanged, `1` not valid JSON or a write error, `2` a bad options file,
  `3` read-only.

The installer, the launcher and the uninstaller treat a nonzero exit as a warning: they print
it, leave the file alone and carry on (the install still exits 0).

The launcher calls `sync` on every interactive launch and in non-interactive mode (including
`--print-env`, which is what Paseo uses), with nothing written to stdout.

### Web search

`web_search.chain_from_env(env)`: when `CCL_WEB_SEARCH_CHAIN` is unset or blank, the chain is
`tinyfish` (only when `TINYFISH_API_KEY` is non-blank), then `ddgs`, then `you_com`. An explicit
chain is used as given (aliases mapped, `duckduckgo` dropped, `["ddgs"]` if nothing is left).
In a packaged install the proxy gets `TINYFISH_API_KEY` from `secrets\tinyfish.env`, so with a
key the chain is `tinyfish`, `ddgs`, `you_com`, and without one it's `ddgs`, `you_com`.

### IRE

`ire_fetch.find_token` is unchanged. When there's no token, `get_recommendations` tries the
GitHub API without auth (the IRE repo is public). If that fails too, it uses the cache, then
`defaults.json`, as before. A token never appears in the output, logs or cache.

### Key handling

Neither key is ever written to stdout, stderr, the install log, `install.json`, the task command
line, the shim or any file except its own `secrets\*.env`. The proxy reads them from those files
at start. The same TinyFish key given by prompt, flag or either env variable gives the same
stored state.

### Uninstall

`install.ps1 -Uninstall` (or `claude-inferhub --uninstall`). The folder counts as **proven** ours
when it has a readable `install.json`, or is empty.

For a proven folder:

1. Stops our proxy (by the PID file in `logs\`, never by port) and unregisters the task.
2. When the Claude config folder is outside `InstallDir` (a v1.0.0 install, or `-ClaudeConfigDir`):
   runs `settings_sync.py unsync`, deletes `settings.json` only if the installer created it and
   it's now empty, and removes the planner sub-agent. A config folder inside `InstallDir` simply
   goes with it.
3. Removes `bin\` from the user PATH.
4. Deletes `InstallDir`. Exit 0.

For a folder that exists but isn't proven (no `install.json`, not empty), the uninstaller still
removes everything of ours it can name, and keeps the folder itself:

1. Unregisters the logon task only if its command line points at this folder (`-CclHome "<InstallDir>"`).
   It doesn't kill anything by PID.
2. Runs `settings_sync.py unsync` and removes the planner sub-agent, using the helpers in
   `app\shared\claude\` and the venv or a system Python. `settings.json` is never deleted (the
   installer can't show it created it). Without the helpers it warns and skips this step.
3. Deletes `secrets\inferhub.env` and `secrets\tinyfish.env`, and `secrets\` if that leaves it empty.
4. Deletes `bin\claude-inferhub.cmd` only if it's our shim (its second line starts with
   `rem claude-inferhub:`), and removes `bin\` from the user PATH.
5. Leaves the folder and everything else in it, warns that it was kept because nothing proves
   the installer made it, and exits 0.

A folder that doesn't exist is exit 0 with "nothing installed".

Tools reused from the PC stay (and so do prerequisites a v1.0.0 install put on the PC). Private
copies go with the folder. Install, then uninstall, then install gives the same
state as a fresh install, except for a new `instance_id`.

### PowerShell functions (library mode)

With `CCL_INSTALL_LIBRARY_ONLY=1`, dot-sourcing `install.ps1` defines these and does nothing else:

| Function | Contract |
|---|---|
| `Test-CclKeyShape -Key <string>` | `$true` when the trimmed key is valid (rules above). |
| `Resolve-CclInferHubKey -Flag <string> -Environment <IDictionary> -StoredPath <path> -Prompt <scriptblock> [-NonInteractive]` | Returns the key by the precedence above. Throws `CCL_NO_KEY` (non-interactive, nothing found) or `CCL_BAD_KEY`. |
| `Resolve-CclTinyFishKey -Flag <string> -Environment <IDictionary> -StoredPath <path> -Prompt <scriptblock> [-NonInteractive] [-Skip]` | Returns the TinyFish key by its precedence, or `$null` when skipped (never throws for a missing key; the prompt is not called with `-Skip` or `-NonInteractive`). Throws `CCL_BAD_KEY` for a bad one. |
| `Write-CclSecret -Path <path> -Key <string> [-Name <string>]` / `Read-CclSecret -Path <path> [-Name <string>]` | Write or read a `secrets\*.env` file. `-Name` is the variable, default `INFERHUB_API_KEY` (`TINYFISH_API_KEY` for `secrets\tinyfish.env`). |
| `New-CclInstanceId` | 32 lowercase hex characters. |
| `Read-CclInstallState -InstallDir <path>` / `Write-CclInstallState -InstallDir <path> -State <hashtable>` | `install.json`, exactly the schema keys. |
| `Get-CclPortState -Port <int> -InstanceId <string>` | `free`, `ours` or `foreign`. |
| `Select-CclPort -Start <int> -Saved <int> -Probe <scriptblock> [-Count <int>]` | As described under Port choice. |
| `Get-CclPrereqPlan -Have <IDictionary>` | The tools to install, in order (`uv`, `git`, `node`, `pnpm`, `claude`), for the ones whose value is false. |
| `Get-CclToolPlan -Found <IDictionary> [-PortableOnly] [-UseSystemTools]` | `reuse` or `bundle` for each of `python`, `node`, `uv`, `pnpm`, `git`, `claude`. `Found[name]` is `$null` or `@{ path; version }`. Rules as in the table under "Self-contained install". |
| `Test-CclPythonVersion -Version <string>` / `Test-CclNodeVersion -Version <string>` | `$true` for Python 3.10 to 3.13 / Node 18 or newer (a leading `v` is fine). |
| `Get-CclToolEnv -InstallDir <path> [-State <object>]` | The variables in the table above, as an ordered hashtable (`PATH` is the list of folders to put in front). |
| `Test-CclInstallTarget -InstallDir <path>` | `$true` when the folder may be installed into (missing, empty or an earlier install). |
| `Get-CclShimText [-InstallDir <path>]` | The text of `bin\claude-inferhub.cmd`: pure ASCII, the same for every install folder (`-InstallDir` is accepted and ignored). |
| `Get-CclTaskArguments -InstallDir <path> -Port <int>` | The logon task's argument string. Never contains the key. |
| `Invoke-CclInstall` / `Invoke-CclUninstall` | The install and uninstall flows. Take the script's parameters and return an exit code. For tests `Invoke-CclInstall` also takes `-Environment <IDictionary>` (instead of the process environment), `-KeyPrompt` and `-TinyFishPrompt` (scriptblocks instead of the masked prompts), `-LocationPrompt` (scriptblock, given the suggestion), `-ToolProbe` (scriptblock returning the `Found` table) and `-ToolSpecs` (replaces the pinned download table). |

### Exit codes

`0` ok, `2` bad arguments, bad key or a folder that can't be installed into, `3` a tool couldn't be set up,
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
5. `install.ps1` is attached to the `v1.0.1-windows` release (and each later one), marked latest.

## Non-goals

- A zip, MSI or `.exe` installer.
- Uninstalling tools that were already on the PC.
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
| End-to-end on Windows | `.github/workflows/launcher-ci.yml` job `windows-installer`: real installs without `-SkipPrereqs` (reusing the runner's tools, and `-PortableOnly`), a profile snapshot before and after, and `claude-inferhub` through a real `cmd.exe` from a non-ASCII folder | Pester `E2E` |

Hidden holdout tests are written by another owner outside the repo, against the interfaces in
this spec: the `install.ps1` parameters, environment variables, exit codes, folder layout,
`install.json` schema, `claude-inferhub` verbs, the TinyFish key handling, `/ccl/identity`, `Select-CclPort`,
`Get-CclLaunchConfig`, `settings_sync.py`, and `chain_from_env`.

## Changes in v1.0.1-windows (issue #63)

1. The shim holds no path and is pure ASCII; it finds the install folder from `%~dp0`. Before,
   it held the full path as UTF-8 without a BOM, which cmd.exe misread for non-ASCII profiles.
2. `-Uninstall` without `install.json` cleans up settings, the planner, the secrets and the shim,
   and keeps the folder (exit 0). Before, it stopped at once with exit 2.
3. `-StartPort` accepts 1 to 65535 (was an undocumented 1024 to 65000), and `Select-CclPort`
   stays inside that range.
4. An empty settings.json counts as `{}`, the same as a whitespace-only one (whitespace-only was
   exit 1 before).
5. A read-only settings.json is left untouched (exit 3 from the helper, a warning from the
   installer). Before, it was replaced.
6. `is_loopback` accepts all of `127.0.0.0/8`, `::1` and v4-mapped loopback (it only knew
   `127.0.0.1`, `::1`, `::ffff:127.0.0.1` and `localhost`).
7. The documented one-liner uses `releases/latest/download/install.ps1`.
8. Self-contained install: the installer asks for one folder and puts everything in it, including
   private copies of the tools that aren't already on the PC (Python, Node, uv, pnpm) and, by
   default, always of git and Claude Code. Claude Code runs with `CLAUDE_CONFIG_DIR` in the folder.
   No winget or global installers. New: `-PortableOnly`, `-UseSystemTools`, `-ClaudeConfigDir`,
   the folder prompt, `install.json` schema v2 with `tools` and `claude_config_dir`. An upgrade
   from v1.0.0 cleans what v1.0.0 put into `~\.claude`.
