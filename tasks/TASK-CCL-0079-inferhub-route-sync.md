# TASK CCL-0079: Keep launcher model families paired with IRE's current provider routes

<!-- continuity:task {"acceptance":["All four built-in Top 20 artifacts use the current IRE family, rank, eligibility, prices, and selected provider route.","No built-in Top 20 row has a blank or malformed provider route; each ID matches the family in the pinned IRE source fixture.","The frontier importer preserves route, health, prices, and preferred endpoint; Windows offline frontier routes match current IRE recommendations.","A scheduled and manually dispatched workflow opens a review PR when generated fallback tables drift and never merges them automatically.","Tests cover all 20 Top 20 model/provider pairs and frontier routes.","No seat or shim routing changes, fallback chain changes, port 4000 activity, or secrets."],"depends_on":[],"goal":"Keep the launcher's free Top 20 and frontier pickers aligned to IRE's actual InferHub provider routes, including the offline fallback.","id":"CCL-0079","issue_url":"https://github.com/Pukujan/claude-code-launcher/issues/96","next_action":"Generate the built-in route tables from current IRE output, verify row-level mappings, then open a reviewed PR.","owner":"Alex; executor agent implements","priority":"P2","protocol_version":"0.1.0-draft","schema":"project-continuity.task.v1","status":"active","why":"The checked-in Top 20 fallback has stale or mismatched model/provider pairs, including an invalid ag/ route for Claude Sonnet 4.6. Mac can use live IRE data, but Windows and offline/cache paths can select a route left behind after rankings changed. A reviewed scheduled refresh prevents future silent drift."} -->

- Status: active
- Owner: Alex; executor agent implements
- Priority: P2
- Depends on: none
- Leaf issue: [#96](https://github.com/Pukujan/claude-code-launcher/issues/96); parent: none (refs Pukujan/inference-recommendation-engine#94, #97, #104)
- Primary writer: Codex
- Branch: `ccl-0079-inferhub-route-sync`

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

## Evidence and interpretation

- Observed at launcher `main` revision `7417fa9`: its checked-in Top 20 tables are internally consistent but stale against IRE. Examples include rank 11 still being MiMo while current IRE rank 11 is Gemini 3.8 Flash, rank 19 using the invalid-looking `ag/` route, and rank 20 listing Muse Spark while current IRE rank 20 is Qwen3.8 Omni Flash.
- Observed at IRE `main` revision `f463962`: current Top 20 JSON includes `best_route`, and the CSV's first `model_ids` entry matches it. Frontier JSON carries per-route health, listed prices, and endpoint metadata.
- Inferred: independently maintained fallback files allowed IDs to stay attached to stale families after ranks and model families changed.

## Checkpoint log

- 2026-10-07: opened issue #96, verified it is OPEN, and recorded a correction after comparing against IRE `main` at `f463962`. `continuity issue verify` and `continuity docs find` could not run because the `continuity` executable is not installed in this environment; GitHub issue status and repository state were checked directly.

### Checkpoint

Completed:
- Compared the current launcher fallback to IRE Top 20 and frontier outputs.
- Corrected the initial issue diagnosis: live Top 20 route ordering matches IRE; checked-in offline mappings are stale.

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
