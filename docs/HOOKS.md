# Hook points for the next pull requests

Two features are planned as separate pull requests: an on-demand IRE
recommendations fetch (`shared/ire/`) and a fallback ladder picker. The
launchers mark where each one plugs in with a `HOOK(...)` comment, so
`git grep HOOK` finds them all.

## IRE fetch: `HOOK(ire)` and `HOOK(ire-models)`

Done in PR #10 and issue #11. `shared/ire/ire_fetch.py` runs at start-up in
both launchers (`HOOK(ire)`); its README has the output schema.

- The Mac launcher passes `--top20-csv shared/litellm/config/top20.csv`, so
  the fetched Top 20 lands where `ensure_top20` looks first, and
  `inferhub_top20.yaml` is rebuilt when that file changes. It also passes
  `--table-out`, and `load_ire_table` (`HOOK(ire-models)`) replaces the
  built-in `MODELS` with it.
- Windows still uses its built-in `$Models` table and only exports
  `CCL_IRE_JSON`. Switching it over is the remaining piece of this hook.
- The built-in tables stay as the last resort. `tests/test_top20_tables.py`
  and `tests/test_ire_fetch.py` keep them equal to each other and to
  `shared/ire/defaults.json`.
- The optional frontier list goes to a separate file (`--frontier-out`; on the
  Mac `CCL_IRE_FRONTIER_JSON`), so the six-key bundle the ladder picker reads
  doesn't change.
- `INFERHUB_MANAGEMENT_URL` is listed in `.env.example`; nothing reads it yet.

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
