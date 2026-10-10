# TASK CCL-0083: Propagate IRE's fixed route lists into the built-in tables

<!-- continuity:task {"acceptance":["The five built-in tables lead every GLM family with a cb/cbcn route and every Qwen policy family with an ali/alicn route, matching IRE's post-fix list at d7014326.","Pull request 117 lands the nightly workflow's regenerated branch c72c409 plus the aligned test expectations, with five-way parity and prices that move with the route.","Issue 113 records the scope revision: the launcher-side pin is dropped because IRE #111 fixed the selector at the source.","The nightly PR-creation failure is filed as issue 115 with an owner decision requested."],"depends_on":["CCL-0081"],"goal":"Deliver the owner's route policy (cb/cbcn for GLM, ali/alicn for Qwen Flash/Max) by propagating IRE's post-fix route lists into the five built-in tables, after IRE #111 fixed the thin-supply selector at the source.","id":"CCL-0083","issue_url":"https://github.com/Pukujan/claude-code-launcher/issues/113","next_action":"Verify required CI on PR 117, merge, close #113 from the merged state.","owner":"Alex; executor agent implements","priority":"P1","protocol_version":"0.1.0-draft","schema":"project-continuity.task.v1","status":"active","why":"IRE's route ordering put the cheapest listed ask first, a thin-supply route, at the head of the GLM and Qwen families (IRE #110, #105). The owner set the policy on 2026-10-09: cb/cbcn for GLM, ali/alicn for Qwen Flash/Max. IRE merged the selector fix (d7014326, IRE #111) and closed #110 on 2026-10-10, so the launcher's job changed from pinning a local override to propagating IRE's fixed list."} -->

- Status: active
- Owner: Alex; executor agent implements
- Priority: P1
- Depends on: CCL-0081
- Leaf issue: [#113](https://github.com/Pukujan/claude-code-launcher/issues/113); parent: none; dependencies: none
- Primary writer: executor agent; branch: `ccl-0083-provider-route-preferences` (tables + aligned tests, PR #117)
- Upstream: IRE [#110](https://github.com/Pukujan/inference-recommendation-engine/issues/110) CLOSED by IRE #111 (`d7014326`), IRE [#105](https://github.com/Pukujan/inference-recommendation-engine/issues/105) covered by the same selector fix.

## Scope revision (2026-10-10, recorded on #113)

The original design pinned `shared/ire/route-preferences.json` and taught `sync_builtin_tables.py` to apply it. That design is **superseded**: IRE merged the selector fix (`d7014326`, IRE #111) and its regenerated lists already lead every policy family with the owner's rails. A committed launcher-side pin would be a second source of truth that can drift from IRE and hide a future regression. The deliverable is now propagation: land the nightly workflow's regenerated branch, which the workflow could not turn into a PR itself (repo Actions setting; filed as issue #115).

## Write set

- PR [#117](https://github.com/Pukujan/claude-code-launcher/pull/117) — lands `c72c409` on branch `ccl-0083-provider-route-preferences`: the five generated tables (`windows/launch-claude-inferhub.ps1`, `mac/Launch Claude InferHub.command`, `shared/litellm/config/top20-builtin.csv`, `shared/ire/defaults.json`, `tests/fixtures/ire/top20-frontier-route-map.json`) plus the test expectations that hardcoded the old routes (`tests/test_ladder.py`, `tests/test_ckff_off.py`, `tests/test_ire_fetch.py`, `tests/test_ultracode_windows_wizard.py`). PR #114 carried the tables alone and failed `python-tests`; it is closed as superseded.
- Issue [#115](https://github.com/Pukujan/claude-code-launcher/issues/115) — the nightly PR-creation failure and its options.
- This task file, `checkpoints/CURRENT.md`.

Out of scope: a launcher-side route-preference file (superseded), seat/shim routing (`apply_inferhub_seat.py`, `merge_litellm_config.py`, `inferhub_fallbacks.yaml`), the live proxy on port 4000, and changing the repo Actions setting (owner decision, #115).

## Acceptance criteria

- [ ] PR #117 merges with all six required checks passing, landing the post-fix tables.
- [ ] Every GLM family leads with `cb/`/`cbcn/` and every Qwen policy family with `ali/`/`alicn/` in all five tables at the merged commit, with prices that move with the route (GLM 5.3 shows cb's 0.0154/0.0484, not alicn's 0.0014/0.0044).
- [ ] Issue #113 records the scope revision and is closed from the merged state.
- [ ] Issue #115 tracks the nightly PR-creation failure for the owner's decision.

## Evidence (2026-10-10)

- IRE `d7014326` (2026-10-10T00:44Z) replaced the 5% price-band tie-break with `supply_penalized_cost(ask, supply, ref)`; IRE #110 closed 2026-10-10T00:53Z.
- IRE main's list at `d7014326`: GLM 5.3 Flash -> `cbcn/glm-5.3-flash`, GLM 5.3 -> `cb/glm-5.3`, GLM 5.2 -> `cb/glm-5.2`, Qwen3.8 Flash -> `alicn/qwen3.8-flash`, Qwen3.8 Max 0902 -> `ali/qwen3.8-max-0902`, Qwen 3.8 Max -> `ali/qwen3.8-max`, Qwen3.8 Omni Flash -> `alicn/qwen3.8-omni-flash`. All policy-conformant.
- Nightly run `38011099347` (2026-10-10T00:55Z) regenerated and pushed `c72c409` to `codex/ire-model-tables-refresh`, then failed on PR creation ("GitHub Actions is not permitted to create or approve pull requests"; repo setting `can_approve_pull_request_reviews: false`). Five-way parity on `c72c409` verified by extraction: no mismatches across CSV, `defaults.json`, fixture, PS1 `$Models`, Mac `MODELS`.
- PR #114 opened from that branch, then failed the required `python-tests` check: seven test expectations hardcoded route ids and prices the tables moved. PR #117 lands the same tables plus the aligned tests; #114 is closed as superseded.

## Qwen watch note

Post-fix, Qwen3.8 Flash still leads with `alicn/qwen3.8-flash` (3 sellers, 8 listings) over the deep `ali/qwen3.8-flash`, because alicn's ask is ~30x cheaper even after the supply penalty. The owner named ALI and ALICN as both acceptable, so this is within policy; revisit with an IRE note only if alicn proves unreliable in use.

## Checkpoint log

- 2026-10-10: created this task projection from issue #113 with the pinning design; reconciled against a live IRE fetch (all six preferred routes present in the Top 20 `ids` lists).
- 2026-10-10: superseded the pinning design after IRE merged the selector fix (IRE #111, `d7014326`) and its regenerated lists proved policy-conformant; opened PR #114 to land the nightly run's stranded branch `c72c409`; filed issue #115 for the nightly PR-creation failure; recorded the revision on #113.
- 2026-10-10: #114 failed the required `python-tests` check (7 stale test expectations). Opened PR #117 with the same tables plus the test alignment; closed #114. Local suite shows no new failures versus `main` (same 23 mac/posix-only failures on Windows).

### 2026-10-10 01:18:58 UTC — executor-agent

<!-- continuity:checkpoint {"agent":"executor-agent","blocked":[],"changed":["windows/launch-claude-inferhub.ps1, mac/Launch Claude InferHub.command, shared/litellm/config/top20-builtin.csv, shared/ire/defaults.json, tests/fixtures/ire/top20-frontier-route-map.json, tests/test_ladder.py, tests/test_ckff_off.py, tests/test_ire_fetch.py, tests/test_ultracode_windows_wizard.py, tasks/TASK-CCL-0083-provider-route-preferences.md, checkpoints/CURRENT.md"],"completed":["Propagated IRE's post-fix route lists into the five built-in picker tables and aligned the tests that hardcoded the old routes; opened PR 117 (tables + tests + the CCL-0083 projection); recorded the scope revision on issue 113; filed issue 115 for the nightly PR-creation failure; opened and then closed PR 114, which carried the tables alone and failed python-tests."],"decisions":["Dropped the launcher-side route pin: IRE fixed the selector at the source, so a local pin would be a divergent second source of truth. The deliverable is propagation of IRE's list."],"evidence":["IRE fix d7014326 (IRE #111) closed IRE #110; IRE main's list leads every policy family with cb/cbcn or ali/alicn. Nightly run 38011099347 pushed c72c409 to codex/ire-model-tables-refresh then failed on PR creation (repo setting can_approve_pull_request_reviews false). Five-way parity on c72c409: no mismatches. tests/test_top20_tables.py 6 passed; ruff clean; local suite same 23 mac/posix-only failures as main, no new ones. PR 117 head a279c0c."],"next_action":"Verify the six required checks on PR 117 and merge it, then close issue 113 from the merged state and receipt issue 109 (CCL-0082 closeout already merged in f8957ca).","protocol_version":"0.1.0-draft","schema":"project-continuity.checkpoint.v1","task_id":"CCL-0083","timestamp":"2026-10-10T01:18:58Z"} -->
<!-- continuity:checkpoint-operation {"payload_sha256":"8d1e382f6e06087c4e0d8db1346c164b8d47b0ae20f2e46c6145fa931db268e2","request_id":"e2577b25b5654984a66f33da8d1da988","schema":"project-continuity.checkpoint-operation.v1","task_id":"CCL-0083"} -->

Completed:
- Propagated IRE's post-fix route lists into the five built-in picker tables and aligned the tests that hardcoded the old routes; opened PR 117 (tables + tests + the CCL-0083 projection); recorded the scope revision on issue 113; filed issue 115 for the nightly PR-creation failure; opened and then closed PR 114, which carried the tables alone and failed python-tests.

Evidence:
- IRE fix d7014326 (IRE #111) closed IRE #110; IRE main's list leads every policy family with cb/cbcn or ali/alicn. Nightly run 38011099347 pushed c72c409 to codex/ire-model-tables-refresh then failed on PR creation (repo setting can_approve_pull_request_reviews false). Five-way parity on c72c409: no mismatches. tests/test_top20_tables.py 6 passed; ruff clean; local suite same 23 mac/posix-only failures as main, no new ones. PR 117 head a279c0c.

Decisions:
- Dropped the launcher-side route pin: IRE fixed the selector at the source, so a local pin would be a divergent second source of truth. The deliverable is propagation of IRE's list.

Changed:
- windows/launch-claude-inferhub.ps1, mac/Launch Claude InferHub.command, shared/litellm/config/top20-builtin.csv, shared/ire/defaults.json, tests/fixtures/ire/top20-frontier-route-map.json, tests/test_ladder.py, tests/test_ckff_off.py, tests/test_ire_fetch.py, tests/test_ultracode_windows_wizard.py, tasks/TASK-CCL-0083-provider-route-preferences.md, checkpoints/CURRENT.md

Blocked/uncertain:
- none

Next:
- Verify the six required checks on PR 117 and merge it, then close issue 113 from the merged state and receipt issue 109 (CCL-0082 closeout already merged in f8957ca).
