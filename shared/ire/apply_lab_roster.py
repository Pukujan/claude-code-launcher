#!/usr/bin/env python3
"""Replace the fetched IRE lists with the local lab roster.

The numbered picker, the frontier list, the utility list, the shell table, and
the Top 20 CSV all come from the roster. Cheap and frontier are the same text
routes in two orders. Utility routes are added once. A route that also sits on
another list is kept on each list. Sub routes are not in the roster.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ire_fetch  # noqa: E402

_FRESH = {
    "price_policy": {"free_below_per_mtok": 0.1},
    "ladders": {},
    "source": "lab-roster",
}


def _atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            stream.write(content)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def _load_json(path: Path):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def _fresh_bundle() -> dict:
    return {
        "price_policy": dict(_FRESH["price_policy"]),
        "ladders": {},
        "source": _FRESH["source"],
    }


def _price(value):
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _name(item: dict, route: str) -> str:
    name = str(item.get("name") or "").replace("|", "/").replace("\n", " ").strip()
    return name or route


def _rows(roster: dict, key: str) -> list:
    raw = roster.get(key, [])
    if not isinstance(raw, list):
        raise ValueError(f"roster {key!r} must be a list")
    out = []
    for item in raw:
        if not isinstance(item, dict) or not item.get("route"):
            raise ValueError(f"roster {key!r} has a row without a route")
        out.append(item)
    return out


def _rank(value, fallback: int) -> int:
    try:
        n = int(value)
    except (TypeError, ValueError):
        return fallback
    return n if n > 0 else fallback


def _picker_row(rank: int, item: dict) -> dict:
    route = str(item["route"])
    price_in = _price(item.get("price_in"))
    return {
        "rank": rank,
        "name": _name(item, route),
        "vendor": item.get("vendor") or "",
        "eligible": True,
        "gate_reasons": [],
        "cost_per_mtok": price_in,
        "price_in": price_in,
        "price_out": _price(item.get("price_out")),
        "tps": _price(item.get("tps")),
        "ids": [route],
    }


def _list_row(item: dict, rank: int) -> dict:
    route = str(item["route"])
    price_in = _price(item.get("price_in"))
    return {
        "rank": rank,
        "name": _name(item, route),
        "vendor": item.get("vendor") or "",
        "route": route,
        "best_route": True,
        "eligible": True,
        "health": "lab-roster",
        "cost_per_mtok": price_in,
        "price_in": price_in,
        "price_out": _price(item.get("price_out")),
        "tps": _price(item.get("tps")),
    }


def _load_bundle(path: Path) -> dict:
    loaded = _load_json(path) if path.is_file() else None
    if loaded is None:
        return _fresh_bundle()
    loaded.setdefault("price_policy", dict(_FRESH["price_policy"]))
    loaded.setdefault("ladders", {})
    return loaded


def apply(roster_path: Path, bundle_path: Path, table_path: Path, csv_path: Path) -> tuple:
    """Write the roster into the bundle, the picker table, and the Top 20 CSV.

    Returns (picker count, frontier count, utility count).
    """
    roster = _load_json(roster_path)
    if roster is None:
        raise ValueError(f"roster is not a JSON object: {roster_path}")
    cheap = _rows(roster, "cheap")
    frontier = _rows(roster, "frontier")
    utility = _rows(roster, "utility")

    bundle = _load_bundle(bundle_path)
    top = []
    seen = set()
    for item in cheap + utility:
        route = str(item["route"])
        if route in seen:
            continue
        seen.add(route)
        top.append(_picker_row(len(top) + 1, item))
    bundle["lab_roster"] = True
    bundle["top20"] = top
    bundle["frontier"] = [
        _list_row(item, _rank(item.get("frontier_rank"), i))
        for i, item in enumerate(frontier, 1)
    ]
    bundle["utility"] = [
        _list_row(item, _rank(item.get("utility_rank"), i))
        for i, item in enumerate(utility, 1)
    ]

    _atomic_write(bundle_path, json.dumps(bundle, indent=2, ensure_ascii=False) + "\n")
    _atomic_write(table_path, ire_fetch.shell_table(bundle))
    _atomic_write(csv_path, ire_fetch.top20_csv(bundle))
    return len(top), len(bundle["frontier"]), len(bundle["utility"])


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--roster", required=True, type=Path)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--table", required=True, type=Path)
    parser.add_argument("--top20-csv", required=True, type=Path)
    args = parser.parse_args(argv)
    if not args.roster.is_file():
        print(f"lab roster not found: {args.roster}", file=sys.stderr)
        return 1
    try:
        picker, text, utility = apply(args.roster, args.bundle, args.table, args.top20_csv)
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
        print(f"lab roster not applied: {exc}", file=sys.stderr)
        return 1
    print(
        f"[ire] lab roster: {picker} routes in the picker "
        f"({text} text on cheap and frontier, {utility} utility). sub left out",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
