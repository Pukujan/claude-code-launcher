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
