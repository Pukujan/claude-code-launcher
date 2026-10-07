# TASK CCL-0081: Refresh the built-in model picker from IRE's October 7 list

<!-- continuity:task {"acceptance":["The four built-in Top 20 tables match the pinned IRE source revision in rank, family, eligibility, selected provider route, and ask prices.","The Windows offline first-20 frontier fallback and shared route-map fixture match the pinned IRE source revision.","Existing table and route-mapping checks pass in required pull request CI.","No seat or shim routing, fixed fallback chain, live proxy, or secret changes."],"depends_on":[],"goal":"Refresh the built-in Top 20 and Windows offline frontier tables from IRE's October 7 source revision.","id":"CCL-0081","issue_url":"https://github.com/Pukujan/claude-code-launcher/issues/107","next_action":"Generate the synchronized tables from the pinned IRE revision and update affected expectations.","owner":"Alex; Codex implements","priority":"P2","protocol_version":"0.1.0-draft","schema":"project-continuity.task.v1","status":"active","why":"IRE's current source differs from the October 6 built-in snapshot in model eligibility, selected provider routes, and frontier data."} -->

- Status: active
- Owner: Alex; Codex implements
- Priority: P2
- Depends on: none
- Leaf issue: [#107](https://github.com/Pukujan/claude-code-launcher/issues/107); parent: none; dependencies: none
- Primary writer: Codex; branch: `codex/ccl-0081-ire-oct7-model-refresh`

## Goal

Refresh the built-in Top 20 and Windows offline frontier tables from IRE's October 7 source revision.

## Why

IRE's current source differs from the October 6 built-in snapshot in model eligibility, selected provider routes, and frontier data.

## Allowed files

- `shared/litellm/config/top20-builtin.csv`
- `shared/ire/defaults.json`
- `windows/launch-claude-inferhub.ps1`
- `mac/Launch Claude InferHub.command`
- `tests/fixtures/ire/top20-frontier-route-map.json`
- `tests/test_top20_tables.py` and `tests/test_pkg_settings_sync.py`
- `tasks/` and `checkpoints/CURRENT.md`

## Human outcome

When IRE cannot be reached, the Windows launcher will offer the same current model eligibility and selected provider routes as IRE's pinned list.

## Scope and boundaries

- In scope: regenerate the four built-in Top 20 tables, Windows's offline first-20 frontier fallback, and their route-map fixture from IRE commit `c80166a2e827c3e0ed1f311735d9596c2ef5ddbc`; update affected table expectations.
- Out of scope: the full lab roster in issue #100 and PR #101, IRE changes, live frontier import behavior, seat/shim routing, fixed fallback chains, live proxy activity, and user-local settings.
- Dependencies/uncertainty: none. The current IRE source revision is pinned for this increment; future drift belongs to the reviewed refresh workflow.

## Acceptance criteria

- [ ] The shared CSV, shared JSON defaults, Windows table, and Mac table match IRE's 20 rows at the pinned source revision in rank/order, model family, eligibility, selected provider route, and ask prices.
- [ ] The Windows offline first-20 frontier fallback and route-map fixture match the same pinned IRE bundle.
- [ ] Existing table-equality and route-mapping checks pass in required pull request CI.
- [ ] No seat or shim routing, fixed fallback chain, live proxy, or secret changes.
- [ ] A linked pull request passes required CI and is set to auto-merge only after its final push.

## Evidence and sources

Observed at launcher `main` revision `27f951e`: `shared/ire/defaults.json` records an October 6 snapshot. The IRE `main` source commit [c80166a2e827c3e0ed1f311735d9596c2ef5ddbc](https://github.com/Pukujan/inference-recommendation-engine/commit/c80166a2e827c3e0ed1f311735d9596c2ef5ddbc) was published 2026-10-07 17:48:43 UTC. A row comparison found 9 of 20 rows with changed eligibility or first provider route. For rank 1, IRE says DeepSeek V4.1 Flash is not eligible and selects `cb/deepseek-v4.1-flash`; local defaults say eligible and start with `alicn/deepseek-v4.1-flash`. The user's desktop entry point forwards to the repository's Windows launcher.

## Reproduction details (only when needed)

Starting revision, material inputs/configuration, runtime, exact command or prompt, observed result, and limitations.

## Related records

- Leaf owning issue: #107; parent: none; dependencies: none.
- Primary writer: Codex; branch: `codex/ccl-0081-ire-oct7-model-refresh`; source issue #107 is OPEN as of 2026-10-07.
- Related issue: #96, which introduced the generated-table workflow; source revision: IRE `main` `c80166a2e827c3e0ed1f311735d9596c2ef5ddbc`; scope correction: [issue comment 6045326197](https://github.com/Pukujan/claude-code-launcher/issues/107#issuecomment-6045326197). No PR, CI evidence, or push receipt yet.

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

## Handoff

Read PROJECT → CURRENT → this task → minimum relevant spec. Checkpoint before stopping.
