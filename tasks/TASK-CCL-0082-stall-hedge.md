# TASK-CCL-0082 — race the next model when the first one stays silent

<!-- continuity:task {"acceptance": ["A streaming messages call keeps the first model when it writes a text or thinking token before its silence budget, and does not open the next rung.", "When the first model stays silent past its budget, the next rung is raced on the original prompt and the first content token is the only stream released.", "A quiet or hard-failed rung is benched, the bench doubles, and the last rung is never benched. After the bench ends that model is first again.", "After a content token, a long gap ends the turn and does not splice another model.", "CCL_STALL_HEDGE=0 leaves the request on the normal proxy path. Unit tests cover this without binding port 4000."], "depends_on": ["CCL-0021"], "goal": "When a slot's first model stays silent, race the next one and try the quiet model again later.", "id": "CCL-0082", "issue_url": "https://github.com/Pukujan/claude-code-launcher/issues/109", "next_action": "none; issue #109 closed after PR #110 merged as 3c7d973 and its replay follow-up PR #112 merged as 2faf4a0.", "owner": "Alex; executor agent implements", "priority": "P1", "protocol_version": "0.1.0-draft", "schema": "project-continuity.task.v1", "status": "completed", "why": "Silence is not a failure until request_timeout, so a stuck planner stays on the quiet model instead of moving to the next rung and trying the quiet one again later."} -->

- Status: completed
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

- [x] A streaming messages call keeps the first model when it writes a text or thinking token before its silence budget, and does not open the next rung.
- [x] When the first model stays silent past its budget, the next rung is raced on the original prompt and the first content token is the only stream released.
- [x] A quiet or hard-failed rung is benched, the bench doubles, and the last rung is never benched. After the bench ends that model is first again.
- [x] After a content token, a long gap ends the turn and does not splice another model.
- [x] `CCL_STALL_HEDGE=0` leaves the request on the normal proxy path. Unit tests cover this without binding port 4000.

## Related records

- Leaf issue [#109](https://github.com/Pukujan/claude-code-launcher/issues/109); parent [#53](https://github.com/Pukujan/claude-code-launcher/issues/53).

## Closeout

### Closeout — 2026-10-10

Completed:
- Reconciled this projection with accepted history: the silence race and its replay busy-loop follow-up are both on `main`, so the task moves from active to completed.

Evidence:
- PR [#110](https://github.com/Pukujan/claude-code-launcher/pull/110) merged as `3c7d97390fdfc1a4f33336c76455c01b1cb7dc04` on 2026-10-08T04:49:59Z; all six required checks passed on head `88f85cf27c3794a8d4de92d5f0c723b9faca06f5`.
- Follow-up PR [#112](https://github.com/Pukujan/claude-code-launcher/pull/112) merged as `2faf4a0e2969c0f534e4edb39211190bd2563c38` on 2026-10-09T22:31:40Z; all six required checks and the supplemental `windows-installer` check passed on head `2288a6433238de80cd11e776e6ec7a1229bac081`.
- `python -m pytest tests/test_stall_hedge.py -q` → 21 passed in 2.30s (run locally 2026-10-10).
- Each acceptance criterion has a named test: keeping the first model on an early token (`test_primary_content_does_not_open_the_next_rung`, `test_thinking_token_commits_the_primary`); racing the next rung without splicing (`test_silent_primary_loses_to_the_next_rung_without_splicing`); benching, doubling, and the last rung never benched (`test_hard_failure_benches_immediately_and_a_bad_request_does_not`, `test_last_rung_silence_is_not_benched`, `test_benched_primary_is_skipped_until_the_bench_ends`); the post-token gap ending the turn (`test_gap_after_commit_ends_the_turn_and_ignores_pings`); and the disabled path (`test_settings_from_env_clamps_and_disables`, `test_disabled_handle_does_not_read_the_body`).
- The test module declares no network and no port 4000, and carries no `4000`, `127.0.0.1` or `localhost` reference, so the "tests do not bind the live proxy" criterion holds.

Decisions:
- Close on the merged commits, not on the earlier draft checkpoints; the merge records own delivery.
- Thresholds in the code (20 s floor, 90 s cap, 30 s bench doubling to 10 min, 120 s gap) remain the proposed starting values; no live tuning evidence was gathered, and the live proxy on port 4000 was not touched.

Changed:
- `tasks/TASK-CCL-0082-stall-hedge.md`, `checkpoints/CURRENT.md`.

Blocked/uncertain:
- PR #110's supplemental `windows-installer` check failed (it passed on the #112 follow-up). That check is not required, and no stall-hedge acceptance criterion depends on it. Recorded here rather than hidden.

Next:
- None for this task. Parent [#53](https://github.com/Pukujan/claude-code-launcher/issues/53) stays open for its own remaining scope.

## Checkpoint log

- 2026-10-10: projection closed against merged history; see the Closeout section above.
