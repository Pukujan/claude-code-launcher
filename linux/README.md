# The Linux launcher

`linux/` starts the same proxy as `mac/` and `windows/`, offers the same 20
models, seats them through the same `apply_inferhub_seat.py`, and hands [CC] the
same environment. It exists so a Linux user has a Linux-named command and an
installer that does not assume macOS.

Owning issue: [#88](https://github.com/Pukujan/claude-code-launcher/issues/88)
(task CCL-0076).

## Quick start

```
linux/setup.sh            # install or repair (no sudo), then:
claude-acs                # pick a folder and models, start [CC]
claude-acs ~/code/thing   # skip the folder picker
linux/setup.sh --check    # report what is there, change nothing
linux/setup.sh --uninstall
```

First run installs what is missing — uv, a uv-managed Python 3.12, the pinned
LiteLLM venv under `shared/litellm/.litellm-venv`, and [CC] — asks once for the
InferHub key, and fetches the IRE model table. Later runs skip what is installed.

## Why this folder is thin

The launcher body lives in `mac/Launch Claude InferHub.command` and is **shared**,
not copied. That script is bash, already branches on `uname -s` to use XDG paths
off-macOS (logs under `$XDG_STATE_HOME/claude-inferhub`, state under
`$XDG_DATA_HOME/claude-inferhub`), and is exercised on Linux in CI
(`launcher-ci.yml`: `mac-dry-run` and the `bash 3.2` job both run on
`ubuntu-latest`). Duplicating ~1,200 lines here would only create drift, which is
the failure mode this repository keeps paying for.

So `linux/launch-claude-inferhub.sh` and `linux/stop-litellm.sh` are thin entries
that check the platform and the checkout, then `exec` the shared body. Everything
the Mac launcher documents applies unchanged: `CLAUDE_IH_PROJECT`,
`CLAUDE_IH_MAIN`, `CLAUDE_IH_ADVISOR`, `--non-interactive`,
`CCL_NONINTERACTIVE=1`, `--print-env json|dotenv`, `CLAUDE_IH_SETUP_ONLY=1`.

A follow-up (its own issue) proposes lifting the shared body into `shared/` so
`mac/` and `linux/` are both thin entries. That touches `mac/`, so it is
deliberately not done here.

## What is different from macOS

| Thing | macOS (`mac/setup.sh`) | Linux (`linux/setup.sh`) |
| --- | --- | --- |
| PATH line | always `~/.zshrc` | the rc file of `$SHELL`: `~/.bashrc`, `~/.zshrc`, or `~/.config/fish/config.fish` |
| fish | n/a | `fish_add_path ~/.local/bin` instead of `export PATH=...` |
| Missing tools | names the tool | names the tool **and** the install command for apt / dnf / pacman / zypper / apk |
| State and logs | `~/Library/...` | XDG paths (already handled by the shared body) |

Everything else — the keyless loopback proxy on `127.0.0.1:4000`, the model
table, the seat script, the folder picker, the `claude --model sonnet
--permission-mode bypassPermissions` command — is identical, because it is the
same code.

## Known limitation

If the official [CC] installer fails and npm is also missing, the shared body
stops with a message instead of installing Node (its `ensure_node` only knows how
to fetch a Node tarball on macOS). On Linux, install Node with your package
manager first. Fixing that properly means editing `mac/`, so it is left as a
follow-up rather than smuggled into this change.

## Containers (not this change)

A Docker or Podman image running the proxy — and optionally [CC] — would give
byte-for-byte replication across distributions and the cleanest CI story. It also
adds a container-runtime dependency, a bind-mount and UID-mapping story for the
project folder, a TTY story for the [CC] TUI, and a secret-passing story for the
InferHub key. For a single-user launcher whose pitch is "install uv, run one
command", the native path is lighter and keeps the one-command UX. If
replication across many machines matters later, it deserves its own issue.
