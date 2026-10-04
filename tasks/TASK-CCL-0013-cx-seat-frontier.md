# TASK-CCL-0013 — cx primaries in Responses mode, hand-picked ladders, frontier list

<!-- continuity:task {"acceptance":["a cx/ seat primary is written as openai/responses/cx/...; every other route's seat output is byte-identical to before (golden test)","hand-picked fallbacks are kept even when they share a vendor with the other seat, with a one-line warning; the disjoint rule shapes defaults only","every picker (primaries and fallbacks, main and advisor, Windows and Mac) can show the IRE Top 20 or the IRE frontier list, with price per 1M and rows over $0.10 marked","ire_fetch.py adds an optional cached frontier key ([] when missing) and leaves the existing keys unchanged","one tiny request with cx/gpt-6.1-sol as main primary answers on a keyless non-4000 test proxy on the PC","lint, mac-dry-run, python-tests and gates pass on the pull request"],"depends_on":["CCL-0006"],"goal":"Seat cx primaries in Responses mode, honor hand-picked ladders, and let Alex pick from the Top 20 or the frontier list.","id":"CCL-0013","issue_url":"https://github.com/Pukujan/claude-code-launcher/issues/13","next_action":"Open the pull request and read the CI result.","owner":"Alex; executor agent implements","priority":"P1","protocol_version":"0.1.0-draft","schema":"project-continuity.task.v1","status":"active","why":"A cx primary lost its system prompt over chat completions, the picker refused shared-vendor hand picks, and the frontier models could not be picked at all."} -->

- Status: active
- Owner: Alex; executor agent implements
- Priority: P1
- Depends on: CCL-0006 (merged)

## Goal

Seat cx primaries in Responses mode, honor hand-picked ladders, and let Alex pick from the Top 20 or the frontier list.

## Why

A cx primary lost its system prompt over chat completions, the picker refused shared-vendor hand picks, and the frontier models could not be picked at all.

## Allowed files

- `shared/litellm/scripts/apply_inferhub_seat.py` (cx only, approved by Alex), `shared/litellm/scripts/merge_litellm_config.py`
- `shared/ire/`, `shared/ladder/`, `windows/launch-claude-inferhub.ps1`, `mac/Launch Claude InferHub.command` (a minimal hook)
- `tests/`, `tasks/`, `checkpoints/CURRENT.md`

## Human outcome

Alex can seat a cx model as a primary and its system prompt still reaches the model. His hand-picked fallbacks are kept as he typed them. He can choose from either IRE list and see each price.

## Scope and boundaries

- In scope: the goal list on issue #13.
- Out of scope: non-cx routing, anything on 127.0.0.1:4000, the macos/ to mac/ merge.
- Dependencies/uncertainty: the cx price cap value is still to be decided.

## Acceptance criteria

- [ ] a cx/ seat primary is written as openai/responses/cx/...; every other route's seat output is byte-identical to before (golden test)
- [ ] hand-picked fallbacks are kept even when they share a vendor with the other seat, with a one-line warning; the disjoint rule shapes defaults only
- [ ] every picker (primaries and fallbacks, main and advisor, Windows and Mac) can show the IRE Top 20 or the IRE frontier list, with price per 1M and rows over $0.10 marked
- [ ] ire_fetch.py adds an optional cached frontier key ([] when missing) and leaves the existing keys unchanged
- [ ] one tiny request with cx/gpt-6.1-sol as main primary answers on a keyless non-4000 test proxy on the PC
- [ ] lint, mac-dry-run, python-tests and gates pass on the pull request

## Related records

- Leaf issue: https://github.com/Pukujan/claude-code-launcher/issues/13. Follows #5 (CCL-0006).
- Primary writer: executor agent for Alex. Branch: `task/CCL-0013-cx-seat-responses`.

## Checkpoint log

No checkpoints yet.
