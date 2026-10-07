# TASK CCL-0079: Keep launcher model families paired with IRE's current provider routes

<!-- continuity:task {"acceptance":["All four built-in Top 20 artifacts use the current IRE family, rank, eligibility, prices, and selected provider route.","No built-in Top 20 row has a blank or malformed provider route; each ID matches the family in the pinned IRE source fixture.","The frontier importer preserves route, health, prices, and preferred endpoint; Windows offline frontier routes match current IRE recommendations.","A scheduled and manually dispatched workflow opens a review PR when generated fallback tables drift and never merges them automatically.","Tests cover all 20 Top 20 model/provider pairs and frontier routes.","No seat or shim routing changes, fallback chain changes, port 4000 activity, or secrets.","The Linux/macOS Claude Code model picker accepts the six-field Top 20 table, displays provider IDs, and includes IRE's first 20 frontier best routes."],"depends_on":[],"goal":"Keep the launcher's free Top 20 and frontier pickers aligned to IRE's actual InferHub provider routes, including the offline fallback.","id":"CCL-0079","issue_url":"https://github.com/Pukujan/claude-code-launcher/issues/96","next_action":"Repair and merge the Linux/macOS model-picker sync so current Top 20 and frontier provider routes appear in Claude Code.","owner":"Alex; executor agent implements","priority":"P2","protocol_version":"0.1.0-draft","schema":"project-continuity.task.v1","status":"active","why":"The checked-in Top 20 fallback has stale or mismatched model/provider pairs, including an invalid ag/ route for Claude Sonnet 4.6. Mac can use live IRE data, but Windows and offline/cache paths can select a route left behind after rankings changed. A reviewed scheduled refresh prevents future silent drift."} -->

- Status: active
- Owner: Alex; executor agent implements
- Priority: P2
- Depends on: none
- Leaf issue: [#96](https://github.com/Pukujan/claude-code-launcher/issues/96); parent: none (refs Pukujan/inference-recommendation-engine#94, #97, #104)
- Primary writer: Codex
- Branch (merged table refresh): `ccl-0079-inferhub-route-sync`; follow-up: `codex/ccl-0079-model-picker-sync`

## Owning issue

Issue [#96](https://github.com/Pukujan/claude-code-launcher/issues/96). The correction at [comment 6033488169](https://github.com/Pukujan/claude-code-launcher/issues/96#issuecomment-6033488169) supersedes the initial diagnosis: current live IRE routes are correct; checked-in fallback mappings are stale.

## Write set

- `shared/ire/` route snapshot generation
- Windows and Mac built-in Top 20 and Windows frontier tables
- Scheduled refresh workflow and route-pair regression coverage
- `tasks/` and `checkpoints/CURRENT.md`

Seat assignment, shim routing, `shared/litellm/config/inferhub_fallbacks.yaml`, and live proxy access remain out of scope.

## Acceptance criteria

- [x] All four built-in Top 20 artifacts use IRE's current family, rank, eligibility, prices, and best route.
- [x] No built-in Top 20 row has a blank or malformed route; its provider/model pair matches the current IRE fixture.
- [x] Windows offline frontier rows match IRE's current first-20 best routes; the existing live importer remains unchanged.
- [x] A scheduled and manually dispatched workflow opens a PR when generated fallbacks drift and does not auto-merge provider changes.
- [x] Tests cover all Top 20 model/provider pairs and frontier routes.
- [x] No seat or shim routing changes, fallback chain changes, live port 4000 activity, or secrets.
- [ ] Linux/macOS Claude Code model-picker sync accepts the six-field Top 20 table, displays provider IDs, and includes IRE's first 20 frontier best routes.

## Evidence and interpretation

- Observed at launcher `main` revision `7417fa9`: its checked-in Top 20 tables are internally consistent but stale against IRE. Examples include rank 11 still being MiMo while current IRE rank 11 is Gemini 3.8 Flash, rank 19 using the invalid-looking `ag/` route, and rank 20 listing Muse Spark while current IRE rank 20 is Qwen3.8 Omni Flash.
- Observed at IRE `main` revision `f463962`: current Top 20 JSON includes `best_route`, and the CSV's first `model_ids` entry matches it. Frontier JSON carries per-route health, listed prices, and endpoint metadata.
- Inferred: independently maintained fallback files allowed IDs to stay attached to stale families after ranks and model families changed.

## Linux model-picker follow-up

- Observed: the installed Linux launcher fetched IRE `main` at `f4639620b9b8814181b25f4e66bb3ddbcfc8ec48` and had 20 Top 20 rows plus 20 selected frontier rows, but its settings sync raised `ValueError: too many values to unpack (expected 5)` because the refreshed table has six fields.
- Inferred: Claude Code therefore kept no provider entries in its model picker even though the launcher's terminal menus had fresh IRE data.
- The user directed this follow-up in issue [#96 comment 6034151538](https://github.com/Pukujan/claude-code-launcher/issues/96#issuecomment-6034151538).
- The current Linux user's picker settings have been refreshed from the existing live IRE cache; it now contains 20 Top 20 and 20 frontier provider choices, with each provider shown in its label.

## Checkpoint log

- 2026-10-07: opened issue #96, verified it is OPEN, and recorded a correction after comparing against IRE `main` at `f463962`. `continuity issue verify` and `continuity docs find` could not run because the `continuity` executable is not installed in this environment; GitHub issue status and repository state were checked directly.

### Checkpoint

Completed:
- Compared the current launcher fallback to IRE Top 20 and frontier outputs.
- Corrected the initial issue diagnosis: live Top 20 route ordering matches IRE; checked-in offline mappings are stale.

Decisions:
- Treat IRE's selected best route as the source of truth for each model-family row.

Evidence:
- IRE `main` `f4639620b9b8814181b25f4e66bb3ddbcfc8ec48` (daily refresh PR #104).
- Launcher `main` `7417fa97f8647cee461e4277508fe2307b8363b9` has stale Top 20 family/provider rows; issue #96 comment 6033488169 records the correction.

Changed:
- `tasks/TASK-CCL-0079-inferhub-route-sync.md`

Blocked/uncertain:
- The `continuity` CLI is unavailable; this does not prevent safe implementation.

Next:
- Complete the required continuity checkpoint, push the branch, and open the review PR.

### Checkpoint — 2026-10-07

Completed:
- Added a generator that refreshes the shared CSV/defaults, Windows and Mac Top 20 tables, Windows frontier fallback, and a pinned route fixture from IRE output.
- Added daily and manual GitHub Actions refresh that opens a review PR without merging it, pinned to one IRE commit SHA and date.
- Updated offline provider routes to IRE `f4639620b9b8814181b25f4e66bb3ddbcfc8ec48`.
- Added row-by-row Top 20/frontier regression checks and adjusted an integration assertion that assumed the old rank-one provider ID; fixed seat and fallback routing files remain unchanged.

Decisions:
- Keep seat assignment, shim routing, and fixed fallback chains unchanged; refresh only model-pick snapshots and make snapshot tests read the generated route data.

Evidence:
- Live bundle fetch at the pinned IRE revision succeeded; generator recorded source date `2026-10-06T17:10:38Z`.
- Focused route checks: 80 passed.
- Full suite: 375 passed, 49 skipped.
- `python -m py_compile shared/ire/ire_fetch.py shared/ire/sync_builtin_tables.py` and `git diff --check` passed.
- Current issue #96 is OPEN. Its corrected evidence is in comment 6033488169.

Changed:
- `shared/ire/`, `shared/litellm/config/top20-builtin.csv`, Windows and Mac launcher snapshots, the sync workflow, task projections, and tests.

Blocked/uncertain:
- The pinned continuity CLI is not installed or discoverable in this Linux environment, so its required checkpoint/push step has not run. No commit or push has been made.

Next:
- Restore the pinned continuity CLI, write the synchronized checkpoint, push this branch, and open a review PR linked to issue #96.

### 2026-10-07 08:09:31 UTC — Codex

<!-- continuity:checkpoint {"agent":"Codex","blocked":["continuity issue verify reports issue #96 OPEN but exits with missing .continuity/documents.json; live issue was checked directly with gh."],"changed":["shared/ire/, shared/litellm/config/top20-builtin.csv, Windows and Mac launcher snapshots, .github/workflows/sync-ire-model-tables.yml, tests, task and current checkpoint projections"],"completed":["Regenerated the offline Top 20 and frontier provider snapshots from pinned IRE output; added daily and manual reviewed refresh PR workflow and row-level route checks."],"decisions":["no new decisions"],"evidence":["Live IRE fetch at f4639620b9b8814181b25f4e66bb3ddbcfc8ec48; focused tests 80 passed; full suite 375 passed, 49 skipped; Ruff passed; workflow YAML parsed; issue #96 is OPEN."],"next_action":"Open the review PR for CCL-0079, wait for required checks and review, then enable auto-merge only after the final push.","protocol_version":"0.1.0-draft","schema":"project-continuity.checkpoint.v1","task_id":"CCL-0079","timestamp":"2026-10-07T08:09:31Z"} -->
<!-- continuity:checkpoint-operation {"payload_sha256":"9e911516af8116d32f55430e3c07d974d28f80e4c79a5a17419a6cdf4c080da2","request_id":"487ae81fbce944c98a704548356502f8","schema":"project-continuity.checkpoint-operation.v1","task_id":"CCL-0079"} -->

Completed:
- Regenerated the offline Top 20 and frontier provider snapshots from pinned IRE output; added daily and manual reviewed refresh PR workflow and row-level route checks.

Evidence:
- Live IRE fetch at f4639620b9b8814181b25f4e66bb3ddbcfc8ec48; focused tests 80 passed; full suite 375 passed, 49 skipped; Ruff passed; workflow YAML parsed; issue #96 is OPEN.

Decisions:
- no new decisions

Changed:
- shared/ire/, shared/litellm/config/top20-builtin.csv, Windows and Mac launcher snapshots, .github/workflows/sync-ire-model-tables.yml, tests, task and current checkpoint projections

Blocked/uncertain:
- continuity issue verify reports issue #96 OPEN but exits with missing .continuity/documents.json; live issue was checked directly with gh.

Next:
- Open the review PR for CCL-0079, wait for required checks and review, then enable auto-merge only after the final push.

### CI correction — 2026-10-07

Completed:
- Added the `Decisions:` headings required by the pinned continuity validator to the earlier task checkpoint projections.
- Changed Mac model-route and UltraCode picker test expectations to derive from the built-in snapshot, including the dry-run's selected seat routes.

Decisions:
- Keep the Mac test dry run aligned with the selected IRE routes while leaving seat/shim routing code unchanged.

Evidence:
- PR #97 armed squash auto-merge on checkpoint SHA `9fa6e87ba0778881bd748fe56ead28ed88eae970`.
- The pinned PCM gate rejected two checkpoint projections because they lacked the required `Decisions:` section.
- Mac unit tests pass locally (107 passed); Bash syntax checks and `git diff --check` pass.
- ShellCheck 0.9.0 then flagged an unbraced variable before a bracket expression in the new UltraCode assertion; that quoting issue is corrected locally.
- Python CI found two remaining hard-coded rank-one route values in `tests/test_ultracode_windows_wizard.py`; the test now reads the current route from the built-in CSV.
- The local dry run could not begin: its test copy tried to duplicate the existing ignored LiteLLM virtualenv into `/tmp` and hit the container disk quota. The partial task-created temp directory was removed; the user's local virtualenv and ignored Top 20 cache were preserved.
- The continuity CLI is now installed from the pinned PCM source; `continuity issue verify` reports issue #96 OPEN, then exits with an error because this repository has no `.continuity/documents.json`.

Changed:
- `mac/tests/unit_tests.sh`, `mac/tests/dry_run.sh`, `tests/test_ultracode_windows_wizard.py`, `tasks/TASK-CCL-0079-inferhub-route-sync.md`, and `checkpoints/CURRENT.md`.

Blocked/uncertain:
- On PR head `910757b3a141825d38f2a7277f6aa231a2168d91`, the second CI run passed the continuity gate, Mac dry run, Bash 3.2, and Linux dry run. Lint failed on the corrected ShellCheck quoting issue; Python tests failed on the corrected route expectations; the Windows installer was still running at inspection.
- Focused route/wizard tests now pass locally (40 passed, 4 skipped); Mac unit tests pass (107 passed); `continuity validate`, Ruff, Bash syntax and diff checks pass.

Next:
- Commit and checkpoint the ShellCheck and Windows wizard test corrections, push the updated branch, then confirm all required PR checks pass.

### 2026-10-07 08:14:03 UTC — Codex

<!-- continuity:checkpoint {"agent":"Codex","blocked":["Updated remote CI has not run; local Mac dry run could not copy the existing ignored LiteLLM virtualenv within the container disk quota."],"changed":["mac/tests/unit_tests.sh, mac/tests/dry_run.sh, tasks/TASK-CCL-0079-inferhub-route-sync.md, checkpoints/CURRENT.md"],"completed":["Corrected task projections for pinned PCM gates and made Mac picker tests derive selected provider routes from the generated IRE Top 20."],"decisions":["Keep live CI checks as the verification source for the Mac dry run; no seat/shim routing code changed."],"evidence":["continuity validate VALID; Mac unit tests 107 passed; bash -n and git diff --check passed; local dry run could not start because copying ignored LiteLLM virtualenv exceeded /tmp quota, partial task temp copy removed."],"next_action":"Verify required checks on PR #97 at the new pushed checkpoint SHA and confirm auto-merge.","protocol_version":"0.1.0-draft","schema":"project-continuity.checkpoint.v1","task_id":"CCL-0079","timestamp":"2026-10-07T08:14:03Z"} -->
<!-- continuity:checkpoint-operation {"payload_sha256":"71d992a08316b0dbb69a31f903554dd9d4270d9384cb47c2e58166fa9273464c","request_id":"09134d4cea214fd084fe2a9b51389070","schema":"project-continuity.checkpoint-operation.v1","task_id":"CCL-0079"} -->

Completed:
- Corrected task projections for pinned PCM gates and made Mac picker tests derive selected provider routes from the generated IRE Top 20.

Evidence:
- continuity validate VALID; Mac unit tests 107 passed; bash -n and git diff --check passed; local dry run could not start because copying ignored LiteLLM virtualenv exceeded /tmp quota, partial task temp copy removed.

Decisions:
- Keep live CI checks as the verification source for the Mac dry run; no seat/shim routing code changed.

Changed:
- mac/tests/unit_tests.sh, mac/tests/dry_run.sh, tasks/TASK-CCL-0079-inferhub-route-sync.md, checkpoints/CURRENT.md

Blocked/uncertain:
- Updated remote CI has not run; local Mac dry run could not copy the existing ignored LiteLLM virtualenv within the container disk quota.

Next:
- Verify required checks on PR #97 at the new pushed checkpoint SHA and confirm auto-merge.

### 2026-10-07 08:19:59 UTC — Codex

<!-- continuity:checkpoint {"agent":"Codex","blocked":["The latest CI for these fixes has not run yet; local full Mac dry run could not duplicate the ignored LiteLLM virtualenv within the container disk quota."],"changed":["mac/tests/unit_tests.sh, tests/test_ultracode_windows_wizard.py, task and current checkpoint projections"],"completed":["Corrected the remaining ShellCheck quoting warning and Windows wizard assertions that hard-coded IRE rank-one provider IDs."],"decisions":["Have Mac and Windows picker tests read the selected route from the generated recommendation table so scheduled updates do not require hard-coded provider edits."],"evidence":["Focused route/wizard tests 40 passed, 4 skipped; Mac unit suite 107 passed; continuity validate VALID; Ruff, bash -n and git diff --check passed. CI on previous head passed gates, Mac dry run, Bash 3.2, Linux dry run; ShellCheck and two Python assertions were fixed."],"next_action":"Verify all required CI checks and auto-merge on PR #97 at the pushed checkpoint SHA.","protocol_version":"0.1.0-draft","schema":"project-continuity.checkpoint.v1","task_id":"CCL-0079","timestamp":"2026-10-07T08:19:59Z"} -->
<!-- continuity:checkpoint-operation {"payload_sha256":"1c6ef6e02f7f9b9aab5c54fb653f2193a2c0104bf880a9f06ae81c4d66efab6e","request_id":"97fd5b1a73d44ad0a16979a991ddc747","schema":"project-continuity.checkpoint-operation.v1","task_id":"CCL-0079"} -->

Completed:
- Corrected the remaining ShellCheck quoting warning and Windows wizard assertions that hard-coded IRE rank-one provider IDs.

Evidence:
- Focused route/wizard tests 40 passed, 4 skipped; Mac unit suite 107 passed; continuity validate VALID; Ruff, bash -n and git diff --check passed. CI on previous head passed gates, Mac dry run, Bash 3.2, Linux dry run; ShellCheck and two Python assertions were fixed.

Decisions:
- Have Mac and Windows picker tests read the selected route from the generated recommendation table so scheduled updates do not require hard-coded provider edits.

Changed:
- mac/tests/unit_tests.sh, tests/test_ultracode_windows_wizard.py, task and current checkpoint projections

Blocked/uncertain:
- The latest CI for these fixes has not run yet; local full Mac dry run could not duplicate the ignored LiteLLM virtualenv within the container disk quota.

Next:
- Verify all required CI checks and auto-merge on PR #97 at the pushed checkpoint SHA.

### CI correction follow-up — 2026-10-07

Completed:
- Changed the Windows wizard test to assert that fallback selections come from current Top 20 routes or the configured ladder, while still checking the selected primary exactly.

Decisions:
- Keep the wizard test focused on route provenance and primary selection; current eligibility may legitimately change which configured fallback is chosen.

Evidence:
- On PR head `07c55c558b3791605d86725bcfb50bf421c41de3`, continuity, lint, Mac dry run, Bash 3.2 and Linux dry run passed; Python tests failed on the old rank-two fallback expectation. The Windows installer was still running at inspection.
- Focused tests now pass locally (40 passed, 4 skipped); continuity validation and Ruff pass. Four skips include Windows wizard execution because PowerShell is unavailable locally.

Changed:
- `tests/test_ultracode_windows_wizard.py`, `tasks/TASK-CCL-0079-inferhub-route-sync.md`, and `checkpoints/CURRENT.md`.

Blocked/uncertain:
- Updated CI for this correction has not run. The prior Windows installer check remained in progress at last inspection.

Next:
- Commit and checkpoint this final route expectation update, push it, and verify all PR checks.

### 2026-10-07 08:23:19 UTC — Codex

<!-- continuity:checkpoint {"agent":"Codex","blocked":["CI for the new head has not run; the Windows installer check on the previous head remained in progress."],"changed":["tests/test_ultracode_windows_wizard.py, task and current checkpoint projections"],"completed":["Updated the Windows wizard test to validate the selected primary and accept configured, currently eligible fallback routes."],"decisions":["Test provider route provenance and primary choice without freezing mutable IRE eligibility outcomes."],"evidence":["Focused tests 40 passed, 4 skipped; continuity validate VALID; Ruff and diff checks passed. PR head 07c55c55 had continuity, lint, Mac, Bash 3.2 and Linux checks pass; Python failed on the corrected rank-two fallback expectation."],"next_action":"Verify all required checks and auto-merge on PR #97 at the new pushed checkpoint SHA.","protocol_version":"0.1.0-draft","schema":"project-continuity.checkpoint.v1","task_id":"CCL-0079","timestamp":"2026-10-07T08:23:19Z"} -->
<!-- continuity:checkpoint-operation {"payload_sha256":"2b196f0dc41844089a7b8c6fdcf65a26664c1eb36824d2ec40b43e91c3e4e54e","request_id":"c21cf3dbb37f4abc8064c51eb058dce7","schema":"project-continuity.checkpoint-operation.v1","task_id":"CCL-0079"} -->

Completed:
- Updated the Windows wizard test to validate the selected primary and accept configured, currently eligible fallback routes.

Evidence:
- Focused tests 40 passed, 4 skipped; continuity validate VALID; Ruff and diff checks passed. PR head 07c55c55 had continuity, lint, Mac, Bash 3.2 and Linux checks pass; Python failed on the corrected rank-two fallback expectation.

Decisions:
- Test provider route provenance and primary choice without freezing mutable IRE eligibility outcomes.

Changed:
- tests/test_ultracode_windows_wizard.py, task and current checkpoint projections

Blocked/uncertain:
- CI for the new head has not run; the Windows installer check on the previous head remained in progress.

Next:
- Verify all required checks and auto-merge on PR #97 at the new pushed checkpoint SHA.

### Linux model-picker follow-up — 2026-10-07

Completed:
- Fixed the shared Linux/macOS Claude Code model-picker sync to accept the current six-field IRE Top 20 rows and label each route with its provider.
- Added the first 20 IRE frontier best routes to the Claude Code picker, preserving their provider route IDs and eligibility labels.
- Refreshed this Linux user's picker settings from the already-current cached IRE bundle; it now has 20 Top 20 and 20 frontier routes.

Evidence:
- The launcher log showed live IRE source `f4639620b9b8814181b25f4e66bb3ddbcfc8ec48`, followed by `ValueError: too many values to unpack (expected 5)` during settings sync.
- The cached IRE bundle as of `2026-10-07T08:30:11Z` has 20 Top 20 rows and 20 selected frontier best routes at ranks 1–20.
- The Claude Code settings refresh reported 44 picker options: four slots, 20 Top 20 routes and 20 frontier routes.
- Required CI is pending for this follow-up branch. No tests were run locally.

Decisions:
- Keep the issue open until this permanent code repair passes required CI and is merged.
- Do not start, probe, reload or restart the live proxy as part of the settings repair.

Changed:
- `mac/Launch Claude InferHub.command`, this task record and `checkpoints/CURRENT.md`.

Blocked/uncertain:
- None.

Next:
- Commit the product and projection updates, checkpoint and push the follow-up branch, then open a linked review PR.
