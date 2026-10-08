# TASK-CCL-0082 — race the next model when the first one stays silent

<!-- continuity:task {"acceptance": ["A streaming messages call keeps the first model when it writes a text or thinking token before its silence budget, and does not open the next rung.", "When the first model stays silent past its budget, the next rung is raced on the original prompt and the first content token is the only stream released.", "A quiet or hard-failed rung is benched, the bench doubles, and the last rung is never benched. After the bench ends that model is first again.", "After a content token, a long gap ends the turn and does not splice another model.", "CCL_STALL_HEDGE=0 leaves the request on the normal proxy path. Unit tests cover this without binding port 4000."], "depends_on": ["CCL-0021"], "goal": "When a slot's first model stays silent, race the next one and try the quiet model again later.", "id": "CCL-0082", "issue_url": "https://github.com/Pukujan/claude-code-launcher/issues/109", "next_action": "Read the required CI result on the pull request.", "owner": "Alex; executor agent implements", "priority": "P1", "protocol_version": "0.1.0-draft", "schema": "project-continuity.task.v1", "status": "active", "why": "Silence is not a failure until request_timeout, so a stuck planner stays on the quiet model instead of moving to the next rung and trying the quiet one again later."} -->

- Status: active
- Owner: Alex; executor agent implements
- Priority: P1
- Depends on: CCL-0021
- Leaf issue: [#109](https://github.com/Pukujan/claude-code-launcher/issues/109); parent: [#53](https://github.com/Pukujan/claude-code-launcher/issues/53); dependencies: none
- Primary writer: implementation session; branch: `ccl-0082-stall-hedge`

## Goal

When a slot's first model stays silent, race the next one and try the quiet model again later.

## Why

Silence is not a failure until request_timeout, so a stuck planner stays on the quiet model instead of moving to the next rung and trying the quiet one again later.

## Allowed files

- `shared/litellm/stall_hedge.py`, `shared/litellm/sitecustomize.py`
- `docs/HOOKS.md`
- `tests/test_stall_hedge.py`
- `tasks/`, `checkpoints/CURRENT.md`

## Human outcome

When the planner's first model sits quiet, Claude Code gets the next model's answer as one stream. The quiet model is offered the next plan again after a short bench.

## Scope and boundaries

- In scope: hold a streaming `/v1/messages` reply until a text or thinking token, race the next rung on the original prompt, bench a silent or hard-failed rung with a doubling delay, and let that rung lead again on a later real call. Thresholds in code are the proposed starting values (20 s floor, 90 s cap, 30 s bench doubling to 10 min, 120 s gap after the first token).
- Out of scope: changing saved slot order (`inferhub_seat.json`, `inferhub_fallbacks.yaml`), `request_timeout`, `stream_timeout`, splicing a second model onto text the client has already seen, and any change to the live proxy on port 4000.

## Acceptance criteria

- [ ] A streaming messages call keeps the first model when it writes a text or thinking token before its silence budget, and does not open the next rung.
- [ ] When the first model stays silent past its budget, the next rung is raced on the original prompt and the first content token is the only stream released.
- [ ] A quiet or hard-failed rung is benched, the bench doubles, and the last rung is never benched. After the bench ends that model is first again.
- [ ] After a content token, a long gap ends the turn and does not splice another model.
- [ ] `CCL_STALL_HEDGE=0` leaves the request on the normal proxy path. Unit tests cover this without binding port 4000.

## Related records

- Leaf issue [#109](https://github.com/Pukujan/claude-code-launcher/issues/109); parent [#53](https://github.com/Pukujan/claude-code-launcher/issues/53).

## Checkpoint log

No checkpoints yet.
