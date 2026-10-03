# Claude Code + InferHub on a Mac

This is the Mac version of the Windows "launch Claude through InferHub" shortcut.
You double-click one file. It starts the local LiteLLM proxy, asks which project
folder you want, asks which models to use, and opens Claude Code in that folder
with every request going through the proxy to InferHub.

## First time

1. Get this repo onto the Mac. Cloning with git is the easy way, because Finder
   then trusts the file:

   ```bash
   mkdir -p ~/work && cd ~/work
   git clone https://github.com/Pukujan/agent-custom-setup.git
   open agent-custom-setup/modules/claude-code/inferhub-litellm-macos/v0.1.0
   ```

2. Double-click **Launch Claude InferHub.command**.

The first run takes a few minutes. It installs whatever is missing, all inside
your home folder and without asking for an admin password:

- Apple's Command Line Tools, but only if it has to download the LiteLLM
  workbench and git isn't there yet. macOS pops up its own installer. Let it
  finish, then double-click again.
- `uv`, which installs and manages Python for you
- Python 3.12, through uv
- the LiteLLM workbench (`Pukujan/litellm-ckff-ops`), cloned to
  `~/work/litellm-ckff-ops` if you don't have it, plus a venv inside it with
  the pinned LiteLLM version
- Claude Code, using Anthropic's official installer. If that fails, it falls
  back to npm, and gets Node from Homebrew or from nodejs.org first if it has to.

It then asks for your **InferHub API key**, just once. Nothing shows on screen
while you paste it. The key goes into `~/.config/inferhub/.env`, which only you
can read. The script also makes a local proxy key in the same file the first
time, so you don't have to.

The workbench repo is private, so the Mac has to be signed in to GitHub before
the first run. `brew install gh && gh auth login` does that. You can also clone
`litellm-ckff-ops` into `~/work` yourself.

## Every time after that

Double-click it again. Nothing gets reinstalled. If the proxy is already
running, the script skips straight to the questions:

1. **Folder**: `~/work` is listed first, then each folder inside it. Type its
   number, or `b` to pick any folder in Finder. Press Return to confirm.
2. **Main model**: the same Top 20 list as Windows. Press Return for the
   default, DeepSeek V4.1 Flash.
3. **Advisor model**: press Return for OFF (the default), or type a number.

Claude Code then opens in that folder.

## No clone, one line

If you'd rather paste one line into Terminal, this runs the same script
(once this is merged to `main`):

```bash
bash -c "$(curl -fsSL 'https://raw.githubusercontent.com/Pukujan/agent-custom-setup/main/modules/claude-code/inferhub-litellm-macos/v0.1.0/Launch%20Claude%20InferHub.command')"
```

Use `bash -c "$(curl ...)"` exactly like that, not `curl ... | bash`. The
pickers need your keyboard, and piping the script into bash would take it away.

## If the Mac complains

- **"cannot be opened because it is from an unidentified developer"**: this
  only happens when the file came from a browser download instead of git.
  Right-click the file, choose **Open**, then **Open** again. You only do this
  once. In Terminal, `xattr -d com.apple.quarantine "Launch Claude InferHub.command"`
  does the same thing.
- **"Permission denied"**: run `chmod +x "Launch Claude InferHub.command"`.
- **Anything else**: the error says what went wrong. The full log is in
  `~/Library/Logs/claude-inferhub/launcher.log`, and LiteLLM's own logs are in
  `~/work/litellm-ckff-ops/logs/`. Keys never go into either.

## Knobs (rarely needed)

| Variable | Default | What it changes |
| --- | --- | --- |
| `LITELLM_PORT` | `4000` | Proxy port. Tests use another port. |
| `LITELLM_DIR` | `~/work/litellm-ckff-ops` | Where the workbench lives |
| `CLAUDE_IH_WORK_ROOT` | `~/work` | Root of the folder picker |
| `LITELLM_HEALTH_TIMEOUT` | `300` | Seconds to wait for the proxy |
| `INFERHUB_TOP20_CSV` | (built-in list) | Real IRE Top 20 CSV, if you have one |
| `CLAUDE_IH_PROJECT`, `CLAUDE_IH_MAIN`, `CLAUDE_IH_ADVISOR` | (ask) | Skip a picker |

## Honest status

This has been checked on Linux under bash 5 and bash 3.2.57, the version macOS
ships. It ran end to end with a fake `claude` and a real local LiteLLM on a test
port. It has **not been run on a real Mac yet**. Expect the first Mac run to
turn up small things, most likely in the Finder picker, the Command Line Tools
prompt, or the Node fallback.
