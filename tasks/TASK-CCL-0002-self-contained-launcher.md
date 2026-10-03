# TASK-CCL-0002 — Self-contained launcher

<!-- continuity:task {"acceptance":["windows/, mac/ and shared/litellm/ are present and both launchers run the proxy from shared/litellm with no litellm-ckff-ops checkout","SOURCES.md lists every copied file with source repo, path, commit SHA and source SHA-256","the proxy runs keyless, binds 127.0.0.1 only, and the seat hot reload works without a key from loopback","stop-litellm.ps1 stops only the PID that start-litellm.ps1 recorded","only .env.example is tracked; docs/PARITY.md and docs/HOOKS.md exist; ACS v0.2.0 is under history/","lint, mac-dry-run, python-tests and gates pass on the pull request"],"depends_on":[],"goal":"Move the Windows and Mac launchers and the shared LiteLLM proxy files into this repository so either launcher runs from one checkout, with sources recorded and CI covering lint, the Mac dry run and Python unit tests.","id":"CCL-0002","issue_url":"https://github.com/Pukujan/claude-code-launcher/issues/3","next_action":"Open the pull request from task/CCL-0002-self-contained-launcher and read the CI result.","owner":"Alex; executor agent implements","priority":"P1","protocol_version":"0.1.0-draft","schema":"project-continuity.task.v1","status":"active","why":"The launcher lived in three drifting places and the Mac port had to clone litellm-ckff-ops to work."} -->

- Status: active
- Owner: Alex; executor agent implements
- Priority: P1
- Depends on: none

## Goal

Move the Windows and Mac launchers and the shared LiteLLM proxy files into this repository so either launcher runs from one checkout, with sources recorded and CI covering lint, the Mac dry run and Python unit tests.

## Why

The launcher lived in three drifting places and the Mac port had to clone litellm-ckff-ops to work.

## Allowed files

- `windows/`, `mac/`, `shared/litellm/`, `history/`, `docs/`, `tests/`
- `SOURCES.md`, `README.md`, `.env.example`, `.gitattributes`, `ruff.toml`, `PSScriptAnalyzerSettings.psd1`
- `.github/workflows/launcher-ci.yml`, `checkpoints/CURRENT.md`, `tasks/`

## Human outcome

Alex can start Claude Code on either machine from one checkout of this repository, and any later fix to the launcher has one place to land.

## Scope and boundaries

- In scope: the scope list on issue #3.
- Out of scope: seat routing changes, anything on 127.0.0.1:4000, `shared/ire/`, the fallback ladder picker.
- Dependencies/uncertainty: depends on CCL-0001 (merged). The PC launcher will be re-synced after another worker's fixes. Windows edits are linted but not run on Windows.

## Acceptance criteria

- [ ] windows/, mac/ and shared/litellm/ are present and both launchers run the proxy from shared/litellm with no litellm-ckff-ops checkout
- [ ] SOURCES.md lists every copied file with source repo, path, commit SHA and source SHA-256
- [ ] the proxy runs keyless, binds 127.0.0.1 only, and the seat hot reload works without a key from loopback
- [ ] stop-litellm.ps1 stops only the PID that start-litellm.ps1 recorded
- [ ] only .env.example is tracked; docs/PARITY.md and docs/HOOKS.md exist; ACS v0.2.0 is under history/
- [ ] lint, mac-dry-run, python-tests and gates pass on the pull request

## Evidence and sources

Link repository state at a revision and cite external factual claims directly. Record commands and results for claims that need verification.

## Reproduction details (only when needed)

Starting revision, material inputs/configuration, runtime, exact command or prompt, observed result, and limitations.

## Related records

- Leaf issue: https://github.com/Pukujan/claude-code-launcher/issues/3. Parent: none. Depends on: #1 (closed).
- Primary writer: executor agent for Alex. Branch: `task/CCL-0002-self-contained-launcher`. As of 2026-10-03: active.
- PR and CI evidence: recorded on the issue.

## Checkpoint log

No checkpoints yet.

## Handoff

Read PROJECT → CURRENT → this task → minimum relevant spec. Checkpoint before stopping.
