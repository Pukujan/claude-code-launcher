# TASK-CCL-0021 — bench a model after it uses up its retries

<!-- continuity:task {"acceptance": ["a seat or rung that fails all its retries is benched for cooldown_s and later requests skip it until the bench ends", "bad requests and connection errors never bench; a running bench is not extended", "unit tests cover the bench logic and assert the generated config carries cooldown_time on seats and rungs with cooldowns enabled", "lint, mac-dry-run, python-tests and gates pass on the pull request"], "depends_on": ["CCL-0006"], "goal": "Bench a model once it has used up its retries, so later requests skip it for cooldown_s.", "id": "CCL-0021", "issue_url": "https://github.com/Pukujan/claude-code-launcher/issues/21", "next_action": "Open the pull request and read the CI result.", "owner": "Alex; executor agent implements", "priority": "P1", "protocol_version": "0.1.0-draft", "schema": "project-continuity.task.v1", "status": "active", "why": "On the proxy LiteLLM 1.103 counts all retries of one request as a single failure, so allowed fails 3 never benched a dead primary."} -->

- Status: active
- Owner: Alex; executor agent implements
- Priority: P1
- Depends on: CCL-0006 (merged)

## Goal

Bench a model once it has used up its retries, so later requests skip it for cooldown_s.

## Why

On the proxy LiteLLM 1.103 counts all retries of one request as a single failure, so allowed fails 3 never benched a dead primary.

## Allowed files

- `shared/litellm/bench_after_retries.py`, `shared/litellm/sitecustomize.py`
- `shared/ladder/README.md`, `SOURCES.md`
- `tests/`, `tasks/`, `checkpoints/CURRENT.md`

## Human outcome

When a model is down, Alex waits through its retries once. After that his requests go straight to the next rung for 3 minutes, and then the 1st model gets another try.

## Scope and boundaries

- In scope: the goal on issue #21.
- Out of scope: `windows/launch-claude-inferhub.ps1` (another worker is editing it) and testing on the PC (Alex's call: unit tests and CI only).

## Acceptance criteria

- [ ] A seat or rung that fails all its retries is benched for `cooldown_s`, and later requests skip it until the bench ends.
- [ ] Bad requests and connection errors never bench, and a running bench is not extended.
- [ ] Unit tests cover the bench logic and assert the generated config carries `cooldown_time` on seats and rungs, with cooldowns enabled.
- [ ] Lint, mac-dry-run, python-tests and gates pass on the pull request.

## Related records

- Issue [#21](https://github.com/Pukujan/claude-code-launcher/issues/21); failure policy from issue #16 (PR #17); ladder from issue #5.

## Checkpoint log

No checkpoints yet.
