# TASK CCL-0075: Refresh the launcher's built-in Top 20 to IRE's current list

<!-- continuity:task {"acceptance":["The four built-in artifacts carry IRE's current Top 20 in the same order and with the same eligibility flags.","GPT 5.6 Luna reads not eligible; Gemini 3.8 Flash and Hy4 Preview are gone; the model 4.6 and Muse Spark 1.3 Contributor are present.","Each row keeps the launcher's curated route id as its first id, so the seat chains and inferhub_fallbacks.yaml stay untouched.","The table-equality, ladder and Mac unit tests pass with the updated expectations.","No secret is committed."],"depends_on":[],"goal":"Refresh the launcher's four built-in picker tables to IRE's current Top 20 so the offline fallback matches the live list, without moving any seat chain or fallback chain.","id":"CCL-0075","issue_url":"https://github.com/Pukujan/claude-code-launcher/issues/84","next_action":"Publish the branch, merge the #84 pull request once the gates pass, then confirm the four tables read IRE's current Top 20 and close #84.","owner":"Alex; executor agent implements","priority":"P2","protocol_version":"0.1.0-draft","schema":"project-continuity.task.v1","status":"active","why":"The four built-in tables are a 2026-10-03 snapshot taken for issue #76, before IRE tightened its list on 2026-10-05 (inference-recommendation-engine#98). They still mark GPT 5.6 Luna recommendation-eligible when IRE gates it open_weight_unverified, still offer Gemini 3.8 Flash and Hy4 Preview which IRE dropped, and never show the two families IRE added: the model 4.6 at rank 19 and Muse Spark 1.3 Contributor at rank 20. The launcher reads IRE live at launch, so a user only sees these rows when GitHub is unreachable or the cache is cold, but that is exactly the offline path."} -->

- Status: active
- Owner: Alex; executor agent implements
- Priority: P2
- Depends on: none
- Leaf issue: [#84](https://github.com/Pukujan/claude-code-launcher/issues/84); parent: none (refs Pukujan/inference-recommendation-engine#94, #98)
- Primary writer: executor-claude-code-launcher; branch `ccl-0075-ire-top20-refresh`

## Owning issue

- Issue [#84](https://github.com/Pukujan/claude-code-launcher/issues/84). Follows the closed #76, whose refresh this snapshot was taken from.

## Write set

- `shared/litellm/config/top20-builtin.csv`, `shared/ire/defaults.json`, `windows/launch-claude-inferhub.ps1`, `mac/Launch Claude InferHub.command`
- `tests/test_ladder.py`, `mac/tests/unit_tests.sh`
- `tasks/`, `checkpoints/CURRENT.md`

Only the picker lists change here. The launcher's configs, seat routing and
fallback chains (`shared/litellm/config/inferhub_fallbacks.yaml`) stay as they
are; each row keeps the launcher's curated route id as its first id so nothing
downstream shifts.

## Acceptance criteria

- [ ] The four built-in artifacts carry IRE's current Top 20 in the same order and with the same eligibility flags.
- [ ] GPT 5.6 Luna reads not eligible; Gemini 3.8 Flash and Hy4 Preview are gone; the model 4.6 and Muse Spark 1.3 Contributor are present.
- [ ] Each row keeps the launcher's curated route id as its first id, so the seat chains and `inferhub_fallbacks.yaml` stay untouched.
- [ ] The table-equality, ladder and Mac unit tests pass with the updated expectations.
- [ ] No secret is committed.

## Checkpoint log

- 2026-10-06: issue #84 opened. Branch `ccl-0075-ire-top20-refresh` cut from `main`.
- 2026-10-06: the four tables regenerated from IRE's committed Top 20 CSV; a hash check confirms all four match IRE row for row. Five expectations in `tests/test_ladder.py` and one in `mac/tests/unit_tests.sh` moved to the new families. Full-suite failure set identical to the `main` baseline (23, all machine-environment), and the Mac unit run is 83 pass with the same three Windows-only failures as `main`.

### 2026-10-06 03:13:14 UTC — executor-claude-code-launcher

<!-- continuity:checkpoint {"agent":"executor-claude-code-launcher","blocked":["none"],"changed":["shared/litellm/config/top20-builtin.csv, shared/ire/defaults.json, windows/launch-claude-inferhub.ps1, mac/Launch Claude InferHub.command","tests/test_ladder.py, mac/tests/unit_tests.sh","tasks/TASK-CCL-0075-ire-top20-refresh.md, checkpoints/CURRENT.md"],"completed":["Regenerated the four built-in picker tables from IRE's committed Top 20 CSV: shared/litellm/config/top20-builtin.csv, shared/ire/defaults.json, the Windows $Models block and the Mac MODELS block.","A hash check confirms all four match IRE's list row for row: same order, same eligibility flags, same ask prices, same ids.","Moved five expectations in tests/test_ladder.py and one in mac/tests/unit_tests.sh to the refreshed families: GPT 5.6 Luna now gated, MiMo V2.5 at 11, Kimi K2.6 at 15, GPT 6 Luna at 17, the model 4.6 at 19, Muse Spark 1.3 Contributor at 20."],"decisions":["No config, seat chain or fallback chain changes; each row keeps the launcher's curated route id as its first id. shared/litellm/config/inferhub_fallbacks.yaml still names ag/gemini-3.8-flash-high in its seat-only block, which is inert (it is in no chain or slot) and is left as-is because the fallback chains do not change."],"evidence":["Full pytest failure set identical to the main baseline (23, all machine-environment); 366 pass. Mac unit run 83 pass with the same three Windows-only failures as main (symlink creation and two ultracode picker cases that need POSIX process substitution). ruff check . clean. Staged blobs are LF-only and the PowerShell file keeps its UTF-8 BOM.","Regenerating shared/litellm/config/inferhub_top20.yaml locally gives rank-1 DeepSeek V4.1 Flash input_cost_per_token 1.5e-10 and output_cost_per_token 6e-10."],"next_action":"Publish the #84 pull request for ccl-0075-ire-top20-refresh with auto-merge, then confirm the four tables read IRE's current Top 20 and mark #84 done after the gates pass.","protocol_version":"0.1.0-draft","schema":"project-continuity.checkpoint.v1","task_id":"CCL-0075","timestamp":"2026-10-06T03:13:14Z"} -->
<!-- continuity:checkpoint-operation {"payload_sha256":"4865ffce073baf1fdbb47c0854502e5da537ebb566a6120ca6a73037dff72d78","request_id":"b9ce98af7a5f446b8592531a1e81eae9","schema":"project-continuity.checkpoint-operation.v1","task_id":"CCL-0075"} -->

Completed:
- Regenerated the four built-in picker tables from IRE's committed Top 20 CSV: shared/litellm/config/top20-builtin.csv, shared/ire/defaults.json, the Windows $Models block and the Mac MODELS block.
- A hash check confirms all four match IRE's list row for row: same order, same eligibility flags, same ask prices, same ids.
- Moved five expectations in tests/test_ladder.py and one in mac/tests/unit_tests.sh to the refreshed families: GPT 5.6 Luna now gated, MiMo V2.5 at 11, Kimi K2.6 at 15, GPT 6 Luna at 17, the model 4.6 at 19, Muse Spark 1.3 Contributor at 20.

Evidence:
- Full pytest failure set identical to the main baseline (23, all machine-environment); 366 pass. Mac unit run 83 pass with the same three Windows-only failures as main (symlink creation and two ultracode picker cases that need POSIX process substitution). ruff check . clean. Staged blobs are LF-only and the PowerShell file keeps its UTF-8 BOM.
- Regenerating shared/litellm/config/inferhub_top20.yaml locally gives rank-1 DeepSeek V4.1 Flash input_cost_per_token 1.5e-10 and output_cost_per_token 6e-10.

Decisions:
- No config, seat chain or fallback chain changes; each row keeps the launcher's curated route id as its first id. shared/litellm/config/inferhub_fallbacks.yaml still names ag/gemini-3.8-flash-high in its seat-only block, which is inert (it is in no chain or slot) and is left as-is because the fallback chains do not change.

Changed:
- shared/litellm/config/top20-builtin.csv, shared/ire/defaults.json, windows/launch-claude-inferhub.ps1, mac/Launch Claude InferHub.command
- tests/test_ladder.py, mac/tests/unit_tests.sh
- tasks/TASK-CCL-0075-ire-top20-refresh.md, checkpoints/CURRENT.md

Blocked/uncertain:
- none

Next:
- Publish the #84 pull request for ccl-0075-ire-top20-refresh with auto-merge, then confirm the four tables read IRE's current Top 20 and mark #84 done after the gates pass.
