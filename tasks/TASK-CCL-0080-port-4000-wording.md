# TASK CCL-0080: Say what the port 4000 rule means

<!-- continuity:task {"acceptance":["The AGENTS.md house rule separates changing 127.0.0.1:4000 (no restart, stop, bind, reload or config write) from probing it read-only, which stays allowed, and names the copy-proxy-then-merge path.","PROJECT.md and README.md carry the same intent in their own voice.","The edit stays outside the OIO-managed oio:issue-log-guidance marker block, so .github/scripts/oio_installer.py still finds its section byte-identical.","python -m pytest tests/test_repo_rules.py passes.","No proxy config, seat routing, shim routing or test code changes, and no traffic to port 4000."],"depends_on":[],"goal":"Reword the port 4000 house rule so it forbids changing the live proxy without forbidding the read-only probing an agent needs to verify routing.","id":"CCL-0080","issue_url":"https://github.com/Pukujan/claude-code-launcher/issues/102","next_action":"Push the branch, open the #102 pull request, and merge once the required checks pass.","owner":"Alex; executor agent implements","priority":"P3","protocol_version":"0.1.0-draft","schema":"project-continuity.task.v1","status":"active","why":"The rule read 'Never connect to, restart, stop or bind 127.0.0.1:4000'. An agent followed it literally, declined to send any request to the proxy, and reported live routing as unproven while a config file and a reload log held the answer. The rule exists to stop a change to a proxy that is serving people; a read changes nothing, and a real request is the only proof of what the running router serves. The old wording also never named the safe path for a change."} -->

- Status: active
- Owner: Alex; executor agent implements
- Priority: P3
- Depends on: none
- Leaf issue: [#102](https://github.com/Pukujan/claude-code-launcher/issues/102); parent: none
- Primary writer: Claude; branch `ccl-0080-port-4000-wording`

## Owning issue

- Issue [#102](https://github.com/Pukujan/claude-code-launcher/issues/102), parent: none.
  Issues #103 and #104 were the same text filed twice by mistake and are closed as
  duplicates of #102.

## Write set

- `AGENTS.md` (the house rule only; the OIO-managed section is untouched)
- `PROJECT.md`, `README.md`
- `tasks/`, `checkpoints/CURRENT.md`

## Acceptance criteria

- [x] The `AGENTS.md` rule separates changing 4000 (no restart, stop, bind, reload or config
      write) from read-only probing, which stays allowed, and names the copy-proxy-then-merge path.
- [x] `PROJECT.md` and `README.md` carry the same intent.
- [x] The OIO-managed `oio:issue-log-guidance` block is byte-identical, so
      `.github/scripts/oio_installer.py` still finds its section intact.
- [x] `python -m pytest tests/test_repo_rules.py` passes (10 passed).
- [x] No proxy config, seat or shim routing, or test change; no traffic to port 4000.

## Boundaries

Out of scope: the proxy config, `apply_inferhub_seat.py`, `merge_litellm_config.py`,
`inferhub_fallbacks.yaml`, `tests/test_repo_rules.py`, and anything that runs on 4000.

The four pre-existing `tests/test_ladder.py` failures are unrelated: they fail identically on
clean `main` (`5070ced`) and this change touches only Markdown.

## Checkpoint log

- 2026-10-07: issue #102 filed. Branch `ccl-0080-port-4000-wording` cut from `main` (`5070ced`).
- 2026-10-07: reworded the rule in `AGENTS.md`, `PROJECT.md` and `README.md`. The OIO-managed
  block was compared against the installer's generated text and matches byte for byte.
