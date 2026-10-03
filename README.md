# claude-code-launcher

The launcher that starts Claude Code on Alex's machines, routed through a local
LiteLLM proxy to InferHub. This repository is where the Windows and Mac launchers
live from now on.

## Platforms

| Path | What |
|---|---|
| [`macos/`](macos/) | macOS installer, launcher, folder navigation, live IRE model table |

## What the shim does

Claude Code talks to Anthropic's API by default. This puts a local
[LiteLLM](https://github.com/BerriAI/litellm) proxy on `127.0.0.1:4000` that maps
Claude Code's model names onto [InferHub](https://inferhub.dev) routes, so Claude
Code runs against whichever model you pick without Anthropic billing.

The model table is **fetched live** from
[`inference-recommendation-engine`](https://github.com/Pukujan/inference-recommendation-engine)
and cached, so it tracks the current recommendation snapshot instead of going
stale in a hardcoded table.

## Quick start (macOS)

```bash
git clone https://github.com/Pukujan/claude-code-launcher.git
cd claude-code-launcher/macos
./setup.sh
claude-acs
```

`setup.sh` is idempotent, needs no `sudo`, and installs only what is missing.
See [`macos/README.md`](macos/README.md) for the full detail.

## Secrets policy

No credentials in this repository, ever. The InferHub key lives at
`~/.config/inferhub/.env` with mode 600, outside the checkout, and is read by
path at runtime. The proxy runs without a LiteLLM master key and Claude Code
receives a dummy value it never validates, so the real key is not duplicated into
the Claude process, a settings file, or a commit.

## Contribution

The launcher code arrives through pull requests. Nothing is committed to `main`
directly. CI runs `bash -n`, shellcheck (warnings fail), both offline test suites,
an explicit bash 3.2 build (macOS ships 3.2), a live check that the IRE model
table is still fetchable, and a secret scan.