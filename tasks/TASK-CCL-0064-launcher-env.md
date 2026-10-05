# TASK-CCL-0064 — one .env in the launcher folder

<!-- continuity:task {"acceptance": ["with <repo>\\.env present, the Windows launcher and start-litellm.ps1 load only that file (plus shared\\litellm\\.env.local), even when the IRE and Desktop env files exist", "with it missing, both fall back to the old order unchanged", "tests for the lookup order, for .env being gitignored and for no key value in any output pass, and the required checks (gates with hotload_check, lint, mac-dry-run, python-tests, bash 3.2 compatibility) are green", "on the PC, a test proxy on port 4017 starts from the new .env only, web search returns results and a sonnet request succeeds; then it is stopped"], "depends_on": [], "goal": "Read every launcher key from one gitignored .env in the launcher folder, with the old files only as a fallback.", "id": "CCL-0064", "issue_url": "https://github.com/Pukujan/claude-code-launcher/issues/64", "next_action": "After the PR merges: git pull on the PC, copy the keys into the launcher .env, drop CCL_ENV_ALIASES from .env.local, verify on a test proxy on port 4017, close issue #64.", "owner": "Alex; executor agent implements", "priority": "P2", "protocol_version": "0.1.0-draft", "schema": "project-continuity.task.v1", "status": "active", "why": "The launcher took its InferHub key from another project's .env and its web search keys from a large personal Desktop file read on every proxy start."} -->

- Status: active
- Owner: Alex; executor agent implements
- Priority: P2
- Depends on: none
- Leaf issue: [#64](https://github.com/Pukujan/claude-code-launcher/issues/64); parent: none
- Primary writer: executor-claude-code-launcher (coder1; the seat is held for CCL-0063); branch `ccl-0064-launcher-env`

## Goal

Read every launcher key from one gitignored .env in the launcher folder, with the old files only as a fallback.

## Why

The launcher took its InferHub key from another project's .env and its web search keys from a large personal Desktop file read on every proxy start.

## Allowed files

- `windows/launch-claude-inferhub.ps1`, `windows/litellm/start-litellm.ps1`
- `tests/test_launcher_env.py`, `README.md`, `.env.example`, `docs/HOOKS.md`, `SOURCES.md`
- `tasks/`, `checkpoints/CURRENT.md`, `.coord/assignment.json`

## Human outcome

Alex keeps every key the launcher needs in one file next to it, under standard names, and the launcher stops reaching into the IRE project and the Desktop secrets file.

## Scope and boundaries

- In scope: the non-packaged lookup in the two Windows scripts, tests, docs. The Mac launcher already reads `<repo>/.env` first and `claude-env-exec.mjs` reads no keys, so neither changes.
- Out of scope: packaged mode, seat and slot routing, the live proxy on port 4000, editing or removing the original env files.

## Acceptance criteria

- [ ] with <repo>\.env present, the Windows launcher and start-litellm.ps1 load only that file (plus shared\litellm\.env.local), even when the IRE and Desktop env files exist
- [ ] with it missing, both fall back to the old order unchanged
- [ ] tests for the lookup order, for .env being gitignored and for no key value in any output pass, and the required checks (gates with hotload_check, lint, mac-dry-run, python-tests, bash 3.2 compatibility) are green
- [ ] on the PC, a test proxy on port 4017 starts from the new .env only, web search returns results and a sonnet request succeeds; then it is stopped

## Related records

- Issue [#64](https://github.com/Pukujan/claude-code-launcher/issues/64).

## Checkpoint log

- 2026-10-04 8:20 PM ET: issue opened; joined as coder1 (seat held by the CCL-0063 session). Red tests committed (`134e427`): 6 failed, 3 passed.
- 2026-10-04 8:35 PM ET: lookup change in; locally the new tests 9 passed, the full suite 289 passed / 7 skipped, ruff and PSScriptAnalyzer clean.
