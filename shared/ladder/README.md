# Fallback ladders for the main and advisor seats

A ladder is the ordered list of routes the proxy tries when a seat's primary
model fails. Each failure gets one retry, and then the request goes to the
next rung. A route that keeps failing is benched for 180 seconds, so later
requests skip it and go straight to a working rung.

## What Alex sees

After he picks the main model, the launcher shows that seat's default ladder:

```
MAIN seat: cb/deepseek-v4.1-flash
Default fallback ladder (IRE source: builtin; cap $0.1/1M; 1 retry, then next rung; 180 s cooldown):
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

`inputs.py` has one function, `load_inputs()`. It uses an IRE bundle when one
is available, either passed with `--bundle` or returned by the `shared/ire`
module once it lands. Otherwise it uses the launchers' Top 20 table
(`shared/litellm/config/top20.csv`, or `top20-builtin.csv`) and these fixed
chains:

| Seat | Primary | Fallbacks |
| --- | --- | --- |
| main | `cb/deepseek-v4.1-flash` | `ali/qwen3.8-flash`, then `cbcn/deepseek-v4-flash` |
| advisor | `cbcn/glm-5.3-flash` | `cbcn/minimax-m3` |

The retry count is 1 and the cooldown is 180 seconds.

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
deployments, sets the fallback list and retry policy for each seat alias, and
puts a 180-second cooldown with an allowed-fails policy on the seat and rung
deployments. It never changes which model a seat alias points to.

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
