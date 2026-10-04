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
- The optional frontier list rides in the bundle under the extra `frontier`
  key (`[]` when IRE has none). The pickers and the ladder picker read it from
  `CCL_IRE_JSON`.
- `INFERHUB_MANAGEMENT_URL` is listed in `.env.example`; nothing reads it yet.

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

## Proxy-side fixes for Claude Code tools

- **WebSearch.** Claude Code asks for Anthropic's server-side `web_search`
  tool, which only Anthropic runs. `merge_litellm_config.py` turns on LiteLLM's
  `websearch_interception` callback and a `duckduckgo` search tool, and
  `shared/litellm/web_search.py` (installed by `sitecustomize.py`) runs those
  searches through the keyless `ddgs` package: Yahoo, then ddgs's `auto` mix,
  then Yahoo again, 1 s apart. A `search_tools` list already in `config.yaml`
  wins.
- **Fast seat max_tokens floor.** WebFetch summaries go to the fast seat with a
  small `max_tokens`; reasoning models could spend all of it thinking and send
  back nothing. `shared/litellm/fast_min_tokens.py` raises `max_tokens` to 4096
  for the fast aliases only. `CCL_FAST_MIN_MAX_TOKENS` changes the floor (0
  turns it off).
