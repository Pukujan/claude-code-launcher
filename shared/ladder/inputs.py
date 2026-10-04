"""Where the ladder picker gets its defaults. One function: load_inputs().

It returns a dict shaped like this, from the best source available:

  {
    "source": {"kind": "ire" | "builtin", "detail": "..."},
    "price_policy": {"max_cost_per_mtok": 0.10},
    "top20": [{"rank", "name", "eligible", "cost_per_mtok", "ids": [...]}, ...],
    "ladders": {"main": {"primary", "fallbacks"}, "advisor": {...}},
    "retry": {"retries": 1, "cooldown_seconds": 180},
  }

Sources, in order:
  1. a bundle file produced by the IRE module (shared/ire, issue #4), if one
     is passed in or the module is present and returns one;
  2. otherwise the Top 20 table the launchers already use
     (shared/litellm/config/top20.csv when synced, else top20-builtin.csv)
     plus the fixed chains below.

The fixed chains are the defaults when IRE is unavailable (Alex, 2026-10-03).
"""
from __future__ import annotations

import csv
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SHARED = HERE.parent
CONFIG = SHARED / "litellm" / "config"

FIXED_LADDERS = {
    "main": {"primary": "cb/deepseek-v4.1-flash", "fallbacks": ["ali/qwen3.8-flash", "cbcn/deepseek-v4-flash"]},
    "advisor": {"primary": "cbcn/glm-5.3-flash", "fallbacks": ["cbcn/minimax-m3"]},
}
FIXED_RETRY = {"retries": 1, "cooldown_seconds": 180}
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
                        "ladders": json.loads(json.dumps(FIXED_LADDERS)), "retry": dict(FIXED_RETRY)}
    raise FileNotFoundError("no Top 20 table under shared/litellm/config")


def _usable(b) -> bool:
    try:
        return bool(b.get("top20")) and float(b["price_policy"]["max_cost_per_mtok"]) > 0
    except (AttributeError, KeyError, TypeError, ValueError):
        return False


def _from_ire_module():
    """Ask the IRE module (if installed) for its bundle. Any failure -> None."""
    ire = SHARED / "ire"
    if not (ire / "ire_fetch.py").is_file():
        return None
    try:
        sys.path.insert(0, str(ire))
        import ire_fetch  # type: ignore
        return ire_fetch.get_bundle()
    except Exception as e:  # never block a launch on IRE
        print(f"[ladder] IRE module unavailable ({type(e).__name__}); using built-in chains", file=sys.stderr)
        return None


def load_inputs(bundle_path: Path | None = None, use_ire: bool = True) -> dict:
    b = None
    if bundle_path and Path(bundle_path).is_file():
        try:
            b = json.loads(Path(bundle_path).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            b = None
    if b is None and use_ire:
        b = _from_ire_module()
    if _usable(b):
        b.setdefault("ladders", json.loads(json.dumps(FIXED_LADDERS)))
        b.setdefault("retry", dict(FIXED_RETRY))
        src = b.get("source") or {}
        b["source"] = {"kind": "ire", "detail": f"{src.get('kind', '?')}: {src.get('detail', '')}"}
        return b
    return builtin_inputs()
