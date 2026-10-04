"""Where the ladder picker gets its defaults. One function: load_inputs().

It returns a dict shaped like this, from the best source available:

  {
    "source": {"kind": "ire" | "builtin", "detail": "..."},
    "price_policy": {"max_cost_per_mtok": 0.10},
    "top20": [{"rank", "name", "eligible", "cost_per_mtok", "ids": [...]}, ...],
    "ladders": {"main": {"primary", "fallbacks"}, "advisor": {...}},
    "retry": {"retries": 3, "cooldown_seconds": 180},
  }

Sources, in order:
  1. the IRE module's JSON (shared/ire, issue #4; schema in shared/ire/README.md):
     the file passed in, else $CCL_IRE_JSON (both launchers set it at start-up),
     else shared/ire/ire_fetch.py get_recommendations();
  2. otherwise the Top 20 table the launchers already use
     (shared/litellm/config/top20.csv when synced, else top20-builtin.csv)
     plus the fixed chains below.

The fixed chains are the defaults when IRE is unavailable (Alex, 2026-10-03).
"""
from __future__ import annotations

import csv
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SHARED = HERE.parent
CONFIG = SHARED / "litellm" / "config"

FIXED_LADDERS = {
    "main": {"primary": "cb/deepseek-v4.1-flash", "fallbacks": ["ali/qwen3.8-flash", "cbcn/deepseek-v4-flash"]},
    "advisor": {"primary": "cbcn/glm-5.3-flash", "fallbacks": ["cbcn/minimax-m3"]},
}
# Failure policy (Alex, 2026-10-03): each model gets 3 retries, then the request
# moves to the next rung. A model that used up its retries is benched for 180 s,
# then tried again. CCL_RETRIES and CCL_COOLDOWN_S override both on a machine.
FIXED_RETRY = {"retries": 3, "cooldown_seconds": 180}
RETRIES_ENV, COOLDOWN_ENV = "CCL_RETRIES", "CCL_COOLDOWN_S"


def _env_int(name: str, lo: int, hi: int):
    raw = os.environ.get(name, "").strip()
    if not raw:
        return None
    try:
        v = int(raw)
    except ValueError:
        v = None
    if v is None or not lo <= v <= hi:
        print(f"[ladder] ignoring {name}={raw!r} (want a whole number {lo}-{hi})", file=sys.stderr)
        return None
    return v


def retry_settings(base: dict | None = None) -> dict:
    """{retries, cooldown_seconds}: CCL_RETRIES / CCL_COOLDOWN_S win, then base, then 3 / 180."""
    out = dict(FIXED_RETRY)
    for k in out:
        if base and base.get(k) is not None:
            out[k] = int(base[k])
    r = _env_int(RETRIES_ENV, 0, 10)
    c = _env_int(COOLDOWN_ENV, 1, 86400)
    if r is not None:
        out["retries"] = r
    if c is not None:
        out["cooldown_seconds"] = c
    return out
PRICE_CAP = 0.10  # docs/INFERHUB-API-SETUP.md in IRE: under $0.10 per 1M is "effectively free"


def _top20_from_csv(path: Path) -> list:
    rows = []
    with path.open(encoding="utf-8-sig", newline="") as fh:
        for r in csv.DictReader(fh):
            ids = [x.strip() for x in (r.get("model_ids") or "").split(";") if x.strip()]
            rank = r.get("recommendation_rank") or r.get("rank")
            if not ids or not rank:
                continue
            try:
                cost = float(r.get("supply_weighted_median_cost_usdc_per_1m") or "")
            except ValueError:
                cost = None
            rows.append({"rank": int(rank), "name": (r.get("model_family") or "").strip(),
                         "eligible": str(r.get("recommendation_eligible", "true")).strip().lower() == "true",
                         "cost_per_mtok": cost, "ids": ids})
    rows.sort(key=lambda x: x["rank"])
    return rows


def builtin_inputs() -> dict:
    for name in ("top20.csv", "top20-builtin.csv"):
        p = CONFIG / name
        if p.is_file():
            try:
                top = _top20_from_csv(p)
            except (OSError, ValueError):
                continue
            if top:
                return {"source": {"kind": "builtin", "detail": f"{p.name} + fixed chains"},
                        "price_policy": {"max_cost_per_mtok": PRICE_CAP}, "top20": top,
                        "ladders": json.loads(json.dumps(FIXED_LADDERS)), "retry": retry_settings()}
    raise FileNotFoundError("no Top 20 table under shared/litellm/config")


def normalize(raw) -> dict | None:
    """Turn shared/ire's output into the shape above. None if it isn't usable.

    shared/ire gives {source, top20, price_policy{free_below_per_mtok},
    ladders{main: [primary, ...], advisor: [...]}, retries, cooldown_s}.
    """
    if not isinstance(raw, dict) or not raw.get("top20"):
        return None
    pp = raw.get("price_policy") or {}
    cap = pp.get("free_below_per_mtok", pp.get("max_cost_per_mtok"))
    lad = {}
    for role, v in (raw.get("ladders") or {}).items():
        if isinstance(v, list) and v:
            lad[role] = {"primary": v[0], "fallbacks": list(v[1:])}
        elif isinstance(v, dict):
            lad[role] = {"primary": v.get("primary"), "fallbacks": list(v.get("fallbacks") or [])}
    for role, v in FIXED_LADDERS.items():
        lad.setdefault(role, json.loads(json.dumps(v)))
    retry = retry_settings(raw.get("retry") or {"retries": raw.get("retries"),
                                                "cooldown_seconds": raw.get("cooldown_s")})
    src = raw.get("source")
    detail = src if isinstance(src, str) else (src or {}).get("kind", "?")
    out = {"source": {"kind": "ire", "detail": str(detail)},
           "price_policy": {"max_cost_per_mtok": cap},
           "top20": raw["top20"], "frontier": list(raw.get("frontier") or []),
           "ladders": lad, "retry": retry}
    return out if _usable(out) else None


def _usable(b) -> bool:
    try:
        return bool(b.get("top20")) and float(b["price_policy"]["max_cost_per_mtok"]) > 0
    except (AttributeError, KeyError, TypeError, ValueError):
        return False


def _from_ire_module():
    """Ask shared/ire (if present) for its answer. Any failure -> None."""
    ire = SHARED / "ire"
    if not (ire / "ire_fetch.py").is_file():
        return None
    try:
        sys.path.insert(0, str(ire))
        import ire_fetch  # type: ignore
        return ire_fetch.get_recommendations()
    except Exception as e:  # never block a launch on IRE
        print(f"[ladder] IRE module unavailable ({type(e).__name__}); using built-in chains", file=sys.stderr)
        return None


def load_inputs(bundle_path: Path | None = None, use_ire: bool = True) -> dict:
    import os

    raw = None
    if bundle_path is None and use_ire:
        env = os.environ.get("CCL_IRE_JSON") or os.environ.get("CCL_IRE_BUNDLE")
        bundle_path = Path(env) if env else None
    if bundle_path and Path(bundle_path).is_file():
        try:
            raw = json.loads(Path(bundle_path).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raw = None
    if raw is None and use_ire:
        raw = _from_ire_module()
    b = normalize(raw)
    return b if b else builtin_inputs()
