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

2. Double-click **Launch Claude InferHub.command**.

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

Double-click it again. Nothing gets reinstalled. If the proxy is already
running, the script skips straight to the questions:

1. **Folder**: `~/work` is listed first, then each folder inside it. Type its
   number, or `b` to pick any folder in Finder. Press Return to confirm.
2. **Main model**: the same Top 20 list as Windows. Press Return for the
   default, DeepSeek V4.1 Flash.
3. **Advisor model**: press Return for OFF (the default), or type a number.

Claude Code then opens in that folder. To update the launcher, `git pull`.

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
| `CLAUDE_IH_PROJECT`, `CLAUDE_IH_MAIN`, `CLAUDE_IH_ADVISOR` | (ask) | Skip a picker |

## Tests

`mac/tests/dry_run.sh [port] [bash]` copies `mac/` and `shared/` into a temp
folder, runs the launcher with a fake `claude` and a real LiteLLM on a test port
(4100 by default; it refuses 4000), and checks the arguments, folder and
environment the fake received. It also checks that the proxy listens on
127.0.0.1 and that the picked seat was hot-reloaded into it without a key. CI
runs it on every pull request.

## Honest status

This has been checked on Linux under bash 5 and bash 3.2.57, the version macOS
ships. It ran end to end with a fake `claude` and a real local LiteLLM on a test
port. It has **not been run on a real Mac yet**. Expect the first Mac run to
turn up small things, most likely in the Finder picker or the Node fallback.
