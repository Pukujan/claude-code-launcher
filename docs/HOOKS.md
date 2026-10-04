# Hook points for the next pull requests

Two features are planned as separate pull requests: an on-demand IRE
recommendations fetch (`shared/ire/`) and a fallback ladder picker. The
launchers mark where each one plugs in with a `HOOK(...)` comment, so
`git grep HOOK` finds them all.

## IRE fetch: `HOOK(ire)` and `HOOK(ire-models)`

Today the Top 20 comes from `shared/litellm/config/top20-builtin.csv` and from
the `$Models` / `MODELS` tables in the two launchers. Those three must match;
`tests/test_top20_tables.py` checks it.

The contract for the fetch:

- Write the fetched recommendations to `shared/litellm/config/top20.csv`, with
  the same columns as `top20-builtin.csv` (`recommendation_rank`,
  `model_family`, `recommendation_eligible`,
  `supply_weighted_median_cost_usdc_per_1m`, `model_ids`). That path is
  gitignored.
- Both start paths already prefer that file over the built-in one when they
  write `inferhub_top20.yaml` (`HOOK(ire)` in `windows/litellm/start-litellm.ps1`
  and in `ensure_top20` in the Mac launcher). Delete `inferhub_top20.yaml` or
  run `start-litellm.ps1` without `-SkipSync` to regenerate it.
- The picker tables are marked `HOOK(ire-models)`. The fetch PR can load the
  picker rows from the same CSV there. If it does, update
  `tests/test_top20_tables.py` to compare against the CSV instead of the
  hardcoded tables.
- `INFERHUB_MANAGEMENT_URL` is listed in `.env.example` for it; nothing reads it
  yet.

## Fallback ladder picker (issue #5)

This hook is now filled. Both launchers call `shared/ladder/ladder_cli.py`
right after each seat is picked, and once more after the last seat apply. See
`shared/ladder/README.md` for how it works. In short:

- The default ladder comes from `shared/ladder/inputs.py` `load_inputs()`. It
  uses an IRE bundle when one is available and otherwise the Top 20 table plus
  the fixed chains.
- The choice goes to the running proxy as `POST /workbench/reload_runtime`
  with `{"scope": "ladder", "plan": ...}`. That is a partial, in-memory update
  that leaves the seat targets alone.
- Failure policy: each model gets 3 retries, then the request moves to the
  next rung. A model that used up its retries is benched for 180 s, then
  tried again. `CCL_RETRIES` and `CCL_COOLDOWN_S` change this on one machine
  (details in `shared/ladder/README.md`).
- `inferhub_fallbacks.yaml` is still the starting point after a proxy restart.
  The next launch puts the picked ladder back on top.
