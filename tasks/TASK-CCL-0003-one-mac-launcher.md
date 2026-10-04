# TASK-CCL-0003 — One Mac launcher

<!-- continuity:task {"acceptance":["macos/ and .github/workflows/macos-shim.yml are gone; mac/ has setup.sh with claude-acs, the terminal folder navigation in mac/lib/nav.sh and the live IRE model table from shared/ire/ire_fetch.py","shared/ire/ire_fetch.py reads the IRE frontier files as optional (missing is fine) and keeps system_prompt_handling and preferred_endpoint as IRE wrote them","the proxy stays keyless on 127.0.0.1, with LITELLM_DANGEROUSLY_PERMIT_WEAK_OR_UNSET_MASTER_KEY set for the proxy process only, in both launchers","shared/litellm matches litellm-ckff-ops de69e68 for the routing files (fast seat aliases, BOM fix) and both launchers set ANTHROPIC_SMALL_FAST_MODEL=small-fast","mac/tests/unit_tests.sh and mac/tests/dry_run.sh pass under bash 5 and bash 3.2.57","bash 3.2 compatibility is a required check on main, and gates, lint, mac-dry-run, bash 3.2 compatibility and python-tests pass on the pull request"],"depends_on":[],"goal":"Have one Mac launcher in mac/ with the macos/ shim's installer, terminal folder navigation and live IRE model table, then delete macos/, with the bash 3.2 check fixed and required on main.","id":"CCL-0003","issue_url":"https://github.com/Pukujan/claude-code-launcher/issues/11","next_action":"Open the pull request from task/CCL-0003-one-mac-launcher, add bash 3.2 compatibility to the required checks and read the CI result.","owner":"Alex; executor agent implements","priority":"P1","protocol_version":"0.1.0-draft","schema":"project-continuity.task.v1","status":"active","why":"Two Mac launchers did overlapping things in different ways, and the bash 3.2 check that should have caught problems was failing and not required."} -->

- Status: active
- Owner: Alex; executor agent implements
- Priority: P1
- Depends on: none

## Goal

Have one Mac launcher in mac/ with the macos/ shim's installer, terminal folder navigation and live IRE model table, then delete macos/, with the bash 3.2 check fixed and required on main.

## Why

Two Mac launchers did overlapping things in different ways, and the bash 3.2 check that should have caught problems was failing and not required.

## Allowed files

- `mac/`, `macos/` (deleted), `shared/ire/`, `shared/litellm/`, `windows/launch-claude-inferhub.ps1`, `windows/litellm/start-litellm.ps1`, `tests/`
- `README.md`, `SOURCES.md`, `docs/PARITY.md`, `docs/HOOKS.md`
- `.github/workflows/launcher-ci.yml`, `.github/workflows/macos-shim.yml` (deleted), `checkpoints/CURRENT.md`, `tasks/`

## Human outcome

One Mac launcher to run, fix and test. A Mac user can install it with one script, reach any folder from the terminal, and see the current IRE picks, and CI checks it under the bash that macOS ships.

## Scope and boundaries

- In scope: the scope list on issue #11, plus the parent's later asks: use `shared/ire/ire_fetch.py` (PR #10) instead of the tokenless fetch, the keyless flag for LiteLLM 1.104, the haiku/small-fast aliases, and a re-sync of shared/litellm to litellm-ckff-ops `de69e68` (PR #42).
- Out of scope: anything on 127.0.0.1:4000, the fallback ladder picker (#5), switching the Windows picker to the live table, routing cx frontier routes over `/v1/responses`.
- Dependencies/uncertainty: depends on CCL-0002 (merged) and PR #10 (merged). Nothing here has run on a real Mac; Windows edits are linted only.

## Acceptance criteria

- [ ] macos/ and .github/workflows/macos-shim.yml are gone; mac/ has setup.sh with claude-acs, the terminal folder navigation in mac/lib/nav.sh and the live IRE model table from shared/ire/ire_fetch.py
- [ ] shared/ire/ire_fetch.py reads the IRE frontier files as optional (missing is fine) and keeps system_prompt_handling and preferred_endpoint as IRE wrote them
- [ ] the proxy stays keyless on 127.0.0.1, with LITELLM_DANGEROUSLY_PERMIT_WEAK_OR_UNSET_MASTER_KEY set for the proxy process only, in both launchers
- [ ] shared/litellm matches litellm-ckff-ops de69e68 for the routing files (fast seat aliases, BOM fix) and both launchers set ANTHROPIC_SMALL_FAST_MODEL=small-fast
- [ ] mac/tests/unit_tests.sh and mac/tests/dry_run.sh pass under bash 5 and bash 3.2.57
- [ ] bash 3.2 compatibility is a required check on main, and gates, lint, mac-dry-run, bash 3.2 compatibility and python-tests pass on the pull request

## Evidence and sources

Link repository state at a revision and cite external factual claims directly. Record commands and results for claims that need verification.

## Reproduction details (only when needed)

Starting revision, material inputs/configuration, runtime, exact command or prompt, observed result, and limitations.

## Related records

- Leaf issue: https://github.com/Pukujan/claude-code-launcher/issues/11. Parent: none. Depends on: #3 (closed), PR #10 (merged).
- Primary writer: executor agent for Alex. Branch: `task/CCL-0003-one-mac-launcher`. As of 2026-10-03: active.
- PR and CI evidence: recorded on the issue.

## Checkpoint log

No checkpoints yet.

## Handoff

Read PROJECT → CURRENT → this task → minimum relevant spec. Checkpoint before stopping.
