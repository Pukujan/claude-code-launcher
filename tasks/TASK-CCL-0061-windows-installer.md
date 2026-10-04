# TASK-CCL-0061 — one-command Windows installer for a friend

<!-- continuity:task {"acceptance": ["one command (irm ... | iex) plus an InferHub key installs everything into %LOCALAPPDATA%\\claude-code-launcher and leaves a working claude-inferhub command", "the proxy picks a free port from 4000 up, never a port held by another program, and Claude's base URL follows it", "packaged mode reads no Alex-specific paths and the key is never printed or logged", "spec, property-based, metamorphic and Windows end-to-end tests pass in CI, and gates (with hotload_check) pass", "install.ps1 is attached to the v1.0.0-windows release"], "depends_on": [], "goal": "Ship a one-command Windows installer so a friend needs only an InferHub key.", "id": "CCL-0061", "issue_url": "https://github.com/Pukujan/claude-code-launcher/issues/61", "next_action": "Write the red tests from docs/specs/windows-package.md and commit them.", "owner": "Alex; executor agent implements", "priority": "P1", "protocol_version": "0.1.0-draft", "schema": "project-continuity.task.v1", "status": "active", "why": "There is no installer today; the launcher assumes Alex's PC (paths, port 4000, pre-installed tools)."} -->

- Status: active
- Owner: Alex; executor agent implements
- Priority: P1
- Depends on: none
- Leaf issue: [#61](https://github.com/Pukujan/claude-code-launcher/issues/61); parent: none
- Primary writer: executor-claude-code-launcher; branch `ccl-0061-windows-installer`

## Goal

Ship a one-command Windows installer so a friend needs only an InferHub key.

## Why

There is no installer today; the launcher assumes Alex's PC (paths, port 4000, pre-installed tools).

## Allowed files

- `windows/` (new `install.ps1`, launcher and proxy scripts), `shared/claude/`, `shared/litellm/web_search.py`,
  `shared/litellm/sitecustomize.py`, `shared/litellm/ccl_identity.py`, `shared/ire/ire_fetch.py`
- `docs/specs/windows-package.md`, `docs/`, `README.md`, `windows/README-friend.md`, `SOURCES.md`
- `tests/`, `.github/workflows/launcher-ci.yml`, `tasks/`, `checkpoints/CURRENT.md`, `.coord/`

## Human outcome

Alex's friend runs one PowerShell line, pastes his InferHub key, and types `claude-inferhub` to get Claude Code
through the local proxy with all four slots and web search working, even if he already runs a LiteLLM on 4000.

## Scope and boundaries

- In scope: the spec in `docs/specs/windows-package.md`.
- Out of scope: seat and slot routing, macOS, a zip or exe, uninstalling prerequisites, Alex's live proxy on 4000.

## Acceptance criteria

- [ ] one command (irm ... | iex) plus an InferHub key (and an optional, free TinyFish key) installs everything into %LOCALAPPDATA%\claude-code-launcher and leaves a working claude-inferhub command
- [ ] the proxy picks a free port from 4000 up, never a port held by another program, and Claude's base URL follows it
- [ ] packaged mode reads no Alex-specific paths and the key is never printed or logged
- [ ] spec, property-based, metamorphic and Windows end-to-end tests pass in CI, and gates (with hotload_check) pass
- [ ] install.ps1 is attached to the v1.0.0-windows release

## Related records

- Issue [#61](https://github.com/Pukujan/claude-code-launcher/issues/61) (assessment comment and Alex's go).

## Checkpoint log

- 2026-10-04 6:20 PM ET: spec written and linked on #61; claim taken in `.coord`.
- 2026-10-04 6:35 PM ET: red tests committed (`6f7c87b`): pytest 31 failed + 2 collection errors, Pester 166 failed.
- 2026-10-04 6:58 PM ET: implementation in; locally pytest 276 passed / 7 skipped, Pester 166 passed / 8 skipped (E2E is Windows only), ruff and PSScriptAnalyzer clean. Waiting on CI, including the Windows job.
- 2026-10-04 7:20 PM ET: CI green, including the Windows job (Pester on PowerShell 5.1 and 7, real install, coexistence with another LiteLLM, uninstall).
- 2026-10-04 7:28 PM ET: Alex asked for a TinyFish key prompt. Spec updated and red tests committed (`166ad6e`): pytest 4 failed, Pester 66 failed.
- 2026-10-04 7:40 PM ET: TinyFish key implemented; locally pytest 280 passed / 7 skipped, Pester 235 passed / 8 skipped (E2E).
