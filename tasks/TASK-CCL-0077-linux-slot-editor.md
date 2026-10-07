# TASK CCL-0077: Per-slot model picks on Mac and Linux

<!-- continuity:task {"acceptance":["An interactive launch on macOS or Linux offers a model-slots step covering all four [CC] slots (sonnet, opus, fable, haiku), each with a first model and up to two fallbacks, chosen with the arrow keys.","haiku can be set to the same chain as sonnet in one pick, and saved chains are offered first (\"use the saved slots\") with a summary of all four chains.","The chosen chains are saved in last-picks.json under slots (with haiku_same), the shape the Windows launcher writes, and survive the launch-target write.","apply_seat passes all four chains through apply_inferhub_seat.py --slot, so the opus and haiku chains reach the running proxy; checked by reading config/inferhub_seat.json after a launch on a test port, never 4000.","A no-TTY, --non-interactive, CLAUDE_IH_SLOTS=off or CLAUDE_IH_MAIN launch shows no menus, keeps the existing --main/--advisor behaviour, and leaves the dry run's piped answers working.","shellcheck is clean and the body stays bash 3.2 compatible."],"depends_on":[],"goal":"Port the Windows launcher's model-slots step to the shared launcher body, so the Mac and Linux launcher can set the opus (planning) and haiku (background) chains and every slot's fallbacks, instead of only sonnet's and fable's first models.","id":"CCL-0077","issue_url":"https://github.com/Pukujan/claude-code-launcher/issues/91","next_action":"Push the branch, open the #91 pull request with auto-merge, and verify the required checks.","owner":"Alex; executor agent implements","priority":"P2","protocol_version":"0.1.0-draft","schema":"project-continuity.task.v1","status":"completed","why":"The Windows launcher opens with a model-slots step; the shared body never had one. apply_seat() only passes --main and --advisor, which set the FIRST model of the sonnet and fable slots, so on Mac and Linux the opus and haiku chains could not be chosen at all and no slot could be given a fallback. The ladder picker that once covered fallbacks is off by default since issue #53, so there was no interactive path to either."} -->

- Status: completed
- Owner: Alex; executor agent implements
- Priority: P2
- Depends on: none
- Leaf issue: [#91](https://github.com/Pukujan/claude-code-launcher/issues/91); parent: [#53](https://github.com/Pukujan/claude-code-launcher/issues/53)
- Primary writer: executor-claude-code-launcher; branch `ccl-0077-linux-slot-editor`

## Owning issue

- Issue [#91](https://github.com/Pukujan/claude-code-launcher/issues/91), a child of
  [#53](https://github.com/Pukujan/claude-code-launcher/issues/53) (per-slot model picks with
  fallback chains and per-slot onboarding). Parent: #53.

## Write set

- `mac/Launch Claude InferHub.command` (the shared body `linux/` also runs)
- `mac/tests/unit_tests.sh`
- `mac/README.md`, `docs/PARITY.md`
- `tasks/`, `checkpoints/CURRENT.md`

`windows/`, `shared/` and the proxy config are not touched: `apply_inferhub_seat.py --slot`
and `slots.py` already do the work, and the Windows launcher already drives them.

## Acceptance criteria

- [x] An interactive launch offers a model-slots step over all four slots (sonnet, opus, fable,
      haiku), each a first model and up to two fallbacks, chosen with the arrow keys.
- [x] haiku can be set to the same chain as sonnet in one pick; saved chains are offered first
      with a summary of all four.
- [x] The chains are saved in `last-picks.json` under `slots` (with `haiku_same`), the shape
      Windows writes, and survive the launch-target write.
- [x] `apply_seat` passes all four chains via `--slot`, so opus and haiku reach the proxy.
- [x] No terminal, `--non-interactive`, `CLAUDE_IH_SLOTS=off` or `CLAUDE_IH_MAIN` shows no
      menus and keeps the existing `--main`/`--advisor` behaviour.
- [x] `shellcheck` clean; bash 3.2 compatible; the dry run still passes.

## Boundaries

Out of scope: `windows/`, `shared/`, the proxy config, the ladder picker's default-off
behaviour, and any change to which model a slot alias points at.

Follow-ups (proposals, not part of this change):

- A "one-pick quick path" that fills all four slots from the main model, which #53 sketches.
- Named presets, which #53 also sketches; today the saved chains are the only preset.

## Checkpoint log

- 2026-10-07: issue #91 opened as a child of #53. Branch `ccl-0077-linux-slot-editor` cut
  from `main` (`70db973`).
- 2026-10-07: the slots step added to the shared body (`pick_slots`, `slot_rung_pick`,
  `chain_at`/`chain_set`, `slots_file`), `apply_seat` passes `--slot`, `save_last_picks`
  preserves the slots, and 21 unit checks added.
- 2026-10-07: merged as `82169e1` (PR #92; issue #91 closed automatically). Every required check
  passed: `gates`, `lint`, `mac-dry-run`, `linux-dry-run`, `python-tests`,
  `bash 3.2 compatibility`.
