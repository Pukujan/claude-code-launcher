# shared/ire: IRE recommendations at launch

`ire_fetch.py` gives both launchers the current picks from IRE
(`Pukujan/inference-recommendation-engine`, a private repo). It runs on every launch, is
standard-library Python 3.8+, and always returns a usable answer, even with no network
and no GitHub login.

IRE is not a submodule and none of its files are committed here. The helper reads them
from GitHub when the launcher starts and keeps the last good copy on the machine, outside
the repo.

## What it reads from IRE (`main`)

| What | Where in IRE |
|---|---|
| Top 20 list | `operational/telemetry/gravebuster/pipeline/ihub/lists/research_model_top20_recommendations.csv` |
| Price policy | the "below **$0.10 USDC per 1 million tokens** ... effectively free" line in `docs/INFERHUB-API-SETUP.md` |
| Fallback picks (optional) | `operational/recommendations/claude-code-fallbacks.v1.json` |
| Frontier models (optional) | `operational/telemetry/gravebuster/pipeline/ihub/lists/research_model_frontier_recommendations.csv` and `.json` |
| Frontier routes (optional) | `operational/telemetry/gravebuster/pipeline/ihub/lists/research_model_frontier_routes.csv` |

The frontier files arrived with IRE PR #68 (`9a8fba0`). They're optional: if
one is missing, the frontier answer just has less in it, and if all three are
missing it says `"available": false`. They never change the main answer below.

IRE doesn't publish fallback picks yet. I searched `main` at `9a8fba0` on 2026-10-03 and
found none. Until that file exists, the ladders come from `defaults.json`. When it does
appear, it should look like
`{"main": ["id", ...], "advisor": ["id", ...], "retries": 1, "cooldown_s": 180}`. The
`retries` and `cooldown_s` fields are optional, and the same shape nested under
`"ladders"` also works. A malformed file is ignored and the built-in ladders are used.

The helper first resolves `main` to a commit SHA, then reads every file at that SHA. That
way the Top 20 and the price policy in one answer always come from the same IRE commit.

## Where the answer comes from

1. **live**: GitHub, with a 5 second budget for the whole fetch. Auth comes from
   `GITHUB_TOKEN` or `GH_TOKEN` if either is set, otherwise from `gh auth token` if `gh` is
   installed and logged in. With no auth it doesn't try the network at all and goes
   straight to the cache. A refused token (401/403), a token that can't see the repo, a
   timeout or a missing Top 20 file all count as a failed live fetch.
2. **cache**: the last good live answer, stored with the time it was fetched and the IRE
   commit SHA. Only live answers get cached. The cache lives at:
   - Windows: `%LOCALAPPDATA%\claude-code-launcher\ire\ire-cache.json`
   - macOS: `~/Library/Caches/claude-code-launcher/ire/ire-cache.json`
   - Linux: `$XDG_CACHE_HOME/claude-code-launcher/ire/ire-cache.json` (default `~/.cache/...`)
3. **defaults**: `defaults.json` next to this file. Its Top 20 matches
   `shared/litellm/config/top20-builtin.csv`, and a test checks that the two agree.

The token goes out in a request header only. It is never printed or logged, and it is
never written to the cache or the output.

## Running it

```
python3 shared/ire/ire_fetch.py                  # JSON on stdout
python3 shared/ire/ire_fetch.py --out ire.json   # JSON to a file
python3 shared/ire/ire_fetch.py --offline        # skip GitHub: cache, then defaults
  --frontier-out F     also write the frontier list (see below) to F
  --table-out F        also write rank|name|id|eligible|cost lines (the Mac picker)
  --top20-csv F        also write the Top 20 as CSV for sync_inferhub_top20.py
  --timeout 5          seconds for the whole fetch
  --cache-dir DIR      use another cache folder
```

The JSON is the only thing written to stdout. One status line goes to stderr and says
where the answer came from, for example:

```
[ire] source=live  IRE Pukujan/inference-recommendation-engine@9a8fba0517 via gh auth token
[ire] source=cache  IRE @9a8fba0517 fetched 2026-10-04T00:06:52Z  (GitHub skipped: GitHub refused the credentials (HTTP 401) (auth from GH_TOKEN))
[ire] source=defaults  built-in picks  (GitHub skipped: gh is installed but not logged in; no cache yet)
```

From Python, `get_recommendations(offline=False, timeout=5.0)` returns the same dict, and
`get_recommendations_and_frontier(...)` returns `(bundle, frontier)`.

The exit code is always 0, because a launcher should start even when IRE can't be
reached. These environment variables change its behaviour: `CCL_IRE_OFFLINE=1` (same as
`--offline`), `CCL_IRE_CACHE_DIR`, and `CCL_IRE_API_BASE` (a GitHub API base URL other
than the default).

### In the launchers

- **Mac** (`mac/Launch Claude InferHub.command`, `fetch_ire`): runs after the venv is
  ready, writes `$STATE_DIR/ire.json` (`CCL_IRE_JSON`), `$STATE_DIR/ire-frontier.json`
  (`CCL_IRE_FRONTIER_JSON`), `$STATE_DIR/ire-table.txt` (which replaces the picker's
  built-in table) and `shared/litellm/config/top20.csv` (for the `ih/` deployments).
- **Windows** (`windows/launch-claude-inferhub.ps1`, `Get-IreRecommendations`): runs
  before the pickers, writes `%LOCALAPPDATA%\claude-code-launcher\ire.json` and sets
  `$env:CCL_IRE_JSON`.

Both print the status line with an `IRE:` prefix. Neither will stop the launch if the
helper fails. The Mac picker uses the fetched Top 20; the Windows picker still uses its
built-in table. The ladder picker (issue #5) is the part that reads `CCL_IRE_JSON`.

## Output schema

Exactly these six top-level keys. The ladder picker (#5) depends on them, so don't add,
rename or drop any without changing that picker too.

```jsonc
{
  "source": "live",            // "live" | "cache" | "defaults"
  "top20": [                   // sorted by rank; 20 rows from IRE, 20 in the defaults
    {
      "rank": 1,
      "name": "DeepSeek V4.1 Flash",
      "vendor": "DeepSeek",
      "eligible": true,        // IRE's recommendation_eligible
      "gate_reasons": [],      // e.g. ["insufficient_provider_breadth"] when eligible is false
      "cost_per_mtok": 0.022108,          // USDC per 1M tokens, or null if IRE has none
      "ids": ["cb/deepseek-v4.1-flash", "cbcn/deepseek-v4.1-flash"]   // InferHub routes, IRE's order
    }
  ],
  "price_policy": {
    "free_below_per_mtok": 0.1,        // a route costing less than this counts as effectively free
    "unit": "USDC per 1M tokens",
    "source": "docs/INFERHUB-API-SETUP.md@9a8fba0517"
  },
  "ladders": {                 // ordered InferHub model ids, first is the primary
    "main":    ["cb/deepseek-v4.1-flash", "ali/qwen3.8-flash", "cbcn/deepseek-v4-flash"],
    "advisor": ["cbcn/glm-5.3-flash", "cbcn/minimax-m3"]
  },
  "retries": 1,                // retries on a rung before moving down the ladder
  "cooldown_s": 180            // seconds a failed rung sits out
}
```

The ladder ids are bare InferHub ids, without the `ih/` prefix that LiteLLM deployments
use. Provenance (fetch time and IRE SHA) isn't in the output. It's in the stderr line and
the cache file, which looks like
`{"fetched_at": "<UTC ISO>", "source_sha": "<40 hex>", "repo", "ref", "bundle": {...}}`.

## Frontier output

Written by `--frontier-out`, and cached next to the bundle (only live answers are cached).
These eight keys, always:

```jsonc
{
  "available": true,           // false when IRE has none of the three files (or no live/cached copy)
  "source": "live",            // "live" | "cache" | "none"
  "ire_sha": "9a8fba05...",    // the IRE commit it was read at (the same one as the bundle)
  "files": {"recommendations_csv": true, "recommendations_json": true, "routes_csv": true},
  "schema": "ihub-frontier-recommendations/v1",   // from the JSON, or null
  "generated_at": "2026-10-04T00:02:28Z",
  "models": [
    {"rank": 1, "name": "GPT 6 Astra", "vendor": "OpenAI", "tier": "frontier", "eligible": true,
     "gate_reasons": [], "best_route": "cb/gpt-6-astra", "cost_per_mtok": 0.1,
     "system_prompt_handling": "upstream_note", "preferred_endpoint": "",
     "ids": ["cb/gpt-6-astra", "cx/gpt-6-astra"]}
  ],
  "routes": [
    {"rank": 1, "name": "GPT 6 Astra", "route": "cx/gpt-6-astra", "best": false, "health": "healthy",
     "cost_per_mtok": 0.1, "system_prompt_handling": "developer_message",
     "preferred_endpoint": "/v1/responses", "required_instructions_value": "You are a helpful assistant."}
  ]
}
```

Models and routes come from the two CSVs. If a CSV is missing, the same rows are taken
from the JSON. `system_prompt_handling` and `preferred_endpoint` are passed through as
IRE wrote them: cx routes say `developer_message` and `/v1/responses`. Nothing in this
repository routes on them yet. The proxy sends cx models over chat completions today,
so a picker that offers cx frontier routes has to deal with that first.

## Tests

`tests/test_ire_fetch.py` mocks `urllib.request.urlopen` and `gh`, so no test touches the
network or needs a token. It covers online (env token, `gh auth token`, a price cap taken
from the doc, IRE picks, malformed picks), offline with a cache, offline with no cache, a
slow GitHub, bad auth (401 with and without a cache, and a token that can't see the
repo), the output contract and the CLI. The frontier tests cover missing files, the CSVs
read at the bundle's commit (cx routes keep `developer_message` and `/v1/responses`), the
JSON filling in for missing CSVs, the cache and the defaults.
