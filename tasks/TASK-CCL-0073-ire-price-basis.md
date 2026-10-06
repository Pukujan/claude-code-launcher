# TASK CCL-0073: Show the cheapest well-supplied ask in the picker

<!-- continuity:task {"acceptance": ["The picker and the bundle show the best-route ask for rank-1 DeepSeek V4.1 Flash, 0.00015 in and 0.0006 out per 1M, not 0.022.", "rung_ok and the cheap flag judge the $0.10 cap on the output ask when the row carries one, and fall back to the input ask then the blend when it does not.", "The four built-in artifacts agree with each other and with the current IRE Top 20, and carry no row IRE has gated out of the list.", "A bundle served from cache or the built-in tables logs one warning naming its age and source once it is older than 7 days.", "pytest and the Pester gates pass, and the existing table-equality and contract tests stay green."], "depends_on": [], "goal": "Show the cheapest well-supplied ask in the launcher picker instead of the average seller's blend, refresh the four built-in tables to IRE's current Top 20, and warn when a list is stale.", "id": "CCL-0073", "issue_url": "https://github.com/Pukujan/claude-code-launcher/issues/76", "next_action": "Publish the branch, merge the #76 pull request once the gates pass, then close #76 and confirm the live launcher reads the ask columns.", "owner": "Alex; executor agent implements", "priority": "P2", "protocol_version": "0.1.0-draft", "schema": "project-continuity.task.v1", "status": "active", "why": "The picker priced rank-1 DeepSeek V4.1 Flash at the supply-weighted blend (0.022 per 1M) while its best route (cb/deepseek-v4.1-flash) is listed at 0.00015 in and 0.0006 out, so the price a user saw did not match any route they could call. The offline tables were a frozen 2026-10-03 snapshot that still offered Muse Spark 1.3 Contributor, a model IRE dropped for thin supply."} -->

- Status: active
- Owner: Alex; executor agent implements
- Priority: P2
- Depends on: none
- Leaf issue: [#76](https://github.com/Pukujan/claude-code-launcher/issues/76); parent: none (refs Pukujan/inference-recommendation-engine#94)
- Primary writer: executor-claude-code-launcher; branch `ccl-0073-ire-price-basis`

## Owning issue

- Issue [#76](https://github.com/Pukujan/claude-code-launcher/issues/76), refs Pukujan/inference-recommendation-engine#94. Branch `ccl-0073-ire-price-basis`.

## Write set

- `shared/ire/ire_fetch.py`, `shared/ire/defaults.json`, `shared/ladder/inputs.py`, `shared/ladder/ladder.py`
- `shared/litellm/config/top20-builtin.csv`, `windows/launch-claude-inferhub.ps1`, `mac/Launch Claude InferHub.command`
- `tests/`, `tasks/`, `checkpoints/CURRENT.md`

Only the picker lists change here. The launcher's configs, seat routing and
fallback chains (`shared/litellm/config/inferhub_fallbacks.yaml`) stay as they
are; each row keeps the launcher's curated route id as its first id so nothing
downstream shifts.

## Checkpoint log

- 2026-10-05: issue #76 opened. Branch `ccl-0073-ire-price-basis` cut from `main`.
- 2026-10-05: ask columns wired through `parse_top20`, `_top20_from_csv`, `cap_price` and `format_row`; the four built-in artifacts refreshed to IRE's current Top 20; the bundle grew a `freshness` field with a 7-day stale warning.
- 2026-10-05: `tests/test_ladder.py` 35/35, the three affected files 73 pass with only the known Windows-only `test_cache_dir_per_platform` failure; full-suite failure set identical to the HEAD baseline (23 each); `ruff check .` clean.

### 2026-10-06 01:17:43 UTC — executor-claude-code-launcher

<!-- continuity:checkpoint {"agent":"executor-claude-code-launcher","blocked":["none"],"changed":["shared/ire/ire_fetch.py, shared/ire/defaults.json, shared/ladder/inputs.py, shared/ladder/ladder.py","shared/litellm/config/top20-builtin.csv, windows/launch-claude-inferhub.ps1, mac/Launch Claude InferHub.command","tests/test_ladder.py, tests/test_ire_fetch.py, tests/test_top20_tables.py, tasks/TASK-CCL-0073-ire-price-basis.md, checkpoints/CURRENT.md"],"completed":["Wired IRE's two ask columns through the launcher: parse_top20 and _top20_from_csv read best_route_min_ask_in/out_usdc_per_1m, cap_price judges the $0.10 cap on the output ask then the input ask then the blend, and format_row prints both.","Refreshed all four built-in picker tables to IRE's current Top 20, dropping the rows IRE gated for thin supply including Muse Spark 1.3 Contributor.","Added a freshness field with a 7-day stale warning for bundles served from cache or the built-in tables.","Updated the tests for the new ask basis and the refreshed table order."],"decisions":["no new decisions"],"evidence":["Full-suite failure set identical to the HEAD baseline (23 each, all machine-environment failures), so this change adds none; ruff check . clean; staged blobs are LF and the PowerShell file keeps its UTF-8 BOM."],"next_action":"Open the #76 pull request for ccl-0073-ire-price-basis with auto-merge, then mark #76 done after the gates pass.","protocol_version":"0.1.0-draft","schema":"project-continuity.checkpoint.v1","task_id":"CCL-0073","timestamp":"2026-10-06T01:17:43Z"} -->
<!-- continuity:checkpoint-operation {"payload_sha256":"a935d099881f3669558b9fffbef65a82a8d698cc8e80caf4e834c245c3bc650a","request_id":"3fb65b4229b643be93da571009c85ecc","schema":"project-continuity.checkpoint-operation.v1","task_id":"CCL-0073"} -->

Completed:
- Wired IRE's two ask columns through the launcher: parse_top20 and _top20_from_csv read best_route_min_ask_in/out_usdc_per_1m, cap_price judges the $0.10 cap on the output ask then the input ask then the blend, and format_row prints both.
- Refreshed all four built-in picker tables to IRE's current Top 20, dropping the rows IRE gated for thin supply including Muse Spark 1.3 Contributor.
- Added a freshness field with a 7-day stale warning for bundles served from cache or the built-in tables.
- Updated the tests for the new ask basis and the refreshed table order.

Evidence:
- Full-suite failure set identical to the HEAD baseline (23 each, all machine-environment failures), so this change adds none; ruff check . clean; staged blobs are LF and the PowerShell file keeps its UTF-8 BOM.

Decisions:
- no new decisions

Changed:
- shared/ire/ire_fetch.py, shared/ire/defaults.json, shared/ladder/inputs.py, shared/ladder/ladder.py
- shared/litellm/config/top20-builtin.csv, windows/launch-claude-inferhub.ps1, mac/Launch Claude InferHub.command
- tests/test_ladder.py, tests/test_ire_fetch.py, tests/test_top20_tables.py, tasks/TASK-CCL-0073-ire-price-basis.md, checkpoints/CURRENT.md

Blocked/uncertain:
- none

Next:
- Open the #76 pull request for ccl-0073-ire-price-basis with auto-merge, then mark #76 done after the gates pass.
