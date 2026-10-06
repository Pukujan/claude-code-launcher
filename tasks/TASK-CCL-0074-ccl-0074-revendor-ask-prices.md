# TASK CCL-0074: Re-vendor the ask-based InferHub generator

<!-- continuity:task {"acceptance":["A CSV row carrying best_route_min_ask_in/out_usdc_per_1m produces input_cost_per_token and output_cost_per_token derived from the ask, not the blend.","A CSV row carrying only supply_weighted_median_cost_usdc_per_1m still produces an input_cost_per_token from the blend, and no output cost.","The generated deployment description names the price basis it used.","SOURCES.md records the new file hash and the commit the change came from.","pytest passes with the same failure set as main, and the pnpm gates pass."],"depends_on":[],"goal":"Re-vendor the ask-based InferHub generator into the launcher so the ih/ deployments carry both the input and output cost from the best route's cheapest listed ask.","id":"CCL-0074","issue_url":"https://github.com/Pukujan/claude-code-launcher/issues/80","next_action":"Publish the branch, merge the #80 pull request once the gates pass, then confirm the generated ih/ deployments read 1.5e-10 in and 6e-10 out for rank 1.","owner":"Alex; executor agent implements","priority":"P2","protocol_version":"0.1.0-draft","schema":"project-continuity.task.v1","status":"active","why":"The launcher's vendored copy is still the f04adc8 blend-only version, so the deployments it generates show the average seller's blend and no output cost, while the picker already shows the ask. Generated from the launcher's own top20-builtin.csv, rank-1 DeepSeek V4.1 Flash comes out at input_cost_per_token 1.5792e-08, the 0.015792 blend, where the route its row names is listed at 0.00015 in and 0.0006 out."} -->

- Status: active
- Owner: Alex; executor agent implements
- Priority: P2
- Depends on: none
- Leaf issue: [#80](https://github.com/Pukujan/claude-code-launcher/issues/80); parent: none (refs Pukujan/litellm-ckff-ops#45, Pukujan/litellm-ckff-ops#46, Pukujan/inference-recommendation-engine#94)
- Primary writer: executor-claude-code-launcher; branch `ccl-0074-revendor-ask-prices`

## Owning issue

- Issue [#80](https://github.com/Pukujan/claude-code-launcher/issues/80). Follows the closed #76, whose picker change already reads the ask columns.

## Write set

- `shared/litellm/scripts/sync_inferhub_top20.py`, `SOURCES.md`, `tests/test_sync_inferhub_top20.py`
- `tasks/`, `checkpoints/CURRENT.md`

Only the vendored generator's price read and write change, plus its record in
`SOURCES.md` and a test. The launcher's configs, seat routing and fallback
chains stay as they are: the role fallbacks come from
`inferhub_fallbacks.yaml`'s own `models:` block, and `merge_litellm_config.py`
reads the generated file only for the `model_name` to route map, so the added
output cost does not reach the chains.

## Acceptance criteria

- [ ] A CSV row carrying `best_route_min_ask_in/out_usdc_per_1m` produces both costs derived from the ask, not the blend.
- [ ] A CSV row carrying only the blend still produces an input cost, and no output cost.
- [ ] The deployment description names the price basis.
- [ ] `SOURCES.md` records the new file hash and the commit the change came from.
- [ ] The repository's existing gates pass.

## Checkpoint log

- 2026-10-06: issue #80 opened. Branch `ccl-0074-revendor-ask-prices` cut from `main`.
- 2026-10-06: the price read and write ported from `fcc2de7`; `SOURCES.md` row updated with hash `64d85c5c…` and the `fcc2de7` note; `tests/test_sync_inferhub_top20.py` added (4 tests). Generating from `config/top20-builtin.csv` yields `1.5e-10` in and `6e-10` out for rank 1; full-suite failure set identical to `main` (23, all machine-environment), 366 pass.

### 2026-10-06 01:56:07 UTC — executor-claude-code-launcher

<!-- continuity:checkpoint {"agent":"executor-claude-code-launcher","blocked":["none"],"changed":["shared/litellm/scripts/sync_inferhub_top20.py, SOURCES.md, tests/test_sync_inferhub_top20.py","tasks/TASK-CCL-0074-ccl-0074-revendor-ask-prices.md, checkpoints/CURRENT.md"],"completed":["Ported the ask-first price read and the two-cost write from litellm-ckff-ops fcc2de7 into the launcher's vendored sync_inferhub_top20.py, with the supply blend as the fallback for a CSV that predates the ask columns.","Updated the SOURCES.md row: base commit f04adc8 and its file hash kept, with the ported commit fcc2de7 and its hash recorded in the note.","Added tests/test_sync_inferhub_top20.py (4 tests) pinning the ask pair, the blend fallback, the missing output cost and the basis label."],"decisions":["no new decisions"],"evidence":["Generating from config/top20-builtin.csv yields input_cost_per_token 1.5e-10 and output_cost_per_token 6e-10 for rank 1. Full-suite failure set identical to main (23, all machine-environment), 366 pass, up 4 from the 362 baseline. ruff clean."],"next_action":"Publish the #80 pull request for ccl-0074-revendor-ask-prices with auto-merge, then confirm the generated ih/ deployments read 1.5e-10 in and 6e-10 out for rank 1.","protocol_version":"0.1.0-draft","schema":"project-continuity.checkpoint.v1","task_id":"CCL-0074","timestamp":"2026-10-06T01:56:07Z"} -->
<!-- continuity:checkpoint-operation {"payload_sha256":"85f5245d157fdbe48e526a2f3d4139bb7d3e194c3786f93d5fe62dac1f3b739a","request_id":"4a746da1c5904b74beddefa53de45b84","schema":"project-continuity.checkpoint-operation.v1","task_id":"CCL-0074"} -->

Completed:
- Ported the ask-first price read and the two-cost write from litellm-ckff-ops fcc2de7 into the launcher's vendored sync_inferhub_top20.py, with the supply blend as the fallback for a CSV that predates the ask columns.
- Updated the SOURCES.md row: base commit f04adc8 and its file hash kept, with the ported commit fcc2de7 and its hash recorded in the note.
- Added tests/test_sync_inferhub_top20.py (4 tests) pinning the ask pair, the blend fallback, the missing output cost and the basis label.

Evidence:
- Generating from config/top20-builtin.csv yields input_cost_per_token 1.5e-10 and output_cost_per_token 6e-10 for rank 1. Full-suite failure set identical to main (23, all machine-environment), 366 pass, up 4 from the 362 baseline. ruff clean.

Decisions:
- no new decisions

Changed:
- shared/litellm/scripts/sync_inferhub_top20.py, SOURCES.md, tests/test_sync_inferhub_top20.py
- tasks/TASK-CCL-0074-ccl-0074-revendor-ask-prices.md, checkpoints/CURRENT.md

Blocked/uncertain:
- none

Next:
- Publish the #80 pull request for ccl-0074-revendor-ask-prices with auto-merge, then confirm the generated ih/ deployments read 1.5e-10 in and 6e-10 out for rank 1.
