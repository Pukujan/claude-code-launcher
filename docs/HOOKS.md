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

Since issue #53 the slot chains (a first model and up to two fallbacks per
Claude Code slot, picked in the launcher) replace the ladder on Windows, and
the Mac launcher only runs it when `CLAUDE_IH_LADDER=ask` or `=default`. The rest of this section
describes the ladder for that case. `shared/ladder/README.md` has the details.
In short:

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
  searches through the keyless `ddgs` package: Yahoo, DuckDuckGo, then ddgs's
  `auto` mix, and the same again after a 2 s back-off, within 20 s
  (`CCL_DDGS_BACKENDS` changes the list). Results without a URL don't count,
  successes are cached for 10 minutes, and when everything fails Claude Code
  gets `Search failed: ...` with the reasons instead of an empty result list.
  `CCL_WEB_SEARCH_CHAIN` (default: `tinyfish` when `TINYFISH_API_KEY` is set,
  then `ddgs`, then `you_com`, which needs no key) can add LiteLLM search providers
  around it, e.g. `searxng,ddgs,brave` with `SEARXNG_API_BASE` /
  `BRAVE_API_KEY` set. Each search logs a timestamped `[web_search]` line in
  `shared/litellm/logs/litellm.out.log`. A `search_tools` list already in
  `config.yaml` wins.
- **SlopSearX first, paid APIs last (Windows, issue #51).** SlopSearX
  (https://github.com/magnus919/SlopSearX) is a SearXNG-compatible meta search
  service that runs locally without Docker. `windows\slopsearx\setup-slopsearx.ps1`
  clones it next to this checkout, builds its venv with uv, starts it on
  `127.0.0.1:18080` (`-Port` to change) from a logon scheduled task with no
  window (`SlopSearX`; start script and logs in `%USERPROFILE%\.slopsearx`),
  and writes the chain to the proxy's machine-local env file
  `shared\litellm\.env.local` (gitignored). `start-litellm.ps1` loads that
  file after the key file: the repository's `.env`, or, only when that is
  missing, the desktop and InferHub env files (`-LocalEnvFile` to point
  elsewhere). A typical file:

  ```
  CCL_WEB_SEARCH_CHAIN=searxng,tinyfish,ddgs,you_com,tavily,exa
  SEARXNG_API_BASE=http://127.0.0.1:18080
  CCL_ENV_ALIASES=TINYFISH_API_KEY=<name in the desktop env>,TAVILY_API_KEY=<name>,EXA_API_KEY=<name>
  ```

  `CCL_ENV_ALIASES` copies keys that a loaded env file keeps under other names
  to the names LiteLLM reads; only names go in `.env.local`. With the keys in
  the repository's `.env` under their standard names (issue #64) the line is
  not needed. `exa` is short for LiteLLM's `exa_ai`; `you` and `youcom`
  mean `you_com`. With this chain a search goes to SlopSearX, then TinyFish
  Search (LiteLLM's `tinyfish`, free key, 30 requests/min), then ddgs, then
  You.com (LiteLLM's `you_com`; with `YOUCOM_API_KEY` unset it uses You.com's
  keyless free tier, 100 queries/day per IP), and Tavily and Exa (paid) only
  if every free source fails (issue #56). A provider without its key just
  fails and the chain moves on. The `[web_search]` log line names the source
  that answered (`searxng ok: ...`), and a source that answers with nothing
  usable logs `<source> gave 0 usable results ...`. Run the setup
  with `-Uninstall` to remove the task; the proxy needs a restart to pick up a
  changed chain.
- **Haiku slot max_tokens floor.** WebFetch summaries go to the haiku slot with a
  small `max_tokens`; reasoning models could spend all of it thinking and send
  back nothing. `shared/litellm/fast_min_tokens.py` raises `max_tokens` to 4096
  for the haiku slot names only. `CCL_FAST_MIN_MAX_TOKENS` changes the floor (0
  turns it off).
- **Request fixes.** `shared/litellm/request_fixes.py` does three small things.
  A `claude-*` id the proxy does not serve goes to the slot in its name
  (`claude-opus-4-8` to opus, `claude-3-5-haiku-*` to haiku) and a name ending
  in `[1m]` loses the suffix; a `claude-*` name with no slot word goes to
  sonnet with a `WARNING: unmapped model` log line. Names the proxy serves keep
  their routing. An assistant `tool_use` with no `tool_result` in the next user
  message gets a placeholder result ("Tool call was rejected or not run."), so
  strict backends such as DeepSeek don't answer 400. A non-streaming reply with
  no text and no tool call is retried once on the same model; a second empty
  reply from that model moves the request to the slot's next model. Empty
  replies never bench a model. Streaming replies are not checked.
- **Advisor.** LiteLLM runs Claude Code's advisor tool itself for
  non-Anthropic providers, and it sends the advisor model the agent's history
  with its tool calls and tool results still in it, no system prompt and no
  tools. DeepSeek reads that as its own agent loop and writes its next tool
  call as raw `DSML` text, which comes back as the "advice".
  `shared/litellm/advisor_fix.py` rewrites that request as plain text (tool
  calls and results spelled out, thinking dropped) and puts a short "you are the
  advisor, reply with plain-text advice" framing in front of the question. The
  start-up log says `[sitecustomize] advisor fix installed`.
