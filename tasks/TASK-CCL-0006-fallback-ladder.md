# TASK-CCL-0006 — Fallback ladder picker for main and advisor

<!-- continuity:task {"acceptance":["after each primary pick the launcher shows the default ladder; Enter accepts, numbers pick up to 3 in order, 0 means none","the default ladder comes from one function that falls back to the fixed chains when IRE is unavailable","main and advisor vendors (route prefixes) stay disjoint by default","the picked ladders reach a running keyless test proxy on a non-4000 port with no restart and read back correctly","a fault-injected primary gets one retry and the request lands on the next rung; the output is on issue #5","cx/gpt-6.1-sol is an opt-in pick with a max-price cap hook and is seated in Responses API mode","lint, mac-dry-run, python-tests and gates pass on the pull request"],"depends_on":["CCL-0002"],"goal":"Let Alex accept or pick up to three ordered fallbacks for the main and advisor seats at launch and apply them to the running proxy without a restart.","id":"CCL-0006","issue_url":"https://github.com/Pukujan/claude-code-launcher/issues/5","next_action":"Read the CI result on the pull request and record it on issue #5.","owner":"Alex; executor agent implements","priority":"P1","protocol_version":"0.1.0-draft","schema":"project-continuity.task.v1","status":"active","why":"The fallback chains were fixed in config, invisible at launch, and changing them meant editing files and restarting the proxy."} -->

- Status: active
- Owner: Alex; executor agent implements
- Priority: P1
- Depends on: CCL-0002 (merged)

## Goal

Let Alex accept or pick up to three ordered fallbacks for the main and advisor seats at launch and apply them to the running proxy without a restart.

## Why

The fallback chains were fixed in config, invisible at launch, and changing them meant editing files and restarting the proxy.

## Allowed files

- `shared/ladder/`, `shared/litellm/sitecustomize.py`, `shared/litellm/.gitignore`
- `windows/launch-claude-inferhub.ps1`, `mac/Launch Claude InferHub.command`
- `tests/test_ladder*.py`, `tests/e2e/`, `docs/HOOKS.md`, `SOURCES.md`, `checkpoints/CURRENT.md`, `tasks/`

## Human outcome

At launch Alex sees which models each seat falls back to, can change them in a few keystrokes, and the running proxy uses them right away.

## Scope and boundaries

- In scope: the scope list on issue #5, plus the opt-in `cx/gpt-6.1-sol` entry (task 5 hook).
- Out of scope: seat and shim routing (`apply_inferhub_seat.py`, `merge_litellm_config.py`, `inferhub_fallbacks.yaml` are unchanged), anything on 127.0.0.1:4000, the IRE module (CCL-0004).
- Dependencies/uncertainty: the stock chains share the `cbcn/` vendor, so the disjoint default leaves main with one fallback when the advisor is on `cbcn/`. Alex to confirm. The cx price cap value is still to be decided, and tool and stream support on cx are unconfirmed.

## Acceptance criteria

- [ ] after each primary pick the launcher shows the default ladder; Enter accepts, numbers pick up to 3 in order, 0 means none
- [ ] the default ladder comes from one function that falls back to the fixed chains when IRE is unavailable
- [ ] main and advisor vendors (route prefixes) stay disjoint by default
- [ ] the picked ladders reach a running keyless test proxy on a non-4000 port with no restart and read back correctly
- [ ] a fault-injected primary gets one retry and the request lands on the next rung; the output is on issue #5
- [ ] cx/gpt-6.1-sol is an opt-in pick with a max-price cap hook and is seated in Responses API mode
- [ ] lint, mac-dry-run, python-tests and gates pass on the pull request

## Related records

- Leaf issue: https://github.com/Pukujan/claude-code-launcher/issues/5. Parent: none. Depends on: #3 (CCL-0002, merged).
- Primary writer: executor agent for Alex. Branch: `task/CCL-0006-fallback-ladder`. As of 2026-10-03: active.
- PR and CI evidence: recorded on the issue.

## Checkpoint log

No checkpoints yet.
