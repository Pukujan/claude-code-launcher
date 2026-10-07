#!/usr/bin/env python3
"""Refresh launcher fallback tables from a live ``ire_fetch.py`` bundle."""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import re
import sys
from pathlib import Path


def _quote(value: str) -> str:
    return value.replace('"', '`"')


def _route_ids(row: dict) -> list[str]:
    ids = [str(x).strip() for x in row.get("ids", []) if str(x).strip()]
    if not ids or any("/" not in x or x.startswith("ih/") for x in ids):
        raise ValueError(f"rank {row.get('rank')} has invalid InferHub route ids: {ids!r}")
    return ids


def _as_csv(rows: list[dict]) -> str:
    from io import StringIO

    out = StringIO(newline="")
    fields = ["recommendation_rank", "model_family", "recommendation_eligible",
              "supply_weighted_median_cost_usdc_per_1m", "best_route_min_ask_in_usdc_per_1m",
              "best_route_min_ask_out_usdc_per_1m", "model_ids"]
    writer = csv.DictWriter(out, fieldnames=fields, lineterminator="\n")
    writer.writeheader()
    for row in rows:
        ids = _route_ids(row)
        writer.writerow({
            "recommendation_rank": row["rank"],
            "model_family": row["name"],
            "recommendation_eligible": str(bool(row.get("eligible"))).lower(),
            "supply_weighted_median_cost_usdc_per_1m": row.get("blend_per_mtok") or "",
            "best_route_min_ask_in_usdc_per_1m": row.get("price_in") or "",
            "best_route_min_ask_out_usdc_per_1m": row.get("price_out") or "",
            "model_ids": "; ".join(ids),
        })
    return out.getvalue()


def _model_rows(rows: list[dict]) -> str:
    out = []
    for row in rows:
        ids = _route_ids(row)
        eligible = str(bool(row.get("eligible"))).lower()
        out.append(
            f'  @{{ Rank = {row["rank"]}; Name = "{_quote(row["name"])}"; '
            f'Id = "{_quote(ids[0])}"; Eligible = ${eligible}; '
            f'Cost = "{row.get("price_in") or ""}"; CostOut = "{row.get("price_out") or ""}" }}'
        )
    return "$Models = @(\n" + "\n".join(out) + "\n)"


def _mac_rows(rows: list[dict]) -> str:
    lines = []
    for row in rows:
        ids = _route_ids(row)
        lines.append("|".join((str(row["rank"]), row["name"], ids[0],
                               str(bool(row.get("eligible"))).lower(),
                               str(row.get("price_in") or ""), str(row.get("price_out") or ""))))
    return "MODELS='" + "\n".join(lines) + "'"


def _frontier_rows(rows: list[dict]) -> str:
    # The Windows built-in list carries one selected route for each of the first
    # 20 IRE frontier families. Live pickers keep their full per-route list.
    chosen = [r for r in rows if r.get("best_route") and int(r.get("rank") or 0) <= 20]
    chosen.sort(key=lambda r: (int(r["rank"]), str(r.get("route"))))
    if not chosen:
        raise ValueError("IRE bundle has no best routes in the first 20 frontier ranks")
    out = []
    for row in chosen:
        route = str(row.get("route") or "")
        if "/" not in route:
            raise ValueError(f"invalid frontier route: {route!r}")
        name = str(row.get("name") or route)
        ctx = row.get("context_window")
        if ctx:
            name += f" ({int(ctx) // 1000}K ctx)"
        price = f'{row.get("price_in") or "?"} in/{row.get("price_out") or "?"} out'
        out.append(
            f'  @{{ Rank = "F{int(row["rank"])}"; Name = "{_quote(name)}"; '
            f'Id = "{_quote(route)}"; Eligible = ${str(bool(row.get("eligible"))).lower()}; '
            f'Cost = "{price}" }}'
        )
    return "$FrontierModels = @(\n" + "\n".join(out) + "\n)"


def _replace(text: str, pattern: str, replacement: str, label: str) -> str:
    updated, count = re.subn(pattern, lambda _: replacement, text, count=1, flags=re.M | re.S)
    if count != 1:
        raise ValueError(f"could not find exactly one {label} block")
    return updated


def _replace_line(text: str, pattern: str, replacement: str, label: str) -> str:
    updated, count = re.subn(pattern, lambda _: replacement, text, count=1, flags=re.M)
    if count != 1:
        raise ValueError(f"could not find exactly one {label} line")
    return updated


def sync(bundle: dict, root: Path, require_live: bool = False, source_sha: str = "unknown",
         source_date: str | None = None) -> None:
    if require_live and bundle.get("source") != "live":
        raise ValueError(f"refusing to refresh from {bundle.get('source')!r} IRE data")
    top20 = sorted(bundle.get("top20") or [], key=lambda r: int(r.get("rank") or 0))
    if len(top20) != 20 or [int(r.get("rank") or 0) for r in top20] != list(range(1, 21)):
        raise ValueError("expected exactly 20 ranked IRE Top 20 rows")
    frontier = bundle.get("frontier") or []
    if not frontier:
        raise ValueError("refusing to erase the Windows frontier fallback from an empty list")
    for row in top20:
        _route_ids(row)
        if not row.get("name"):
            raise ValueError(f"rank {row['rank']} has no model family")

    frontier_best = [r for r in frontier if r.get("best_route") and int(r.get("rank") or 0) <= 20]
    frontier_best.sort(key=lambda r: (int(r["rank"]), str(r.get("route"))))
    route_map = {
        "ire_main_sha": source_sha,
        "top20": [{"rank": r["rank"], "name": r["name"], "id": _route_ids(r)[0],
                   "eligible": bool(r.get("eligible")), "price_in": r.get("price_in"),
                   "price_out": r.get("price_out")} for r in top20],
        "frontier": [{"rank": r["rank"], "name": r["name"], "id": r["route"],
                      "eligible": bool(r.get("eligible")), "price_in": r.get("price_in"),
                      "price_out": r.get("price_out"), "context_window": r.get("context_window")}
                     for r in frontier_best],
    }
    if not route_map["frontier"]:
        raise ValueError("IRE bundle has no best frontier routes in the first 20 ranks")
    fixture = root / "tests/fixtures/ire/top20-frontier-route-map.json"
    fixture.write_text(json.dumps(route_map, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    config = root / "shared/litellm/config"
    (config / "top20-builtin.csv").write_text(_as_csv(top20), encoding="utf-8", newline="")

    defaults_path = root / "shared/ire/defaults.json"
    defaults = json.loads(defaults_path.read_text(encoding="utf-8"))
    defaults["_as_of"] = source_date or (bundle.get("freshness") or {}).get("as_of") or dt.datetime.now(
        dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    defaults["_note"] = (
        "Built-in defaults used when GitHub is unavailable and no cache exists. "
        "Top 20 matches shared/litellm/config/top20-builtin.csv and both launchers. "
        "Each ids list is ordered with IRE's selected best provider route first. "
        "The shown price is that route's cheapest listed ask; fixed seat ladders remain unchanged."
    )
    defaults["top20"] = [{
        "rank": row["rank"], "name": row["name"], "vendor": row.get("vendor", ""),
        "eligible": bool(row.get("eligible")), "gate_reasons": row.get("gate_reasons") or [],
        "cost_per_mtok": row.get("cost_per_mtok"), "price_in": row.get("price_in"),
        "price_out": row.get("price_out"), "blend_per_mtok": row.get("blend_per_mtok"),
        "ids": _route_ids(row),
    } for row in top20]
    defaults_path.write_text(json.dumps(defaults, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    windows_path = root / "windows/launch-claude-inferhub.ps1"
    windows = windows_path.read_text(encoding="utf-8-sig")
    windows = _replace(windows, r"\$Models = @\(.*?^\)", _model_rows(top20), "Windows Top 20")
    windows = _replace(windows, r"\$FrontierModels = @\(.*?^\)", _frontier_rows(frontier), "Windows frontier")
    windows = _replace_line(windows, r'^\$DefaultModelId = ".*"$',
                            f'$DefaultModelId = "{_quote(_route_ids(top20[0])[0])}"', "Windows default model")
    windows_path.write_text("\ufeff" + windows, encoding="utf-8", newline="")

    mac_path = root / "mac/Launch Claude InferHub.command"
    mac = mac_path.read_text(encoding="utf-8")
    mac = _replace(mac, r"^MODELS='.*?'(?=\n\nMODEL_COUNT=)", _mac_rows(top20), "Mac Top 20")
    mac = _replace_line(mac, r'^DEFAULT_MODEL_ID=".*"$',
                        f'DEFAULT_MODEL_ID="{_route_ids(top20[0])[0]}"', "Mac default model")
    mac_path.write_text(mac, encoding="utf-8", newline="")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True, type=Path, help="JSON output from ire_fetch.py")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--require-live", action="store_true", help="fail unless bundle source is live")
    parser.add_argument("--source-sha", default="unknown", help="IRE main commit for snapshot provenance")
    parser.add_argument("--source-date", help="committer date for the pinned IRE source commit")
    args = parser.parse_args()
    try:
        sync(json.loads(args.bundle.read_text(encoding="utf-8")), args.root,
             args.require_live, args.source_sha, args.source_date)
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print("Refreshed the Top 20 and frontier fallback tables from IRE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
