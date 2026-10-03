# InferHub Claude Code module notes (v0.2.0)

## Source of truth

**Agent Custom Setup (this repository) is the source of truth.**

- Canonical path: `modules/claude-code/inferhub-litellm/v0.2.0/`
- Desktop path `C:\Users\pujan\OneDrive\Desktop\configs\claude-code\` is a **deploy mirror**.
- After an accepted merge, sync **Desktop FROM ACS** (copy these launchers out to Desktop).
- Do **not** treat Desktop as SoT. Personal experiments on Desktop must come back through a PR into ACS before they are canonical.

See repo-root [`POLICY.md`](../../../../POLICY.md).

## What this is

A sanitized, versioned InferHub-only Claude Code launcher (v0.2.0 seal).
It seats main/advisor models through the local LiteLLM proxy and starts Claude Code with CKFF env cleared for the child process.

Version note: `0.1.0` is reserved on open PR #2 for a flat `modules/claude-code/` scaffold. This module uses the multi-setup layout `modules/<harness>/<setup-id>/v<semver>/` at **0.2.0**.

## Secrets stay outside this repo

- Desktop: `C:\Users\pujan\OneDrive\Desktop\configs\.env`
- InferHub (optional): `D:\claude\inferhub\.env`
- Never paste keys, tokens, cookies, or bak files into this repository.
- The launcher *reads* `LITELLM_MASTER_KEY` / `LITELLM_PROXY_KEY` at runtime from Desktop `configs\.env`; it does not embed them.

## Expected local layout

| Path | Role |
| --- | --- |
| `D:\claude\litellm` | Unified LiteLLM workbench (`Pukujan/litellm-ckff-ops`) |
| `D:\claude\inferhub` | InferHub-related env (optional for some seats) |
| `C:\Users\pujan\OneDrive\Desktop\configs\claude-code\` | Deploy mirror of these launchers (not SoT) |

## How to use

1. Ensure the LiteLLM proxy can start (`D:\claude\litellm\start-litellm.ps1`).
2. From this module directory (or the Desktop mirror after deploy), run `launch-claude-inferhub.cmd` (or the `.ps1`).
3. Pick MAIN model, optional ADVISOR, then a project folder under `D:\claude`.
4. Claude Code starts with `ANTHROPIC_BASE_URL=http://127.0.0.1:4000` and seat alias `sonnet`.

## Metadata

See `module.json` for `name`, `purpose`, `harness`, `created`/`updated`, `owning_issue`, `owning_agent`, `deploy_mirrors`, `version`, and `status`.
Bump `version` (new `v<semver>/` directory) when refreshing content; update `registry.json` and `updated` in the same PR.
