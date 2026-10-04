#!/usr/bin/env python3
"""Fallback ladders for the main and advisor seats.

A ladder is the ordered list of routes LiteLLM tries after the seat's primary
fails (after one retry). This module:
  - works out the default ladder for a seat from the inputs that
    inputs.load_inputs() returns (IRE when available, else the fixed chains);
  - keeps vendors (the route prefix: cb/, cbcn/, ali/, ...) disjoint between
    main and advisor unless told otherwise;
  - asks the operator to accept the default (Enter) or pick up to 3 rungs;
  - turns the result into LiteLLM deployments + router fallbacks.

Standard library only. The interactive part reads plain stdin, so the same
code runs from the Windows launcher (PowerShell) and the Mac launcher (zsh).
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
EXTRA_MODELS_PATH = HERE / "extra_models.json"
MAX_RUNGS = 3

MAIN_NAMES = ["main", "sonnet", "claude-sonnet-5", "ih-main", "ih-sonnet", "inferhub-sonnet"]
ADVISOR_NAMES = ["advisor", "opus", "claude-opus-5-5", "claude-fable-5", "claude-fable-5-1",
                 "ih-advisor", "ih-opus", "inferhub-opus"]
ROLE_NAMES = {"main": MAIN_NAMES, "advisor": ADVISOR_NAMES}


def prefix(route_id: str | None) -> str | None:
    """Vendor = route prefix, e.g. 'cbcn' for 'cbcn/glm-5.3-flash'."""
    if not route_id or "/" not in route_id:
        return None
    return route_id.split("/", 1)[0]


def is_cx(route_id: str) -> bool:
    return prefix(route_id) == "cx"


def litellm_model(route_id: str) -> str:
    """LiteLLM model string for an InferHub route.

    cx/ routes go through the native Responses API ('openai/responses/...'):
    on Chat Completions InferHub turns the system prompt into a developer
    message and forces the upstream instructions to a stock string, so the
    seat's system prompt would not reach the model. In responses mode LiteLLM
    sends the system prompt as `instructions`, which cx keeps as sent.
    """
    if is_cx(route_id) or _prefers_responses(route_id):
        return f"openai/responses/{route_id}"
    return f"openai/{route_id}"


def _prefers_responses(route_id: str) -> bool:
    """IRE's frontier list marks routes with preferred_endpoint=/v1/responses."""
    for x in load_extra_models(include_hidden=True):
        if x.get("id") == route_id and x.get("preferred_endpoint") == "/v1/responses":
            return True
    return False


def opted_in_ids() -> set:
    return {x.strip() for x in os.environ.get("CCL_OPT_IN_MODELS", "").split(",") if x.strip()}


def price_cap_for(x: dict):
    """Max-price cap hook for an extra route: env var wins, then the JSON field."""
    env = x.get("max_price_env")
    if env and os.environ.get(env):
        try:
            return float(os.environ[env])
        except ValueError:
            return None
    return x.get("max_price_per_mtok")


def extra_allowed(x: dict) -> tuple:
    """(allowed, reason) for an extra route under its opt-in and price-cap rules."""
    if x.get("placeholder"):
        return False, "placeholder, exact id pending"
    if x.get("opt_in") and x.get("id") not in opted_in_ids():
        return False, "opt-in: add it to CCL_OPT_IN_MODELS"
    cap = price_cap_for(x)
    worst = x.get("output_cost_per_mtok", x.get("cost_per_mtok"))
    if cap is not None and worst is not None and float(worst) > float(cap):
        return False, f"listed price ${worst}/1M is over your cap ${cap}/1M"
    return True, ""


def load_extra_models(include_hidden: bool = False) -> list:
    """Extra routes. Opt-in routes not opted in on this machine are left out
    unless include_hidden is set (used only for display/debug)."""
    if not EXTRA_MODELS_PATH.is_file():
        return []
    models = json.loads(EXTRA_MODELS_PATH.read_text(encoding="utf-8")).get("models") or []
    if include_hidden:
        return models
    return [m for m in models if not (m.get("opt_in") and m.get("id") not in opted_in_ids())]


LISTS = ("top20", "frontier")
LIST_LABELS = {"top20": "IRE Top 20", "frontier": "IRE frontier list"}


def catalog(bundle: dict, which: str = "top20") -> list:
    """Pickable routes from one list.

    which="top20": IRE Top 20 (first route of each family) + extras.
    which="frontier": IRE frontier list, one row per route (empty if IRE has none).
    Each item: {id, name, rank, eligible, cost_per_mtok, cheap, placeholder, note, list}
    """
    cap = float(bundle["price_policy"]["max_cost_per_mtok"])
    out, seen = [], set()
    if which == "frontier":
        for m in bundle.get("frontier") or []:
            rid = m.get("route")
            if not rid or rid in seen:
                continue
            seen.add(rid)
            cost = m.get("cost_per_mtok")
            out.append({"id": rid, "name": m.get("name") or rid, "rank": m.get("rank"),
                        "eligible": bool(m.get("eligible")), "cost_per_mtok": cost,
                        "price_in": m.get("price_in"), "price_out": m.get("price_out"),
                        "cheap": cost is not None and cost < cap, "placeholder": False,
                        "extra": False, "opt_in": False, "note": m.get("health") or "",
                        "list": "frontier"})
        return out
    for m in bundle.get("top20") or []:
        rid = m["ids"][0]
        cost = m.get("cost_per_mtok")
        out.append({"id": rid, "name": m["name"], "rank": m["rank"], "eligible": bool(m.get("eligible")),
                    "cost_per_mtok": cost, "cheap": cost is not None and cost < cap,
                    "placeholder": False, "extra": False, "opt_in": False, "note": "", "list": "top20"})
        seen.add(rid)
    for x in load_extra_models():
        if x.get("id") in seen:
            continue
        ok, why = extra_allowed(x)
        out.append({"id": x["id"], "name": x.get("name", x["id"]), "rank": None,
                    "eligible": ok, "cost_per_mtok": x.get("cost_per_mtok"),
                    "output_cost_per_mtok": x.get("output_cost_per_mtok"),
                    # opted-in extras are judged by their own cap hook, not the IRE cap
                    "cheap": ok, "extra": True, "opt_in": bool(x.get("opt_in")),
                    "placeholder": bool(x.get("placeholder")), "note": why or x.get("price_note", ""),
                    "list": "top20"})
    return out


def _route_index(bundle: dict) -> dict:
    """Map every route id IRE lists (all aliases of a family) to its row."""
    idx = {}
    for m in bundle.get("top20") or []:
        for rid in m["ids"]:
            idx.setdefault(rid, m)
    for m in bundle.get("frontier") or []:
        if m.get("route"):
            idx.setdefault(m["route"], {"eligible": bool(m.get("eligible")), "frontier": True,
                                        "cost_per_mtok": m.get("cost_per_mtok"), "name": m.get("name")})
    for x in load_extra_models():
        idx.setdefault(x["id"], {"eligible": extra_allowed(x)[0], "extra": True,
                                 "cost_per_mtok": x.get("cost_per_mtok"), "name": x.get("name")})
    return idx


def _cap_hook_problem(rid: str):
    """An extras entry's own max-price hook (e.g. CCL_CX_SOL_MAX_PRICE) applies
    wherever the route was listed. None when there is no hook or it allows it."""
    for x in load_extra_models(include_hidden=True):
        if x.get("id") == rid:
            cap = price_cap_for(x)
            worst = x.get("output_cost_per_mtok", x.get("cost_per_mtok"))
            if cap is not None and worst is not None and float(worst) > float(cap):
                return f"listed price ${worst}/1M is over your cap ${cap}/1M"
    return None


def rung_ok(bundle: dict, rid: str) -> bool:
    """Eligible in IRE and under the price cap. Unknown routes are refused."""
    cap = float(bundle["price_policy"]["max_cost_per_mtok"])
    m = _route_index(bundle).get(rid)
    if not m or not m.get("eligible") or _cap_hook_problem(rid):
        return False
    if m.get("extra"):
        return True  # opted in and inside its own price-cap hook
    c = m.get("cost_per_mtok")
    return c is not None and float(c) < cap


def default_ladder(bundle: dict, role: str, primary: str, blocked_prefixes=()) -> list:
    """Default ladder for a seat.

    Start from IRE's fallback picks (or the built-in chain for the role) and
    drop the primary itself, anything IRE no longer lists as eligible and
    under the cap, and any rung on a blocked vendor prefix. Each dropped rung
    is replaced, where possible, by the next eligible Top 20 route in rank
    order (first route of each family). The ladder never grows past the base
    chain's length or 3 rungs, so the stock chains stay as they are.
    """
    blocked = {p for p in blocked_prefixes if p}
    base = list(((bundle.get("ladders") or {}).get(role) or {}).get("fallbacks") or [])
    want = min(len(base), MAX_RUNGS) if base else MAX_RUNGS
    out = []

    def usable(rid):
        return (rid and rid != primary and rid not in out and prefix(rid) not in blocked
                and rung_ok(bundle, rid))

    for rid in base:
        if len(out) < want and usable(rid):
            out.append(rid)
    for m in bundle.get("top20") or []:
        if len(out) >= want:
            break
        if usable(m["ids"][0]):
            out.append(m["ids"][0])
    return out[:want]


def prune_for_other_seat(ladder: list, other_prefixes) -> tuple:
    """Drop rungs whose vendor is used by the other seat. Returns (kept, dropped)."""
    other = {p for p in other_prefixes if p}
    kept = [r for r in ladder if prefix(r) not in other]
    dropped = [r for r in ladder if prefix(r) in other]
    return kept, dropped


def validate_picks(bundle: dict, primary: str, picks: list, blocked_prefixes=()) -> list:
    """Hard problems with a hand-picked ladder (empty = fine).

    Hand picks are Alex's call: a gated or over-cap route, or one that shares a
    vendor with the other seat, is allowed and only warned about (see
    pick_warnings). The vendor-disjoint rule applies to defaults only.
    """
    problems = []
    if len(picks) > MAX_RUNGS:
        problems.append(f"at most {MAX_RUNGS} fallbacks")
    if len(set(picks)) != len(picks):
        problems.append("a route appears twice")
    idx = _route_index(bundle)
    for r in picks:
        if r == primary:
            problems.append(f"{r} is the primary itself")
            continue
        m = idx.get(r)
        hook = _cap_hook_problem(r)
        if hook:
            problems.append(f"{r}: {hook}")
        elif m is None:
            hidden = {x["id"]: x for x in load_extra_models(include_hidden=True)}
            if r in hidden:
                problems.append(f"{r}: {extra_allowed(hidden[r])[1]}")
            else:
                problems.append(f"{r} is not in the IRE Top 20, the frontier list or the extras")
        elif m.get("extra") and not m.get("eligible"):
            problems.append(f"{r}: {extra_allowed(next(x for x in load_extra_models() if x['id'] == r))[1]}")
    return problems


def pick_warnings(bundle: dict, picks: list, blocked_prefixes=()) -> list:
    """One line per hand-picked rung that a default ladder would not use."""
    cap = float(bundle["price_policy"]["max_cost_per_mtok"])
    blocked = {p for p in blocked_prefixes if p}
    idx = _route_index(bundle)
    out = []
    for r in picks:
        m = idx.get(r) or {}
        c = m.get("cost_per_mtok")
        if not m.get("extra"):
            if not m.get("eligible"):
                out.append(f"{r} is gated in IRE (not recommendation-eligible)")
            if c is None or float(c) >= cap:
                out.append(f"{r} costs over ${cap:.2f} per 1M (~{c if c is not None else '?'}/1M)")
        if prefix(r) in blocked:
            out.append(f"{r} shares vendor '{prefix(r)}/' with the other seat (kept: you picked it)")
    return out


# --------------------------------------------------------------------------- interactive


def _fmt_cost(c):
    return "   ?  " if c is None else f"{c:6.3f}"


def format_row(i: int, c: dict, cap: float, blocked=()) -> str:
    """One picker row: number, route, price per 1M, name, flags. Rows at or over
    the cap are marked 'OVER $0.10'."""
    flags = []
    over = c.get("cost_per_mtok") is None or float(c["cost_per_mtok"]) >= cap
    if c.get("extra"):
        flags.append("opt-in extra, not from IRE" if c["eligible"] else f"not pickable: {c['note']}")
        if c.get("output_cost_per_mtok") is not None:
            flags.append(f"out ~{c['output_cost_per_mtok']}/1M")
        over = False if c.get("cost_per_mtok") is not None and float(c["cost_per_mtok"]) < cap else over
    elif not c["eligible"]:
        flags.append("gated")
    if c.get("list") == "frontier" and c.get("price_out") is not None:
        flags.append(f"in/out {c.get('price_in')}/{c.get('price_out')}")
    if prefix(c["id"]) in set(blocked):
        flags.append("other seat's vendor")
    if is_cx(c["id"]):
        flags.append("cx: Responses mode")
    mark = f"OVER ${cap:.2f}" if over else ""
    return (f"  {i:2d}. {c['id']:<40} ~{_fmt_cost(c['cost_per_mtok'])}/1M {mark:<10} {c['name']}"
            + (f"  [{'; '.join(flags)}]" if flags else ""))


def _parse_choice(ans: str, cands: list) -> list | None:
    """'3 1' -> ids by number; route ids are accepted as typed. None = junk."""
    out = []
    for tok in ans.replace(",", " ").split():
        if tok.isdigit():
            n = int(tok)
            if not 1 <= n <= len(cands):
                return None
            out.append(cands[n - 1]["id"])
        elif "/" in tok:
            out.append(tok)
        else:
            return None
    return out


def _show_list(p, bundle, which, exclude, blocked, cap):
    cands = [c for c in catalog(bundle, which) if c["id"] not in exclude]
    p(f"-- {LIST_LABELS[which]} (price is per 1M tokens; 't' = Top 20, 'f' = frontier list) --")
    if not cands:
        p("  (empty: IRE has no frontier list on this machine yet)" if which == "frontier" else "  (empty)")
    for i, c in enumerate(cands, 1):
        p(format_row(i, c, cap, blocked))
    return cands


def prompt_ladder(bundle: dict, role: str, primary: str, blocked_prefixes=(), *,
                  inp=input, out=sys.stderr, allow_shared: bool = False, which: str = "top20") -> dict:
    """Show the default ladder and let the operator accept or replace it.

    Returns {"fallbacks": [...], "source": "default"|"picked"|"none"}.
    The vendor-disjoint rule shapes the default only; hand picks are kept
    (with a one-line warning) even when they share a vendor with the other seat.
    """
    blocked = () if allow_shared else tuple(blocked_prefixes)
    dflt = default_ladder(bundle, role, primary, blocked)
    cap = float(bundle["price_policy"]["max_cost_per_mtok"])

    def p(s=""):
        print(s, file=out, flush=True)

    p()
    p(f"{role.upper()} seat: {primary}")
    if is_cx(primary):
        p("  note: cx/ route. It is seated in Responses API mode so your system prompt arrives as")
        p("        'instructions'. Over Chat Completions cx would replace it with a stock prompt.")
    src = (bundle.get("source") or {}).get("kind", "?")
    rt = bundle.get("retry") or {}
    n, cd = rt.get("retries", 3), rt.get("cooldown_seconds", 180)
    p(f"Default fallback ladder (IRE source: {src}; cap ${cap:g}/1M):")
    p(f"  each model gets {n} {'retry' if n == 1 else 'retries'}, then the next rung; a model that fails is "
      f"benched for {cd:g} s, then tried again")
    if dflt:
        for i, r in enumerate(dflt, 1):
            p(f"  {i}. {r}" + ("   [cx: Responses mode]" if is_cx(r) else ""))
    else:
        p("  (none available under the current rules)")
    if blocked:
        p(f"  vendors left out of the default because the other seat uses them: {', '.join(sorted(set(blocked)))}")
    p()
    p("Enter = accept, 0 = no fallbacks, t / f = show the Top 20 / frontier list,")
    p("or type up to 3 numbers from the list shown (or route ids), in order.")
    cands = _show_list(p, bundle, which, {primary}, blocked, cap)
    while True:
        try:
            ans = inp(f"{role} fallbacks [{which}]> ").strip()
        except EOFError:
            ans = ""
        if ans == "":
            return {"fallbacks": dflt, "source": "default"}
        if ans == "0":
            return {"fallbacks": [], "source": "none"}
        if ans.lower() in ("t", "f"):
            which = "top20" if ans.lower() == "t" else "frontier"
            cands = _show_list(p, bundle, which, {primary}, blocked, cap)
            continue
        picks = _parse_choice(ans, cands)
        if not picks:
            p("  Type list numbers separated by spaces, e.g. '3 1', t or f to switch lists, or Enter.")
            continue
        probs = validate_picks(bundle, primary, picks)
        if probs:
            for pr in probs:
                p(f"  can't use that: {pr}")
            continue
        for w in pick_warnings(bundle, picks, blocked_prefixes):
            p(f"  warning: {w}")
        return {"fallbacks": picks, "source": "picked"}


def prompt_primary(bundle: dict, role: str, *, default: str | None = None, allow_off: bool = False,
                   inp=input, out=sys.stderr, which: str = "frontier") -> dict | None:
    """Pick a seat primary from either list. Returns the catalog row
    ({"id", "name", ...}), {"id": "", "name": "OFF"} for OFF, or None if cancelled."""
    cap = float(bundle["price_policy"]["max_cost_per_mtok"])

    def p(s=""):
        print(s, file=out, flush=True)

    p()
    p(f"Choose the {role.upper()} model. t / f switch between the Top 20 and the frontier list."
      + (" o = OFF." if allow_off else "") + " q = cancel.")
    cands = _show_list(p, bundle, which, set(), (), cap)
    while True:
        try:
            ans = inp(f"{role} model [{which}]> ").strip()
        except EOFError:
            return None
        low = ans.lower()
        if low == "q":
            return None
        if low in ("t", "f"):
            which = "top20" if low == "t" else "frontier"
            cands = _show_list(p, bundle, which, set(), (), cap)
            continue
        if allow_off and low in ("o", "off"):
            return {"id": "", "name": "OFF"}
        if ans == "" and default:
            ans = default
        picks = _parse_choice(ans, cands)
        if not picks or len(picks) != 1:
            p("  Type one number from the list shown, t or f to switch lists, or q.")
            continue
        rid = picks[0]
        probs = [x for x in validate_picks(bundle, "", [rid]) if "appears twice" not in x]
        if probs:
            p(f"  can't use that: {probs[0]}")
            continue
        for w in pick_warnings(bundle, [rid]):
            p(f"  warning: {w}")
        row = next((c for c in catalog(bundle, "top20") + catalog(bundle, "frontier") if c["id"] == rid),
                   {"id": rid, "name": rid})
        return row


# --------------------------------------------------------------------------- proxy payload


def build_plan(main_primary: str, main_ladder: list, advisor_primary: str | None,
               advisor_ladder: list, api_base: str, retries: int = 3, cooldown: float = 180.0,
               main_names=None, advisor_names=None) -> dict:
    """The JSON the proxy hook applies. Seat aliases are not touched here;
    only the ih/<route> rung deployments and the fallback lists are."""
    main_names = main_names or MAIN_NAMES
    advisor_names = advisor_names or ADVISOR_NAMES
    if not advisor_primary:
        advisor_ladder = list(main_ladder)
    routes = list(dict.fromkeys(list(main_ladder) + list(advisor_ladder)))
    deployments = [{
        "model_name": f"ih/{r}",
        "litellm_params": {"model": litellm_model(r), "api_base": api_base,
                           "api_key": "os.environ/INFERHUB_API_KEY"},
        "model_info": {"description": f"InferHub fallback rung -> {r}"},
    } for r in routes]
    fallbacks = {}
    for n in main_names:
        fallbacks[n] = [f"ih/{r}" for r in main_ladder]
    for n in advisor_names:
        fallbacks[n] = [f"ih/{r}" for r in advisor_ladder]
    return {
        "schema": "ccl-ladder-plan/v1",
        "seats": {"main": {"primary": main_primary, "fallbacks": list(main_ladder)},
                  "advisor": {"primary": advisor_primary, "fallbacks": list(advisor_ladder)}},
        "deployments": deployments,
        "fallbacks": fallbacks,
        "retry_policy": {"RateLimitErrorRetries": retries, "InternalServerErrorRetries": retries,
                         "ServiceUnavailableErrorRetries": retries, "TimeoutErrorRetries": 0,
                         "BadRequestErrorRetries": 0, "AuthenticationErrorRetries": 0},
        # Each model gets `retries` retries (1 + retries attempts) before the request
        # moves to the next rung. The failure that uses up the last retry benches the
        # model for cooldown_time seconds (allowed fails = retries), so later requests
        # skip it until the cooldown ends. Timeouts, bad requests and auth errors are
        # not retried. Same values as inferhub_fallbacks.yaml.
        "cooldown": {"cooldown_time": float(cooldown), "allowed_fails_policy": {
            "RateLimitErrorAllowedFails": retries, "InternalServerErrorAllowedFails": retries,
            "ServiceUnavailableErrorAllowedFails": retries, "BadGatewayErrorAllowedFails": retries,
            "TimeoutErrorAllowedFails": 1, "AuthenticationErrorAllowedFails": 0,
            "NotFoundErrorAllowedFails": 0}},
    }
