# Fallback ladders for the main and advisor seats

A ladder is the ordered list of routes the proxy tries when a seat's primary
model fails.

## Failure policy

- When the 1st model fails, the proxy tries the 2nd, then the 3rd.
- Each model gets **3 retries** before the request moves on, so it's tried up
  to 4 times in all. Retries cover rate limits (including InferHub's 402
  "no provider under bid") and 5xx errors. Timeouts, bad requests and auth
  errors aren't retried.
- The failure that uses up a model's last retry **benches** it for
  **180 seconds**. While it's benched, new requests skip it and go straight
  to the next rung. When the bench time is up, the 1st model is tried again.
- The bench is done by `shared/litellm/bench_after_retries.py`, not by
  LiteLLM's allowed-fails counter. On the proxy, LiteLLM 1.103 logs a failed
  request once, no matter how many retries it used. So with 3 allowed fails a
  model was only benched after 4 failed requests, which in practice meant
  never. The hook listens for LiteLLM's fallback event, which fires only when a
  model's retries are spent, and benches that model for its `cooldown_time`.
  It leaves cooldowns alone for bad requests and connection errors, and it
  doesn't extend a bench that's already running.
- This applies to both seats (main and advisor) and to every rung. It comes
  from three places: `shared/ire/defaults.json` (`retries`, `cooldown_s`),
  the picker's live apply, and the proxy config
  (`shared/litellm/config/inferhub_fallbacks.yaml`).
- To change it on one machine, set these environment variables before
  launching. They win over IRE and the built-in defaults:
  - `CCL_RETRIES`: retries per model, a whole number from 0 to 10 (default 3).
  - `CCL_COOLDOWN_S`: bench time in seconds, from 1 to 86400 (default 180).

## What Alex sees

After he picks the main model, the launcher shows that seat's default ladder:

```
MAIN seat: cb/deepseek-v4.1-flash
Default fallback ladder (IRE source: builtin; cap $0.1/1M):
  each model gets 3 retries, then the next rung; a model that fails is benched for 180 s, then tried again
  1. ali/qwen3.8-flash
  2. cbcn/deepseek-v4-flash

Press Enter to accept, 0 for no fallbacks, or type up to 3 numbers from the list below in order.
```

Below that is the full numbered list, with each route's price and a tag for
anything that can't be picked (gated, over the price cap, the other seat's
vendor, or opt-in only). The same thing happens after the advisor pick.
Entries that don't fit the rules are refused with a reason, and he is asked
again.

## Where the default comes from

`inputs.py` has one function, `load_inputs()`. It reads the JSON that
`shared/ire/ire_fetch.py` writes at launch (both launchers put its path in
`CCL_IRE_JSON`; `--bundle` overrides it). If that file is missing it asks
`ire_fetch.get_recommendations()` directly. The IRE answer already falls back
to its cache and then its own defaults. If even that fails, it uses the launchers' Top 20 table
(`shared/litellm/config/top20.csv`, or `top20-builtin.csv`) and these fixed
chains:

| Seat | Primary | Fallbacks |
| --- | --- | --- |
| main | `cb/deepseek-v4.1-flash` | `ali/qwen3.8-flash`, then `cbcn/deepseek-v4-flash` |
| advisor | `cbcn/glm-5.3-flash` | `cbcn/minimax-m3` |

Retries and bench time follow the failure policy above (3 retries, 180 s).

From that base, the primary itself is dropped, along with any rung the Top 20
no longer marks as eligible or that costs $0.10 per 1M tokens or more. Each
dropped rung is replaced, where possible, with the next eligible Top 20 route.
A ladder never gets longer than the base chain, or longer than 3 rungs.

## Vendors stay apart

A vendor here means the route prefix: `cb/`, `cbcn/`, `ali/` and so on. By
default, main and advisor don't share one. Rungs on the other seat's vendors
are tagged in the list and refused. When the advisor primary is on a vendor
that main's *default* ladder uses, that rung is dropped from main, and the
picker prints a note saying so.

The stock chains run into this. If the advisor is `cbcn/glm-5.3-flash`, main
loses `cbcn/deepseek-v4-flash` and keeps one fallback. Pass
`--allow-shared-vendors` to `choose` to keep the full chain.

## How it reaches the running proxy

Stock LiteLLM's routes for changing fallbacks and models (`/fallback`,
`/model/new`, `/config/update`) won't work without a database, and this proxy
has none. It has no master key either. So `ladder_cli.py apply` uses the
proxy's existing no-restart path, `POST /workbench/reload_runtime`, with
`{"scope": "ladder", "plan": {...}}`.

`shared/litellm/sitecustomize.py` hands that request to `proxy_apply.py`. The
update is partial and in memory. It adds or replaces the `ih/<route>` rung
deployments, sets the fallback list for each seat alias, gives the seat
aliases and the rungs the same retry policy, and puts the cooldown (180 s
by default) and an allowed-fails policy on the seat and rung deployments. It never changes which model a seat alias points to.

When the proxy has no key, the endpoint only answers loopback callers. When a
key is set, it must be sent, and `apply` sends `LITELLM_MASTER_KEY` if it is in
the environment.

The launchers call `apply` after the last seat apply, because the seat's
merge step reloads the stock chains from `inferhub_fallbacks.yaml`. A proxy
restart also goes back to those stock chains until the next launch.

## cx/ routes and `cx/gpt-6.1-sol`

A `cx/` route turns the system prompt into a developer message on Chat
Completions and forces its own instructions instead, unless the request
comes in through the Responses API. So every `cx/` rung is seated as
`openai/responses/cx/...`. In that mode LiteLLM sends the system prompt as
`instructions`, which cx keeps as sent.

`cx/gpt-6.1-sol` is listed in `extra_models.json` as opt-in. It stays hidden
until `CCL_OPT_IN_MODELS=cx/gpt-6.1-sol` is set, and it is never part of a
default ladder. Its usual seller price is $0.02 in and $0.10 out per 1M
tokens, with a context of 272k and up to 128k output tokens. Tool and stream
support are not confirmed yet. The max-price cap is
`CCL_CX_SOL_MAX_PRICE`, or `max_price_per_mtok` in the JSON, and its value
is still for Alex to decide. When a cap is set and the listed output price is
above it, the route is refused.

## Commands

```
python shared/ladder/ladder_cli.py choose --state S --role main --primary cb/deepseek-v4.1-flash
python shared/ladder/ladder_cli.py choose --state S --role advisor --primary cbcn/glm-5.3-flash
python shared/ladder/ladder_cli.py apply  --state S --base-url http://127.0.0.1:4000
python shared/ladder/ladder_cli.py show   --base-url http://127.0.0.1:4000
```

`CLAUDE_IH_LADDER=default` in the launchers takes the defaults without asking,
and `=off` skips the step. With no terminal on stdin, the defaults are taken.

## Testing it against a broken primary

`tests/e2e/` has a server that always answers 503, a keyless test proxy
config whose seat primaries point at that server, and two PowerShell scripts.
Run `start-test-proxy.ps1 -Port 4012`, then `run-fault-injection.ps1 -Port 4012`.
Both refuse port 4000. The real requests use `max_tokens` 8, on rungs under
$0.10 per 1M tokens.

## Two lists: Top 20 and frontier

Every picker can show either the IRE Top 20 or the IRE frontier list (the `frontier` key
from `shared/ire`). That covers the seat primaries and the fallbacks, for both main and
advisor. Each row shows the price per 1M tokens, and any row at or above the price policy
($0.10 per 1M) is marked `OVER $0.10`. On Windows, Tab switches lists in the seat menus.
On the Mac, typing `f` at the seat prompt opens the shared picker (`ladder_cli.py primary`),
and there `t` and `f` switch lists. In the fallback prompt, `t` and `f` switch lists on
both platforms, and you can also type route ids directly to mix the two lists.

## Hand picks versus defaults

The vendor-disjoint rule shapes the default ladder only. Fallbacks you pick by hand are
kept as you typed them, even when they share a route prefix with the other seat. A gated
or over-cap route is kept as well. Each of those gets a one-line warning. A pick is refused
only when it's the primary itself, appears twice, makes more than 3 rungs, isn't in either
list or the extras, or breaks an extras price-cap hook such as `CCL_CX_SOL_MAX_PRICE`.

## cx/ routes as seat primaries

`apply_inferhub_seat.py` seats a `cx/` primary as `openai/responses/cx/...`, the same way
cx fallback rungs are seated, so the system prompt reaches the model as `instructions`.
Every other route still gets `openai/<id>`. Test fixtures in `tests/fixtures/seat/` check
that the non-cx output is byte-for-byte identical to the output before this change.
