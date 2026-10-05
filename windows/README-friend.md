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
irm https://github.com/Pukujan/claude-code-launcher/releases/latest/download/install.ps1 | iex
```

That link always gets the newest release. To pin this exact version instead,
use `irm https://github.com/Pukujan/claude-code-launcher/releases/download/v1.0.1-windows/install.ps1 | iex`. The old v1.0.0 link still works, but it installs 1.0.0,
which has the bugs fixed in 1.0.1 (a broken `claude-inferhub` command when
your Windows user name has accents or other non-English letters, among
others), so use the link above.

It first asks where to put everything:

```
Install folder [C:\Users\you\claude-code-launcher]:
```

Press Enter for the suggestion or type any folder (it's created if it isn't
there). Everything goes into that one folder, so it's easy to find, move to
another drive, or delete. A folder that already holds other files is refused,
so a typo can't scatter files into your Documents. Then it asks for your
InferHub key and your TinyFish key (the typing is hidden for both; press Enter
at the TinyFish one to skip it), and does the rest. When it says "All set",
open a **new** terminal and run:

```powershell
claude-inferhub
```

If you would rather pass the keys up front, so nothing is asked:

```powershell
& ([scriptblock]::Create((irm https://github.com/Pukujan/claude-code-launcher/releases/latest/download/install.ps1))) -InferHubKey 'ih-your-key-here' -TinyFishKey 'your-tinyfish-key'
```

Add `-InstallDir 'D:\tools\claude-launcher'` to choose the folder without
being asked. Use `-SkipTinyFish` instead of `-TinyFishKey` if you don't want one. Setting
`INFERHUB_API_KEY` and `TINYFISH_API_KEY` in the environment works too. Keep
in mind that a key typed on the command line can end up in your PowerShell
history. The prompts don't have that problem.

### Prefer to look at the script first?

Download it, read it, then run it:

```powershell
irm https://github.com/Pukujan/claude-code-launcher/releases/latest/download/install.ps1 -OutFile install.ps1
notepad install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

If you have the GitHub CLI and access to the repository, this gets the same
file:

```powershell
gh release download v1.0.1-windows -R Pukujan/claude-code-launcher -p install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

## What it installs

Everything lives in the folder you picked. Nothing is installed system-wide,
nothing goes through winget, and nothing is added to your PATH except the
folder's `bin\`.

- **Tools.** If your PC already has a suitable Python (3.10 to 3.13), Node.js
  (18 or newer), uv or pnpm, the installer uses it and leaves it alone.
  Whatever is missing or too old gets a private copy in `tools\`. Git
  (PortableGit) and Claude Code are always private copies, so your own
  installs are never touched; add `-UseSystemTools` to use the ones you have
  instead. Add `-PortableOnly` to never use anything from the PC. Every
  download is checked against a fixed SHA-256 before it's unpacked.
  `install.json` records which tools were reused and which are private.
  Poppler's `pdftoppm` (so Claude Code can read PDF pages) is set up the same
  way: reused if it's already on your PATH, otherwise a private copy.
- **The launcher**, in the folder:
  - `app\` holds the launcher files
  - `venv\` holds LiteLLM
  - `tools\` holds the private tools, `cache\` their caches (uv's cache, the pnpm store)
  - `claude-config\` is Claude Code's own config and data for launcher
    sessions (`CLAUDE_CONFIG_DIR`): settings, the planner, sessions and projects.
    Your normal `claude` (and `~\.claude`) isn't affected.
  - `secrets\inferhub.env` and `secrets\tinyfish.env` hold your keys, readable only by your user
  - `state\` holds your last picks and optional settings
  - `logs\` holds the logs
  - `bin\claude-inferhub.cmd` is the command, added to your user PATH (skip with `-NoPath` and run it from `bin\`)
- A logon task named `claude-code-launcher-proxy` that starts the proxy hidden
  when you sign in

Apart from the folder, only the logon task and the PATH entry are written.
Temporary files go to the usual Windows temp folder.

If you installed 1.0.0 before, run the new one-liner: it suggests your old
folder (`%LOCALAPPDATA%\claude-code-launcher`) and moves the launcher's Claude
Code settings out of `~\.claude` into the folder. Tools 1.0.0 installed
system-wide (uv, Git, Node, pnpm, Claude Code) stay where they are.

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
the next free port and remembers it in `install.json`. `-StartPort` picks a
different first port; any port from 1 to 65535 works. It never takes over or
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
& ([scriptblock]::Create((irm https://github.com/Pukujan/claude-code-launcher/releases/latest/download/install.ps1))) -Uninstall
```

This stops the proxy (only the one it started), removes the logon task and the
PATH entry, and deletes the install folder, which takes the private tools and
the launcher's Claude config with it. Tools that were already on your PC stay.
Without `-InstallDir` the uninstaller finds the folder through the logon task.

If `install.json` is gone, the uninstaller can't be sure it made the folder,
so it removes only its own pieces (the settings entries, the planner, the
keys in `secrets\`, the command and the PATH entry), keeps the folder and
tells you so. Delete the folder yourself if you're sure.

## Claude Code settings.json

The installer adds the model list and advisor to `claude-config\settings.json` in the install folder.
An empty file is treated as `{}`. It never touches a file that isn't valid
JSON, or one marked read-only; it warns and carries on, and the rest of the
install still works. Clear the read-only flag and run the installer again if
you want the model picker.

## If something goes wrong

Look in `%LOCALAPPDATA%\claude-code-launcher\logs\`. `install.log` is the
installer, and `litellm.err.log` is the proxy. Your keys are never written
to the logs.
