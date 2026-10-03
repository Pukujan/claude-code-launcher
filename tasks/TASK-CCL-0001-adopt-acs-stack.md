# TASK-CCL-0001 — Adopt the ACS stack

<!-- continuity:task {"acceptance":["PCM continuity files and the nine pinned schemas are present and `continuity validate` prints VALID","the CGM 0.5.12 adapter lists all eight modules and the pinned validate_content_system.py prints VALID","the OIO 0.1.0 installer output is present and `oio_installer.py --check` prints VALID","the ACS .coord assignment, boss claim and stack-manifest.json are pinned to release train 2026-10-01","the pinned ACS hotload_check.py passes against this repository","the required `gates` check reports success on the pull request","no secrets are stored"],"depends_on":[],"goal":"Install the ACS multi-agent-hotload 0.1.0 stack (PCM 0.6.0, CGM 0.5.12, OIO 0.1.0) pinned to release train 2026-10-01 and prove it with the pinned validators in a required gates check.","id":"CCL-0001","issue_url":"https://github.com/Pukujan/claude-code-launcher/issues/1","next_action":"Open the pull request from task/CCL-0001-adopt-acs-stack and read the gates result.","owner":"Alex; executor agent installs","priority":"P0","protocol_version":"0.1.0-draft","schema":"project-continuity.task.v1","status":"active","why":"The launcher repository needs continuity files, an issue form and a required CI gate before any launcher code lands."} -->

- Status: active
- Owner: Alex; executor agent installs
- Priority: P0
- Depends on: none

## Goal

Install the ACS multi-agent-hotload 0.1.0 stack (PCM 0.6.0, CGM 0.5.12, OIO 0.1.0) pinned to release train 2026-10-01 and prove it with the pinned validators in a required gates check.

## Why

The launcher repository needs continuity files, an issue form and a required CI gate before any launcher code lands.

## Allowed files

- `.continuity/`, `schemas/v1/`, `PROJECT.md`, `AGENTS.md`, `HANDOFF.md`, `checkpoints/CURRENT.md`, `tasks/`
- `.content-system/`, `.oio/`, `.coord/`, `stack-manifest.json`
- `.github/ISSUE_TEMPLATE/`, `.github/scripts/`, `.github/workflows/`, `.gitignore`

## Human outcome

A fresh agent opening this repository finds the project contract, the current checkpoint and an issue form, and a broken change cannot reach `main` because the `gates` check has to pass first.

## Scope and boundaries

- In scope: the stack install, copied from `Pukujan/frontend-bakeoff` PR #2 and `Pukujan/recipe-box` REPRODUCE.md.
- Out of scope: the launcher itself (a separate issue).
- Dependencies/uncertainty: none. `README.md` already existed, so PCM was initialised in a scratch folder and its files copied in, which is the overlay route PCM documents for that case.

## Acceptance criteria

- [ ] PCM continuity files and the nine pinned schemas are present and `continuity validate` prints VALID
- [ ] the CGM 0.5.12 adapter lists all eight modules and the pinned validate_content_system.py prints VALID
- [ ] the OIO 0.1.0 installer output is present and `oio_installer.py --check` prints VALID
- [ ] the ACS .coord assignment, boss claim and stack-manifest.json are pinned to release train 2026-10-01
- [ ] the pinned ACS hotload_check.py passes against this repository
- [ ] the required `gates` check reports success on the pull request
- [ ] no secrets are stored

## Evidence and sources

Link repository state at a revision and cite external factual claims directly. Record commands and results for claims that need verification.

## Reproduction details (only when needed)

Starting revision, material inputs/configuration, runtime, exact command or prompt, observed result, and limitations.

## Related records

- Leaf issue: https://github.com/Pukujan/claude-code-launcher/issues/1. Parent: none. Dependencies: none.
- Primary writer: executor agent for Alex. Branch: `task/CCL-0001-adopt-acs-stack`. As of 2026-10-03: active.
- PR and CI evidence: recorded on the issue once the `gates` check runs.

## Checkpoint log

No checkpoints yet.

## Handoff

Read PROJECT → CURRENT → this task → minimum relevant spec. Checkpoint before stopping.
