# Claude Code + InferHub on Windows: one command

This sets up Claude Code on your PC so it talks to InferHub through a small
LiteLLM proxy that runs on your own machine. You need an InferHub API key and
about ten minutes. A TinyFish key for web search is a good idea too (it's
free, see below). Nothing here needs admin rights.

## Before you start: get a free TinyFish key

TinyFish Search is what Claude uses to search the web. It's free and doesn't
need a card:

1. Sign up at <https://agent.tinyfish.ai/sign-up>.
2. Open <https://agent.tinyfish.ai/api-keys> and click "Create API Key".
3. Keep the key handy; the installer asks for it.

You can skip it, but then search falls back to DuckDuckGo and You.com, which
are often rate-limited and can be unreliable. You can add the key later.

## Install

Open **PowerShell** (Start menu, type "PowerShell", Enter) and paste:

```powershell
irm https://github.com/Pukujan/claude-code-launcher/releases/download/v1.0.0-windows/install.ps1 | iex
```

It asks for your InferHub key, then your TinyFish key (the typing is hidden
for both; press Enter at the TinyFish one to skip it), then does the rest.
When it says "All set", open a **new** terminal and run:

```powershell
claude-inferhub
```

If you would rather pass the keys up front, so nothing is asked:

```powershell
& ([scriptblock]::Create((irm https://github.com/Pukujan/claude-code-launcher/releases/download/v1.0.0-windows/install.ps1))) -InferHubKey 'ih-your-key-here' -TinyFishKey 'your-tinyfish-key'
```

Use `-SkipTinyFish` instead of `-TinyFishKey` if you don't want one. Setting
`INFERHUB_API_KEY` and `TINYFISH_API_KEY` in the environment works too. Keep
in mind that a key typed on the command line can end up in your PowerShell
history. The prompts don't have that problem.

### Prefer to look at the script first?

Download it, read it, then run it:

```powershell
irm https://github.com/Pukujan/claude-code-launcher/releases/download/v1.0.0-windows/install.ps1 -OutFile install.ps1
notepad install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

If you have the GitHub CLI and access to the repository, this gets the same
file:

```powershell
gh release download v1.0.0-windows -R Pukujan/claude-code-launcher -p install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

## What it installs

Only what is missing. Everything already on the PC is left as it is.

- **uv** (Python manager) from its official installer, and Python 3.12 through uv
- **Git** and **Node.js LTS** through winget, and **pnpm**
- **Claude Code** from `https://claude.ai/install.ps1`
- The launcher itself, in `%LOCALAPPDATA%\claude-code-launcher`:
  - `app\` holds the launcher files
  - `venv\` holds LiteLLM
  - `secrets\inferhub.env` and `secrets\tinyfish.env` hold your keys, readable only by your user
  - `state\` holds your last picks and optional settings
  - `logs\` holds the logs
  - `bin\claude-inferhub.cmd` is the command, added to your user PATH
- A logon task named `claude-code-launcher-proxy` that starts the proxy hidden
  when you sign in

The installers it downloads are saved to a temporary file and run from there.
None of them are piped into `iex`.

## Using it

`claude-inferhub` asks you to pick a model chain for each of Claude Code's
slots (or keep your last picks) and a project folder, then opens Claude Code.
The folder list starts in your home folder, and it remembers the last one.

Heads up: it starts Claude Code with `--permission-mode bypassPermissions`,
so Claude does not ask before running commands or editing files. Only open
folders you are fine with it changing.

Other things you can do:

| Command | What it does |
| --- | --- |
| `claude-inferhub --set-key` | Change your InferHub key (restarts the proxy) |
| `claude-inferhub --set-tinyfish-key` | Add or change your TinyFish key; press Enter to remove it (restarts the proxy) |
| `claude-inferhub --uninstall` | Remove everything it installed (same as `install.ps1 -Uninstall`) |

Running the install command again updates the launcher and keeps your key.

## Ports

The proxy listens on `127.0.0.1` only, starting at port 4000. If something
else already uses 4000 (another LiteLLM, for example), the installer picks
the next free port and remembers it in `install.json`. It never takes over or
stops a program it didn't start. Before Claude Code connects, the launcher
checks that the proxy on that port really is this install's.

## Web search

With a TinyFish key, Claude's web searches go to TinyFish first, then
DuckDuckGo, then You.com's free tier if the others come back empty. Without
one, only DuckDuckGo and You.com are tried, and those often throttle or return
nothing. To add the key later:

```powershell
claude-inferhub --set-tinyfish-key
```

## Uninstall

```powershell
claude-inferhub --uninstall
```

or, if the command is gone:

```powershell
& ([scriptblock]::Create((irm https://github.com/Pukujan/claude-code-launcher/releases/download/v1.0.0-windows/install.ps1))) -Uninstall
```

This stops the proxy (only the one it started), removes the logon task, the
PATH entry, the model list and planner it added to Claude Code's settings, and
the install folder. Your other Claude Code settings stay. uv, Git, Node, pnpm
and Claude Code stay installed, since you may use them for other things.

## If something goes wrong

Look in `%LOCALAPPDATA%\claude-code-launcher\logs\`. `install.log` is the
installer, and `litellm.err.log` is the proxy. Your keys are never written
to the logs.
