# Claude Code + InferHub on a Mac

This is the Mac version of the Windows "launch Claude through InferHub" shortcut.
You double-click one file. It starts the local LiteLLM proxy from this
repository, asks which project folder you want, asks which models to use, and
opens Claude Code in that folder with every request going through the proxy to
InferHub.

**It has only been tested on Linux so far.** See "Honest status" at the end.

## First time

1. Get this repository onto the Mac. Cloning with git is the easy way, because
   Finder then trusts the file. The repository is private, so sign in first
   (`brew install gh && gh auth login`):

   ```bash
   mkdir -p ~/work && cd ~/work
   gh repo clone Pukujan/claude-code-launcher
   open claude-code-launcher/mac
   ```

2. Either double-click **Launch Claude InferHub.command**, or install the
   `claude-acs` command from Terminal:

   ```bash
   ~/work/claude-code-launcher/mac/setup.sh
   ```

   `setup.sh` does the same first-run work as the double-click (below), then
   puts `claude-acs` in `~/.local/bin` and adds that folder to your PATH in
   `~/.zshrc`. Open a new Terminal window afterwards. `setup.sh --check` shows
   what's installed without changing anything, and `setup.sh --uninstall`
   removes `claude-acs` and stops the proxy this checkout started. It keeps your
   key and the venv.

The first run takes a few minutes. It installs whatever is missing, all inside
your home folder and without asking for an admin password:

- `uv`, which installs and manages Python for you
- Python 3.12, through uv
- a venv at `shared/litellm/.litellm-venv` with the pinned LiteLLM from
  `shared/litellm/requirements.txt`
- Claude Code, using Anthropic's official installer. If that fails, it falls
  back to npm, and gets Node from Homebrew or from nodejs.org first if it has to.

Nothing else gets cloned. The proxy config and scripts are already in
`shared/litellm/`.

It then asks for your **InferHub API key**, just once. Nothing shows on screen
while you paste it. The key goes into `~/.config/inferhub/.env`, which only you
can read. You can also put it in a `.env` at the repository root (copy
`.env.example`).

There is no proxy key to set up. The proxy listens on 127.0.0.1 only and runs
without a master key, and Claude Code is handed the dummy key `local`. If you do
set `LITELLM_MASTER_KEY` in one of those files, the proxy enforces it and the
launcher passes it to Claude Code instead.

## Every time after that

Double-click it again, or type `claude-acs` (`claude-acs ~/work/myproj` skips
the folder question). Nothing gets reinstalled. If the proxy is already
running, the script skips straight to the questions:

1. **Folder**: `~/work` is listed first, then each folder inside it, then
   folders you used before. Type a number, or:
   - `b` to browse in the terminal: arrow keys move, Right or Return opens a
     folder, Left goes up, `s` picks the folder you're in, `n` makes a new one
     there, Esc goes back
   - `q` for quick picks (home, Desktop, Documents, common code folders)
   - `t` to type a path (`~` works)
   - `n` to make a new folder
   - `x` to quit

   Then press Return to confirm.
2. **Main model**: the IRE Top 20. Press Return for the default, DeepSeek V4.1
   Flash.
3. **Advisor model**: press Return for OFF (the default), or type a number.

Claude Code then opens in that folder. To update the launcher, `git pull`.

### Where the model list comes from

Each launch asks `shared/ire/ire_fetch.py` for the current IRE Top 20. IRE is a
private repository, so this needs a GitHub login: `gh auth login` once, or a
`GH_TOKEN` in your environment. Without one, or offline, it uses the last list
it fetched, and before the first fetch the built-in list (the same one Windows
has). The launcher prints one `IRE:` line saying which it used, and never
stops because of it.

The same fetch also reads IRE's frontier list (stronger models with live route
prices) when IRE publishes it. Type `f` at the main or advisor prompt to pick
from it instead of the Top 20.

## If the Mac complains

- **"cannot be opened because it is from an unidentified developer"**: this
  only happens when the file came from a browser download instead of git.
  Right-click the file, choose **Open**, then **Open** again. You only do this
  once. In Terminal, `xattr -d com.apple.quarantine "Launch Claude InferHub.command"`
  does the same thing.
- **"Permission denied"**: run `chmod +x "Launch Claude InferHub.command"`.
- **Anything else**: the error says what went wrong. The full log is in
  `~/Library/Logs/claude-inferhub/launcher.log`, and LiteLLM's own logs are in
  `shared/litellm/logs/`. Keys never go into either.

## Knobs (rarely needed)

| Variable | Default | What it changes |
| --- | --- | --- |
| `LITELLM_PORT` | `4000` | Proxy port. Tests use another port. |
| `CLAUDE_IH_WORK_ROOT` | `~/work` | Root of the folder picker |
| `LITELLM_HEALTH_TIMEOUT` | `300` | Seconds to wait for the proxy |
| `INFERHUB_TOP20_CSV` | `shared/litellm/config/top20-builtin.csv` | A real IRE Top 20 CSV, if you have one |
| `CLAUDE_IH_PROJECT`, `CLAUDE_IH_MAIN`, `CLAUDE_IH_ADVISOR` | (ask) | Skip a picker. The old names `ACS_FOLDER`, `ACS_MAIN_ID`, `ACS_ADVISOR_ID` still work. |
| `CCL_IRE_OFFLINE` | unset | `1` skips GitHub and uses the cached or built-in list |
| `CLAUDE_IH_LAUNCH` | (ask; `claude` with no terminal) | `claude` or `ultracode` skips the "launch with" picker. UltraCode runs the real `ultracode` command from [UltraCode-Shim](https://github.com/OnlyTerp/UltraCode-Shim) (pinned commit, cached in `~/.cache/claude-code-launcher/ultracode-shim`, installed once with its `install.sh` as `~/.local/bin/ultracode`), pointed at the proxy with the seat alias as the model. |

## Stopping the proxy

`mac/stop-litellm.sh` stops the proxy this checkout started, using the PID in
`shared/litellm/logs/litellm.pid`. It checks that the PID really is this
checkout's LiteLLM first, and never stops anything by port.

## Tests

- `mac/tests/unit_tests.sh [bash]` runs offline checks on the model table, the
  key reading, the folder navigation, the folder picker with piped answers, the
  environment clearing and the stop script.
- `mac/tests/dry_run.sh [port] [bash]` copies `mac/` and `shared/` into a temp
  folder with a throwaway home, runs `setup.sh`, then `claude-acs` with a fake
  `claude` and a real LiteLLM on a test port (4100 by default; it refuses 4000).
  It checks the arguments, folder and environment the fake received, that the
  proxy listens on 127.0.0.1 only and serves the seat and fast aliases with no
  key, that the picked seat was hot-reloaded, and that `stop-litellm.sh` stops
  it.

CI runs both on every pull request, once with Ubuntu's bash 5 (`mac-dry-run`)
and once with bash 3.2.57 built from source (`bash 3.2 compatibility`).

## Honest status

This has been checked on Linux under bash 5 and bash 3.2.57, the version macOS
ships. It ran end to end with a fake `claude` and a real local LiteLLM on a test
port, and the arrow-key browser was driven through a pseudo-terminal under both
bash versions. It has **not been run on a real Mac yet**. Expect the first Mac
run to turn up small things, most likely in the terminal browser, the `~/.zshrc`
PATH line or the Node fallback.
