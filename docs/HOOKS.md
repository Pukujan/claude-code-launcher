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

## Fallback ladder picker: `HOOK(fallback-ladder)`

Today the ladders come from `shared/litellm/config/inferhub_fallbacks.yaml`,
unchanged from `litellm-ckff-ops`.

The marker sits right after the advisor is picked and before the seat is
applied, in both launchers. A picker there can write its choice to a gitignored
file and pass it to `merge_litellm_config.py --inferhub-fallbacks <file>`, or
edit the role chains in a copy of `inferhub_fallbacks.yaml`. The merge then goes
through the same hot reload as a seat change.

The hot reload (`POST /workbench/reload_runtime`) works without a master key:
with no key set, `shared/litellm/sitecustomize.py` accepts the request from
127.0.0.1 or ::1 only, and `reload_runtime.py` sends no `Authorization` header.
With a key set, the token must match, as before.
