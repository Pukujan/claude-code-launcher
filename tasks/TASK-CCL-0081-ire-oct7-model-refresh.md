# TASK CCL-0081: Refresh the built-in model picker from IRE's October 7 list

<!-- continuity:task {"acceptance":["The four built-in Top 20 tables match the pinned IRE source revision in rank, family, eligibility, selected provider route, and ask prices.","The Windows offline first-20 frontier fallback and shared route-map fixture match the pinned IRE source revision.","When IRE changes a model family's selected provider, Windows defaults and picker highlights use the current listed route for that same family; an existing saved custom route is preserved until the user changes it.","Table, route-mapping, and picker checks pass in required pull request CI.","No seat or shim routing, fixed fallback chain, live proxy, or secret changes."],"depends_on":[],"goal":"Refresh the built-in model tables from IRE and keep Windows picker defaults on the same model family when its selected provider changes.","id":"CCL-0081","issue_url":"https://github.com/Pukujan/claude-code-launcher/issues/107","next_action":"none; issue #107 closed after PR #108 merged as 6130d2d with all required checks green.","owner":"Alex; Codex implements","priority":"P2","protocol_version":"0.1.0-draft","schema":"project-continuity.task.v1","status":"completed","why":"IRE's current source changes model eligibility and selected provider routes; those route changes can leave Windows picker defaults pointing outside the current list."} -->

- Status: completed
- Owner: Alex; Codex implements
- Priority: P2
- Depends on: none
- Leaf issue: [#107](https://github.com/Pukujan/claude-code-launcher/issues/107) (closed); parent: none; dependencies: none
- Primary writer: Codex; branch: `codex/ccl-0081-ire-oct7-model-refresh`

## Goal

Refresh the built-in Top 20 and Windows offline frontier tables from IRE's October 7 source revision, and keep Windows picker defaults on the same model family when IRE changes its selected provider.

## Why

IRE's current source differs from the October 6 built-in snapshot in model eligibility, selected provider routes, and frontier data. A provider change can also leave a Windows first-run slot default unavailable in the refreshed list.

## Allowed files

- `shared/litellm/config/top20-builtin.csv`
- `shared/ire/defaults.json`
- `windows/launch-claude-inferhub.ps1`
- `mac/Launch Claude InferHub.command`
- `tests/fixtures/ire/top20-frontier-route-map.json`
- `tests/test_top20_tables.py`, `tests/test_pkg_settings_sync.py`, `tests/test_ckff_off.py`, `tests/test_ladder.py`, and `tests/test_ultracode_windows_wizard.py`
- `.coord/boss_claim.json`
- `tasks/` and `checkpoints/CURRENT.md`

## Human outcome

When IRE cannot be reached, the Windows launcher will offer IRE's current model eligibility and selected routes, and first-run slot defaults will stay on the same model family when a provider prefix changes.

## Scope and boundaries

- In scope: regenerate the four built-in Top 20 tables, Windows's offline first-20 frontier fallback, and their route-map fixture from IRE commit `c80166a2e827c3e0ed1f311735d9596c2ef5ddbc`; map Windows default highlights to the current listed route for the same model family when IRE changes its provider; use current routes when an unusable saved CKFF-only slot falls back to defaults; update affected expectations. Existing saved custom routes remain as saved unless the user edits that slot.
- Out of scope: the full lab roster in issue #100 and PR #101, IRE changes, live frontier import behavior, seat/shim routing, the shared fixed fallback configuration, saved custom routes, live proxy activity, and user-local settings.
- Dependencies/uncertainty: none. The current IRE source revision is pinned for this increment; future drift belongs to the reviewed refresh workflow.

## Acceptance criteria

- [x] The shared CSV, shared JSON defaults, Windows table, and Mac table match IRE's 20 rows at the pinned source revision in rank/order, model family, eligibility, selected provider route, and ask prices.
- [x] The Windows offline first-20 frontier fallback and route-map fixture match the same pinned IRE bundle.
- [x] When a default route is no longer listed but its model family remains, the Windows picker highlights IRE's current route for that family, including when the user edits a saved slot.
- [x] A saved custom route is preserved unless the user chooses a replacement; a CKFF-only slot falls back to current IRE defaults.
- [x] Table, route-mapping, and picker checks pass in required pull request CI.
- [x] No seat or shim routing, fixed fallback chain, live proxy, or secret changes.
- [x] A linked pull request passes required CI and is set to auto-merge only after its final push.

## Evidence and sources

Observed at launcher `main` revision `27f951e`: `shared/ire/defaults.json` records an October 6 snapshot. The IRE `main` source commit [c80166a2e827c3e0ed1f311735d9596c2ef5ddbc](https://github.com/Pukujan/inference-recommendation-engine/commit/c80166a2e827c3e0ed1f311735d9596c2ef5ddbc) was published 2026-10-07 17:48:43 UTC. A row comparison found 9 of 20 rows with changed eligibility or first provider route. For rank 1, IRE says DeepSeek V4.1 Flash is not eligible and selects `cb/deepseek-v4.1-flash`; local defaults say eligible and start with `alicn/deepseek-v4.1-flash`. The user's desktop entry point forwards to the repository's Windows launcher.

At PR #108 head `6d7fb069`, required Python CI failed because route, eligibility, and ordering expectations still reflected the prior snapshot. It also showed that Windows picker defaults such as `cb/gpt-6-astra` no longer appear in the refreshed list, even though IRE lists the same family at `cx/gpt-6-astra`. The remaining required CI checks passed at that head, and the supplemental Windows installer check passed. No tests were run locally. The picker-only scope corrections are recorded in [issue comment 6045504469](https://github.com/Pukujan/claude-code-launcher/issues/107#issuecomment-6045504469) and [issue comment 6046443651](https://github.com/Pukujan/claude-code-launcher/issues/107#issuecomment-6046443651).

## Reproduction details (only when needed)

Starting revision, material inputs/configuration, runtime, exact command or prompt, observed result, and limitations.

## Related records

- Leaf owning issue: #107; parent: none; dependencies: none.
- Primary writer: Codex; branch: `codex/ccl-0081-ire-oct7-model-refresh`; source issue #107 was OPEN during the work and is closed at this projection.
- Related issue: #96, which introduced the generated-table workflow; source revision: IRE `main` `c80166a2e827c3e0ed1f311735d9596c2ef5ddbc`; scope corrections: [comment 6045326197](https://github.com/Pukujan/claude-code-launcher/issues/107#issuecomment-6045326197), [comment 6045504469](https://github.com/Pukujan/claude-code-launcher/issues/107#issuecomment-6045504469), and [comment 6046443651](https://github.com/Pukujan/claude-code-launcher/issues/107#issuecomment-6046443651).
- Review PR: [#108](https://github.com/Pukujan/claude-code-launcher/pull/108), MERGED as `6130d2dbe669f9cfc3e4b481d46b8446f283b202` on 2026-10-07T20:53:49Z. All six required checks and the supplemental Windows installer check passed on final head `78050429e37bea932b02d86e91e111dd3705d063`.

## Checkpoint log

### 2026-10-07 — Codex

Completed:
- Fetched launcher `main` to `27f951e` and verified it is current with `origin/main`.
- Compared the built-in Top 20 against IRE `main` at `c80166a2`; 9 of 20 rows differ in eligibility or selected provider route.
- Opened and verified issue #107; created this task projection on its named branch.

Decisions:
- Use IRE commit `c80166a2` as the source for this snapshot; keep seat/shim routing and fixed fallback chains unchanged.

Evidence:
- `git pull --ff-only origin main` completed as a fast-forward; working tree was clean before this task.
- `continuity issue verify CCL-0081` reports issue #107 OPEN.
- IRE's source CSV at the pinned revision confirms rank 1 is not eligible and selects `cb/deepseek-v4.1-flash`; local defaults still mark it eligible and start with `alicn/deepseek-v4.1-flash`.

Changed:
- `tasks/TASK-CCL-0081-ire-oct7-model-refresh.md`

Blocked/uncertain:
- None.

Next:
- Generate the four tables from the pinned IRE revision and update affected expectations.

### Scope correction — 2026-10-07

Completed:
- Recorded that this refresh also covers the Windows offline first-20 frontier fallback and its shared route-map fixture. The generator writes these together with the Top 20 tables.

Decisions:
- Include the generated Windows frontier fallback because it shares the pinned bundle and route-map fixture; keep live frontier import behavior unchanged.

Evidence:
- Compared with launcher `main` revision `27f951e`, all 20 captured frontier rows differ at the pinned IRE commit. The generator's `sync` function writes the Top 20 files, Windows frontier list, and one route-map fixture in the same run.
- The correction superseding the Top 20-only boundary is in [issue comment 6045326197](https://github.com/Pukujan/claude-code-launcher/issues/107#issuecomment-6045326197).

Changed:
- Issue #107 scope and this task projection.

Blocked/uncertain:
- None.

Next:
- Generate and reconcile the complete pinned Top 20 and frontier snapshot.

### 2026-10-07 19:34:23 UTC — Codex

<!-- continuity:checkpoint {"agent":"Codex","blocked":["none"],"changed":["shared/ire/defaults.json; shared/litellm/config/top20-builtin.csv; Windows and Mac launcher tables; Windows frontier fallback; route-map fixture; table expectation tests; task and current projections; boss claim."],"completed":["Regenerated the shared CSV/defaults, Windows and Mac Top 20 tables, Windows offline first-20 frontier fallback, and pinned route-map fixture from IRE commit c80166a2; updated the two affected model-picker expectations; reconciled CCL-0079 completion projections."],"decisions":["Keep the pinned IRE source; no seat/shim routing, fixed fallback chain, live proxy, or user-local settings changes."],"evidence":["Pinned live IRE fetch succeeded at c80166a2e827c3e0ed1f311735d9596c2ef5ddbc dated 2026-10-07T17:48:43Z; 9 of 20 Top 20 rows changed eligibility or first route and all 20 captured frontier rows changed; continuity validate VALID; git diff --check clean; no tests run locally; latest origin/main remained 27f951e and IRE main remained c80166a2 before push."],"next_action":"Open the linked pull request, verify required CI, and enable auto-merge only after the final push.","protocol_version":"0.1.0-draft","schema":"project-continuity.checkpoint.v1","task_id":"CCL-0081","timestamp":"2026-10-07T19:34:23Z"} -->
<!-- continuity:checkpoint-operation {"payload_sha256":"a6b73a5a976ec7926d269c09a111710c3bf52342a5f1b5fca04c81bde4c4c1be","request_id":"40f6fd4aafee4b12ba141fe1187cb749","schema":"project-continuity.checkpoint-operation.v1","task_id":"CCL-0081"} -->

Completed:
- Regenerated the shared CSV/defaults, Windows and Mac Top 20 tables, Windows offline first-20 frontier fallback, and pinned route-map fixture from IRE commit c80166a2; updated the two affected model-picker expectations; reconciled CCL-0079 completion projections.

Evidence:
- Pinned live IRE fetch succeeded at c80166a2e827c3e0ed1f311735d9596c2ef5ddbc dated 2026-10-07T17:48:43Z; 9 of 20 Top 20 rows changed eligibility or first route and all 20 captured frontier rows changed; continuity validate VALID; git diff --check clean; no tests run locally; latest origin/main remained 27f951e and IRE main remained c80166a2 before push.

Decisions:
- Keep the pinned IRE source; no seat/shim routing, fixed fallback chain, live proxy, or user-local settings changes.

Changed:
- shared/ire/defaults.json; shared/litellm/config/top20-builtin.csv; Windows and Mac launcher tables; Windows frontier fallback; route-map fixture; table expectation tests; task and current projections; boss claim.

Blocked/uncertain:
- none

Next:
- Open the linked pull request, verify required CI, and enable auto-merge only after the final push.

### 2026-10-07 19:35:18 UTC — Codex

<!-- continuity:checkpoint {"agent":"Codex","blocked":["none"],"changed":["tasks/TASK-CCL-0081-ire-oct7-model-refresh.md; checkpoints/CURRENT.md"],"completed":["Updated the task and repository current projections to record that the pinned snapshot is generated and pushed; the next action is opening and reviewing the linked PR."],"decisions":["This is the final planned branch push before creating the pull request and letting the required checks start."],"evidence":["Continuity validation is VALID; issue #107 remains OPEN; latest origin/main remains 27f951e and IRE main remains c80166a2e827c3e0ed1f311735d9596c2ef5ddbc before this push."],"next_action":"Open the linked pull request, verify required CI, and enable auto-merge only after the final push.","protocol_version":"0.1.0-draft","schema":"project-continuity.checkpoint.v1","task_id":"CCL-0081","timestamp":"2026-10-07T19:35:18Z"} -->
<!-- continuity:checkpoint-operation {"payload_sha256":"87eb759f70daeee4302eb5f1fae51091d81eb733dfc68cbed8e258e45d65515d","request_id":"9c3f3d78cc8845679debf15e28a935d2","schema":"project-continuity.checkpoint-operation.v1","task_id":"CCL-0081"} -->

Completed:
- Updated the task and repository current projections to record that the pinned snapshot is generated and pushed; the next action is opening and reviewing the linked PR.

Evidence:
- Continuity validation is VALID; issue #107 remains OPEN; latest origin/main remains 27f951e and IRE main remains c80166a2e827c3e0ed1f311735d9596c2ef5ddbc before this push.

Decisions:
- This is the final planned branch push before creating the pull request and letting the required checks start.

Changed:
- tasks/TASK-CCL-0081-ire-oct7-model-refresh.md; checkpoints/CURRENT.md

Blocked/uncertain:
- none

Next:
- Open the linked pull request, verify required CI, and enable auto-merge only after the final push.

### 2026-10-07 20:43:37 UTC — Codex

<!-- continuity:checkpoint {"agent":"Codex","blocked":["Corrective CI on PR #108 is pending; task remains active until required checks pass and the PR merges."],"changed":["windows/launch-claude-inferhub.ps1; tests/test_ckff_off.py; tests/test_ladder.py; tests/test_ultracode_windows_wizard.py; tasks/TASK-CCL-0081-ire-oct7-model-refresh.md; checkpoints/CURRENT.md; .coord/boss_claim.json"],"completed":["A changed IRE provider left Windows picker defaults pointing outside the current list; defaults now follow the current listed route for the same model family."],"decisions":["Keep the shared fixed fallback configuration, seat/shim scripts, live proxy and saved non-CKFF custom routes unchanged; map only picker defaults and an emptied CKFF-only slot fallback to current IRE routes."],"evidence":["Issue #107 remains OPEN. The correction is recorded in issue comments 6045504469 and 6046443651. PR #108 head 6d7fb069 had required python-tests FAILURE; all other required checks and the supplemental Windows installer passed. No tests were run locally. Continuity validation is VALID, git diff --check is clean, and shared fixed fallback configuration plus seat/shim routing files are unchanged."],"next_action":"Verify required CI on PR #108's exact pushed head and enable auto-merge after this final push; then confirm merge, issue status, and accepted history.","protocol_version":"0.1.0-draft","schema":"project-continuity.checkpoint.v1","task_id":"CCL-0081","timestamp":"2026-10-07T20:43:37Z"} -->
<!-- continuity:checkpoint-operation {"payload_sha256":"2ef261f79e2b8d17017bf374d88b7be147ce1bbead2d3897983ed09dea60b828","request_id":"a204c068f12c442bbf0f350af7c2d062","schema":"project-continuity.checkpoint-operation.v1","task_id":"CCL-0081"} -->

Completed:
- A changed IRE provider left Windows picker defaults pointing outside the current list; defaults now follow the current listed route for the same model family.

Evidence:
- Issue #107 remains OPEN. The correction is recorded in issue comments 6045504469 and 6046443651. PR #108 head 6d7fb069 had required python-tests FAILURE; all other required checks and the supplemental Windows installer passed. No tests were run locally. Continuity validation is VALID, git diff --check is clean, and shared fixed fallback configuration plus seat/shim routing files are unchanged.

Decisions:
- Keep the shared fixed fallback configuration, seat/shim scripts, live proxy and saved non-CKFF custom routes unchanged; map only picker defaults and an emptied CKFF-only slot fallback to current IRE routes.

Changed:
- windows/launch-claude-inferhub.ps1; tests/test_ckff_off.py; tests/test_ladder.py; tests/test_ultracode_windows_wizard.py; tasks/TASK-CCL-0081-ire-oct7-model-refresh.md; checkpoints/CURRENT.md; .coord/boss_claim.json

Blocked/uncertain:
- Corrective CI on PR #108 is pending; task remains active until required checks pass and the PR merges.

Next:
- Verify required CI on PR #108's exact pushed head and enable auto-merge after this final push; then confirm merge, issue status, and accepted history.

### Closeout — 2026-10-10

Completed:
- Reconciled this projection with accepted history: the refresh and the picker-default correction are both on `main`, so the task moves from active to completed.
- Recorded that the later route-policy overlay for the GLM and Qwen families is a separate task, CCL-0083, so a reader does not read this completed refresh as the final word on those routes.

Evidence:
- PR [#108](https://github.com/Pukujan/claude-code-launcher/pull/108) merged as `6130d2dbe669f9cfc3e4b481d46b8446f283b202` on 2026-10-07T20:53:49Z.
- On the final head `78050429e37bea932b02d86e91e111dd3705d063` every required check passed (`gates`, `lint`, `mac-dry-run`, `linux-dry-run`, `python-tests`, `bash 3.2 compatibility`), and the supplemental `windows-installer` check passed too.
- The earlier `python-tests` failure on head `6d7fb069` was corrected before the merge; it is not an open defect.

Decisions:
- Close the task on the merged commit rather than on the pre-merge checkpoints; the merge record is what owns delivery.

Changed:
- `tasks/TASK-CCL-0081-ire-oct7-model-refresh.md`, `checkpoints/CURRENT.md`.

Blocked/uncertain:
- The review-gate question recorded during this task (PR #108 merged with no submitted review while an approving review had been reported required) is resolved as a settings fact, not a code fact: `main`'s branch protection now requires the six status checks and no review, and no rulesets exist. Nothing on this issue's acceptance list depended on it.

Next:
- None for this task. Preserve this record; the GLM and Qwen route policy continues under CCL-0083.

## Handoff

Read PROJECT → CURRENT → this task → minimum relevant spec. Checkpoint before stopping.
