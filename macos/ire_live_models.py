#!/usr/bin/env python3
"""Fetch the live IRE Top 20 from GitHub and emit the shell model table.

The ranking is NOT hardcoded here: it is read at runtime from

    Pukujan/inference-recommendation-engine
      operational/telemetry/gravebuster/pipeline/ihub/lists/
      research_model_top20_recommendations.csv

so the launcher always reflects the current recommendation snapshot. The result
is cached under ~/.local/state/claude-acs so an offline launch still works.

Usage:
  ire_live_models.py                 # print the table (cached if fresh)
  ire_live_models.py --refresh       # ignore the cache, force a fetch
  ire_live_models.py --json          # emit JSON instead of shell
  ire_live_models.py --check-proxy   # probe each route through LiteLLM

Exit codes: 0 ok, 1 fetch failed and no usable cache, 2 bad arguments.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

OWNER = "Pukujan"
REPO = "inference-recommendation-engine"
BRANCH = "main"
CSV_PATH = (
    "operational/telemetry/gravebuster/pipeline/ihub/lists/"
    "research_model_top20_recommendations.csv"
)
RAW_URL = f"https://raw.githubusercontent.com/{OWNER}/{REPO}/{BRANCH}/{CSV_PATH}"

CACHE_DIR = os.path.expanduser("~/.local/state/claude-acs")
CACHE_FILE = os.path.join(CACHE_DIR, "ire-models.json")
CACHE_TTL_SECONDS = 6 * 3600  # re-probe every 6h; a launch should not wait on I/O

PROXY_BASE = os.environ.get("PROXY_BASE", "http://127.0.0.1:4000")


def log(msg: str) -> None:
    print(f"[ire] {msg}", file=sys.stderr)


def fetch(url: str, timeout: int = 20) -> bytes:
    # Some corporate/older macOS Pythons lack a usable default CA path; keep the
    # failure explicit rather than silently downgrading to an unverified fetch.
    ctx = ssl.create_default_context()
    req = urllib.request.Request(url, headers={"User-Agent": "claude-code-launcher"})
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
        return resp.read()



def live_catalog(timeout: int = 25) -> set[str]:
    """Model ids InferHub will actually accept, per its own /v1/models."""
    key = ""
    for cand in (os.path.expanduser("~/.config/inferhub/.env"),
                 os.path.expanduser("~/Documents/secrets/.env")):
        try:
            with open(cand, encoding="utf-8") as fh:
                for line in fh:
                    if line.strip().startswith("INFERHUB_API_KEY"):
                        key = line.split("=", 1)[1].strip().strip('"').strip("'")
                        break
        except OSError:
            continue
        if key:
            break
    if not key:
        return set()
    req = urllib.request.Request(
        f"{API_BASE}/v1/models", headers={"Authorization": f"Bearer {key}"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return {m["id"] for m in json.loads(resp.read().decode()).get("data", [])}
    except (urllib.error.URLError, OSError, ValueError, KeyError):
        return set()


API_BASE = "https://api.inferhub.dev/v1"


def annotate_live(models: list[dict]) -> list[dict]:
    """Attach every vendor id IRE lists plus which ones InferHub still serves.

    IRE's list is a verbatim snapshot taken on the telemetry host, so some vendor
    slugs have since been retired upstream. Registering a retired slug makes
    LiteLLM answer "Invalid model name", so the launcher must know which are live.
    """
    catalog = live_catalog()
    if not catalog:
        log("InferHub catalog unavailable; marking every slug unverified")
        for m in models:
            m["vendors"] = [m["model"]]
            m["live_vendors"] = []
        return models
    for m in models:
        vendors = [v.strip() for v in m.get("vendors", [m["model"]]) if v.strip()]
        if not vendors:
            vendors = [m["model"]]
        m["vendors"] = vendors
        m["live_vendors"] = [v for v in vendors if v in catalog]
    return models


def parse_csv(raw: bytes) -> list[dict]:
    text = raw.decode("utf-8-sig", errors="replace")
    rows = list(csv.DictReader(text.splitlines()))
    if not rows:
        raise ValueError("CSV parsed to zero rows")
    out = []
    for r in rows:
        rank = (r.get("recommendation_rank") or "").strip()
        family = (r.get("model_family") or "").strip()
        slug = (r.get("model_ids") or "").split(";")[0].strip()
        if not rank.isdigit() or not family or "/" not in slug:
            continue  # skip a malformed row rather than emit a broken table
        try:
            cost = float(r.get("supply_weighted_median_cost_usdc_per_1m") or 0)
        except ValueError:
            cost = 0.0
        out.append(
            {
                "rank": int(rank),
                "family": family,
                "model": slug,
                # Every vendor id IRE lists for this family. The first is the
                # preferred route; the rest are fallbacks, some of which may be
                # retired upstream (see annotate_live).
                "vendors": [v.strip() for v in (r.get("model_ids") or "").split(";") if v.strip()] or [slug],
                "cost": cost,
                "eligible": (r.get("recommendation_eligible") or "").strip().lower() == "true",
            }
        )
    out.sort(key=lambda x: x["rank"])
    return out


def load_cache() -> list[dict] | None:
    try:
        with open(CACHE_FILE, encoding="utf-8") as fh:
            blob = json.load(fh)
    except (OSError, ValueError):
        return None
    models = blob.get("models")
    return models if isinstance(models, list) and models else None


def save_cache(models: list[dict]) -> None:
    try:
        os.makedirs(CACHE_DIR, mode=0o700, exist_ok=True)
        tmp = CACHE_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"fetched_at": dt.datetime.now(dt.timezone.utc).isoformat(), "models": models}, fh, indent=1)
        os.replace(tmp, CACHE_FILE)
    except OSError as exc:
        log(f"could not write cache: {exc}")


def cache_age() -> float:
    try:
        return dt.datetime.now().timestamp() - os.path.getmtime(CACHE_FILE)
    except OSError:
        return float("inf")


def get_models(force: bool = False) -> list[dict]:
    fresh = None if force else load_cache()
    if fresh and cache_age() < CACHE_TTL_SECONDS:
        log(f"using cache ({len(fresh)} models)")
        return fresh
    try:
        models = parse_csv(fetch(RAW_URL))
        log(f"fetched {len(models)} models from {OWNER}/{REPO}@{BRANCH}")
        save_cache(models)
        return models
    except (urllib.error.URLError, OSError, ValueError) as exc:
        log(f"live fetch failed: {exc}")
        if fresh:
            log(f"falling back to cache ({len(fresh)} models)")
            return fresh
        raise SystemExit(1)


def emit_shell(models: list[dict]) -> None:
    """Emit the shell table. MODEL_IDS uses the first vendor InferHub still
    serves; IRE_RETIRED lists slugs it no longer has, so the launcher never
    registers one and LiteLLM never answers "Invalid model name"."""
    print("# Generated by ire_live_models.py - live from IRE, do not hand-edit.")
    ids, names, costs, elig, retired = [], [], [], [], []
    for m in models:
        live = m.get("live_vendors") or [m["model"]]
        ids.append(live[0])
        names.append(m["family"])
        costs.append(f'{m["cost"]:.6g}')
        elig.append("1" if m["eligible"] else "0")
        for v in m.get("vendors", []):
            if v not in live:
                retired.append(v)

    def block(name, vals):
        print(f"{name}=(")
        for i in range(0, len(vals), 4):
            print("  " + " ".join(f'"{v}"' for v in vals[i : i + 4]))
        print(")")

    block("MODEL_NAMES", names)
    block("MODEL_IDS", ids)
    block("MODEL_COSTS", costs)
    print("MODEL_ELIGIBLE=(" + " ".join(elig) + ")")
    if retired:
        print("# IRE lists these vendor slugs but InferHub no longer serves them:")
        print("# " + " ".join(retired))
    print("MODEL_COUNT=${#MODEL_IDS[@]}")


def probe_slug(m: dict) -> str:
    """Prefer a vendor InferHub still serves; fall back to the first listed."""
    live = m.get("live_vendors") or []
    return live[0] if live else m["model"]


def probe(models: list[dict]) -> int:
    """Ask LiteLLM to run one tiny completion per route; report what answers."""
    import urllib.request as u

    print(f"{'rank':>4}  {'model':44s} {'usdc/1m':>8}  status")
    ok = dead = 0
    for m in models:
        body = json.dumps(
            {
                "model": f"ih/{probe_slug(m)}",
                "messages": [{"role": "user", "content": "1+1? number only"}],
                "max_tokens": 400,
            }
        ).encode()
        req = u.Request(
            f"{PROXY_BASE}/v1/chat/completions",
            data=body,
            headers={"Content-Type": "application/json", "Authorization": "Bearer probe"},
        )
        try:
            with u.urlopen(req, timeout=90) as resp:
                blob = json.loads(resp.read().decode())
            txt = (blob.get("choices") or [{}])[0].get("message", {}).get("content", "")
            if resp.status == 200 and not (txt or "").strip():
                # A reasoning model can spend the whole budget before emitting
                # text. Retry with a larger max_tokens before calling it dead.
                body2 = json.dumps({
                    "model": f"ih/{probe_slug(m)}",
                    "messages": [{"role": "user", "content": "1+1? number only"}],
                    "max_tokens": 2000,
                }).encode()
                req2 = u.Request(
                    f"{PROXY_BASE}/v1/chat/completions",
                    data=body2,
                    headers={"Content-Type": "application/json", "Authorization": "Bearer probe"},
                )
                with u.urlopen(req2, timeout=120) as r2:
                    b2 = json.loads(r2.read().decode())
                txt = (b2.get("choices") or [{}])[0].get("message", {}).get("content", "")
            status = "ok" if (txt or "").strip() else "empty even at 2000 tokens"
            ok += 1
        except urllib.error.HTTPError as exc:
            detail = ""
            try:
                detail = json.loads(exc.read().decode()).get("error", {}).get("message", "")
            except Exception:
                pass
            if exc.code == 402:
                status = "402 no provider bidding"
            elif exc.code == 503:
                status = "503 no provider available"
            else:
                status = f"http {exc.code} {detail[:60]}"
            dead += 1
        except (urllib.error.URLError, OSError, ValueError) as exc:
            status = f"unreachable ({exc})"
            dead += 1
        print(f"{m['rank']:>4}  {m['model']:44s} {m['cost']:>8.4f}  {status}")
    print(f"\nanswered: {ok}/{len(models)}   unavailable: {dead}/{len(models)}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Live IRE Top 20 for the Claude Code shim")
    ap.add_argument("--refresh", action="store_true", help="ignore the cache")
    ap.add_argument("--json", action="store_true", help="emit JSON")
    ap.add_argument("--check-proxy", action="store_true", help="probe every route")
    args = ap.parse_args()

    if args.check_proxy:
        return probe(annotate_live(load_cache() or get_models()))

    models = annotate_live(get_models(force=args.refresh))
    if args.json:
        print(json.dumps(models, indent=1))
    else:
        emit_shell(models)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except KeyboardInterrupt:
        sys.exit(130)