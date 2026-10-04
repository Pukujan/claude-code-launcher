#!/usr/bin/env python3
"""Fetch IRE recommendations for the Claude Code launcher at start-up.

Both launchers (windows/ and mac/) run this file. It reads three things from the
private repo Pukujan/inference-recommendation-engine on main:

  - the Top 20 list (CSV)
  - the price policy line in docs/INFERHUB-API-SETUP.md
    ("below $0.10 USDC per 1 million tokens" counts as effectively free)
  - fallback picks, if IRE ever publishes them (optional JSON, see PICKS_PATH)
  - the frontier list (optional; FRONTIER_JSON_PATH, else FRONTIER_ROUTES_PATH),
    one row per route, under the extra key "frontier" ([] when IRE has none)

and prints one JSON document. The schema is documented in README.md next to
this file and is consumed by the ladder picker (issue #5), so do not add or
rename top-level keys without updating both.

Sources, first one that works wins: live (GitHub) -> cache -> built-in defaults.
Standard library only. Tokens are sent in a request header and never printed,
logged or written to the cache.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULTS_PATH = HERE / "defaults.json"

IRE_REPO = "Pukujan/inference-recommendation-engine"
IRE_REF = "main"
API_BASE = "https://api.github.com"
TOP20_PATH = "operational/telemetry/gravebuster/pipeline/ihub/lists/research_model_top20_recommendations.csv"
POLICY_PATH = "docs/INFERHUB-API-SETUP.md"
# IRE has no fallback-picks file yet (checked main at 9a8fba0 on 2026-10-03).
# If this path appears, its ladders replace the built-in ones.
PICKS_PATH = "operational/recommendations/claude-code-fallbacks.v1.json"

# The frontier list: models above the Top 20's price band, one row per route.
LISTS = "operational/telemetry/gravebuster/pipeline/ihub/lists/"
FRONTIER_JSON_PATH = LISTS + "research_model_frontier_recommendations.json"
FRONTIER_ROUTES_PATH = LISTS + "research_model_frontier_routes.csv"

DEFAULT_TIMEOUT = 5.0
CACHE_NAME = "ire-cache.json"
KEYS = ("source", "top20", "price_policy", "ladders", "retries", "cooldown_s")
# Optional extras: always present in the output, may be empty.
EXTRA_KEYS = ("frontier",)

POLICY_RE = re.compile(
    r"below\s*\**\s*\$\s*([0-9]+(?:\.[0-9]+)?)\s*(?:USDC|USD)?\s*per\s*1\s*(?:million|M)\s*tokens",
    re.IGNORECASE,
)


class FetchError(Exception):
    """GitHub could not be reached, refused the request, or sent something unusable."""


def log(msg: str) -> None:
    print(f"[ire] {msg}", file=sys.stderr, flush=True)


# ---------------------------------------------------------------- locations


def cache_dir() -> Path:
    """%LOCALAPPDATA%, ~/Library/Caches or XDG cache, under claude-code-launcher/ire."""
    override = os.environ.get("CCL_IRE_CACHE_DIR")
    if override:
        return Path(override)
    if os.name == "nt":
        base = os.environ.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local")
        return Path(base) / "claude-code-launcher" / "ire"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Caches" / "claude-code-launcher" / "ire"
    base = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / "claude-code-launcher" / "ire"


# ---------------------------------------------------------------- auth


def find_token(timeout: float = DEFAULT_TIMEOUT) -> tuple[str | None, str]:
    """Return (token, where it came from). (None, reason) when there is no auth."""
    for name in ("GITHUB_TOKEN", "GH_TOKEN"):
        value = os.environ.get(name, "").strip()
        if value:
            return value, name
    gh = shutil.which("gh")
    if not gh:
        return None, "no GITHUB_TOKEN/GH_TOKEN and gh is not installed"
    try:
        p = subprocess.run([gh, "auth", "token", "--hostname", "github.com"],
                           capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None, "gh auth token did not answer"
    token = (p.stdout or "").strip()
    if p.returncode != 0 or not token:
        return None, "gh is installed but not logged in"
    return token, "gh auth token"


# ---------------------------------------------------------------- GitHub


class GitHub:
    """Minimal GitHub contents API client with a shared deadline."""

    def __init__(self, token: str, timeout: float = DEFAULT_TIMEOUT, api_base: str | None = None):
        self._token = token
        self.api_base = (api_base or os.environ.get("CCL_IRE_API_BASE") or API_BASE).rstrip("/")
        self.deadline = time.monotonic() + timeout

    def _get(self, url: str, accept: str) -> bytes | None:
        """Body, or None on 404. Raises FetchError on anything else."""
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise FetchError("timed out")
        req = urllib.request.Request(url, headers={
            "Accept": accept,
            "Authorization": f"Bearer {self._token}",
            "User-Agent": "claude-code-launcher-ire",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        try:
            with urllib.request.urlopen(req, timeout=left) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if e.code in (401, 403):
                raise FetchError(f"GitHub refused the credentials (HTTP {e.code})") from None
            raise FetchError(f"GitHub answered HTTP {e.code}") from None
        except (urllib.error.URLError, OSError) as e:
            reason = getattr(e, "reason", e)
            raise FetchError(f"network error: {type(reason).__name__}") from None

    def commit_sha(self, repo: str, ref: str) -> str:
        body = self._get(f"{self.api_base}/repos/{repo}/commits/{urllib.parse.quote(ref, safe='')}",
                         "application/vnd.github.sha")
        sha = (body or b"").decode("ascii", "replace").strip()
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            # 404 here means the repo is invisible to this token, which is an auth problem.
            raise FetchError("could not resolve the IRE commit (no access to the repo?)")
        return sha

    def file(self, repo: str, path: str, sha: str) -> str | None:
        body = self._get(f"{self.api_base}/repos/{repo}/contents/{urllib.parse.quote(path)}?ref={sha}",
                         "application/vnd.github.raw")
        return None if body is None else body.decode("utf-8-sig")


# ---------------------------------------------------------------- parsing


def _cost(v):
    try:
        return round(float(v), 6)
    except (TypeError, ValueError):
        return None


def parse_top20(text: str) -> list[dict]:
    rows = []
    for r in csv.DictReader(io.StringIO(text)):
        rank = (r.get("recommendation_rank") or r.get("rank") or "").strip()
        ids = [x.strip() for x in (r.get("model_ids") or "").split(";") if x.strip()]
        if not rank.isdigit() or not ids:
            continue
        rows.append({
            "rank": int(rank),
            "name": (r.get("model_family") or "").strip(),
            "vendor": (r.get("vendor") or "").strip(),
            "eligible": (r.get("recommendation_eligible") or "true").strip().lower() == "true",
            "gate_reasons": [g.strip() for g in (r.get("gate_reasons") or "").split(";") if g.strip()],
            "cost_per_mtok": _cost(r.get("supply_weighted_median_cost_usdc_per_1m")),
            "ids": ids,
        })
    rows.sort(key=lambda x: x["rank"])
    return rows


def _frontier_row(r: dict, eligible, price: dict, health) -> dict | None:
    route = (r.get("route") or "").strip()
    rank = str(r.get("frontier_rank") or "").strip()
    if not route or not rank.isdigit():
        return None
    return {
        "rank": int(rank),
        "name": (r.get("model_family") or r.get("model_label") or route).strip(),
        "vendor": (r.get("vendor") or "").strip(),
        "route": route,
        "best_route": str(r.get("is_best_route")).strip().lower() == "true",
        "eligible": eligible,
        "health": health or "",
        # IRE's price policy basis is the cheapest input ask (USDC per 1M tokens)
        "cost_per_mtok": _cost(price.get("min_ask_in")),
        "price_in": _cost(price.get("min_ask_in")),
        "price_out": _cost(price.get("min_ask_out")),
        "preferred_endpoint": (r.get("preferred_endpoint") or None),
        "system_prompt_handling": (r.get("system_prompt_handling") or None),
        "context_window": int(r["context_window"]) if str(r.get("context_window") or "").isdigit() else None,
    }


def _sort_frontier(rows: list) -> list:
    rows = [x for x in rows if x]
    rows.sort(key=lambda x: (x["rank"], not x["best_route"], x["route"]))
    return rows


def parse_frontier_json(text: str) -> list[dict]:
    """research_model_frontier_recommendations.json -> one row per enabled route."""
    doc = json.loads(text)
    elig = {}
    for m in doc.get("models") or []:
        elig[m.get("model_family")] = bool(m.get("recommendation_eligible"))
    rows = []
    for r in doc.get("routes") or []:
        if r.get("enabled") is False:
            continue
        rows.append(_frontier_row(r, elig.get(r.get("model_family"), False),
                                  r.get("price") or {}, (r.get("health") or {}).get("status")))
    return _sort_frontier(rows)


def parse_frontier_routes_csv(text: str) -> list[dict]:
    """research_model_frontier_routes.csv (fallback when the JSON is missing).
    Eligibility isn't in this file, so a route counts as eligible when it is healthy."""
    rows = []
    for r in csv.DictReader(io.StringIO(text)):
        if (r.get("enabled") or "true").strip().lower() != "true":
            continue
        health = (r.get("health_status") or "").strip()
        rows.append(_frontier_row(r, health == "healthy",
                                  {"min_ask_in": r.get("min_ask_in"), "min_ask_out": r.get("min_ask_out")},
                                  health))
    return _sort_frontier(rows)


def parse_price_cap(markdown: str) -> float | None:
    m = POLICY_RE.search(markdown)
    return float(m.group(1)) if m else None


def price_policy(cap: float, source: str) -> dict:
    return {"free_below_per_mtok": cap, "unit": "USDC per 1M tokens", "source": source}


def parse_picks(text: str) -> dict:
    """IRE fallback picks. Accepts {"main": [...], "advisor": [...]} or the same under "ladders",
    plus optional "retries" and "cooldown_s". Raises ValueError if unusable."""
    doc = json.loads(text)
    ladders = doc.get("ladders", doc)
    out = {}
    for seat in ("main", "advisor"):
        chain = ladders.get(seat)
        if not isinstance(chain, list) or not chain or not all(isinstance(x, str) and x for x in chain):
            raise ValueError(f"picks: '{seat}' must be a non-empty list of model ids")
        out[seat] = chain
    picks = {"ladders": out}
    for key in ("retries", "cooldown_s"):
        if isinstance(doc.get(key), int) and doc[key] >= 0:
            picks[key] = doc[key]
    return picks


# ---------------------------------------------------------------- bundle


def load_defaults() -> dict:
    doc = json.loads(DEFAULTS_PATH.read_text(encoding="utf-8"))
    doc["source"] = "defaults"
    out = {k: doc[k] for k in KEYS}
    out["frontier"] = list(doc.get("frontier") or [])
    return out


def validate(bundle: dict) -> dict:
    if set(bundle) != set(KEYS) | set(EXTRA_KEYS):
        raise ValueError(f"bundle keys must be exactly {KEYS + EXTRA_KEYS}")
    if not isinstance(bundle["frontier"], list) or not all(
            isinstance(r, dict) and r.get("route") for r in bundle["frontier"]):
        raise ValueError("bad frontier list")
    if bundle["source"] not in ("live", "cache", "defaults"):
        raise ValueError("bad source")
    if not bundle["top20"] or not all(r.get("ids") for r in bundle["top20"]):
        raise ValueError("empty top20")
    cap = bundle["price_policy"].get("free_below_per_mtok")
    if not isinstance(cap, (int, float)) or not 0 < cap < 100:
        raise ValueError("bad price cap")
    for seat in ("main", "advisor"):
        if not bundle["ladders"].get(seat):
            raise ValueError(f"empty {seat} ladder")
    if not isinstance(bundle["retries"], int) or not isinstance(bundle["cooldown_s"], int):
        raise ValueError("bad retries/cooldown_s")
    return bundle


def fetch_live(gh: GitHub, repo: str = IRE_REPO, ref: str = IRE_REF) -> tuple[dict, str]:
    """(bundle, commit sha). Raises FetchError or ValueError."""
    defaults = load_defaults()
    sha = gh.commit_sha(repo, ref)
    top20_csv = gh.file(repo, TOP20_PATH, sha)
    if top20_csv is None:
        raise FetchError(f"{TOP20_PATH} is missing at {sha[:10]}")
    top20 = parse_top20(top20_csv)
    if not top20:
        raise FetchError("the IRE Top 20 CSV had no usable rows")
    doc = gh.file(repo, POLICY_PATH, sha)
    cap = parse_price_cap(doc) if doc else None
    if cap is None:
        log(f"could not read the price line in {POLICY_PATH}; keeping the built-in cap")
        policy = defaults["price_policy"]
    else:
        policy = price_policy(cap, f"{POLICY_PATH}@{sha[:10]}")
    bundle = dict(defaults, source="live", top20=top20, price_policy=policy)
    picks_text = gh.file(repo, PICKS_PATH, sha)
    if picks_text is not None:
        try:
            picks = parse_picks(picks_text)
            bundle.update(picks)
            log(f"using IRE fallback picks from {PICKS_PATH}")
        except (ValueError, AttributeError, json.JSONDecodeError) as e:
            log(f"ignoring malformed {PICKS_PATH}: {e}")
    bundle["frontier"] = fetch_frontier(gh, repo, sha)
    return validate(bundle), sha


def fetch_frontier(gh: GitHub, repo: str, sha: str) -> list:
    """Optional. [] when IRE has no frontier list or it can't be parsed."""
    for path, parse in ((FRONTIER_JSON_PATH, parse_frontier_json),
                        (FRONTIER_ROUTES_PATH, parse_frontier_routes_csv)):
        text = gh.file(repo, path, sha)
        if text is None:
            continue
        try:
            rows = parse(text)
        except (ValueError, KeyError, TypeError, AttributeError) as e:
            log(f"ignoring malformed {path}: {type(e).__name__}")
            continue
        if rows:
            return rows
    return []


def write_cache(directory: Path, bundle: dict, sha: str, fetched_at: str) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    record = {"fetched_at": fetched_at, "source_sha": sha, "repo": IRE_REPO, "ref": IRE_REF,
              "bundle": bundle}
    fd, tmp = tempfile.mkstemp(dir=str(directory), prefix=".ire-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(record, fh, indent=2)
        os.replace(tmp, directory / CACHE_NAME)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def read_cache(directory: Path) -> dict | None:
    """The cache record ({fetched_at, source_sha, ..., bundle}) or None if missing or bad."""
    try:
        record = json.loads((directory / CACHE_NAME).read_text(encoding="utf-8"))
        bundle = dict(record["bundle"], source="cache")
        bundle.setdefault("frontier", [])  # caches written before the frontier key
        record["bundle"] = validate(bundle)
        return record
    except (OSError, ValueError, KeyError, TypeError, AttributeError, json.JSONDecodeError):
        return None


def now_utc() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def get_recommendations(offline: bool = False, timeout: float = DEFAULT_TIMEOUT,
                        directory: Path | None = None) -> dict:
    """The one entry point. Always returns a valid bundle; never raises for network trouble."""
    directory = directory or cache_dir()
    if offline or os.environ.get("CCL_IRE_OFFLINE") == "1":
        why = "offline mode"
    else:
        token, where = find_token(timeout)
        if token is None:
            why = where
        else:
            try:
                bundle, sha = fetch_live(GitHub(token, timeout))
                log(f"source=live  IRE {IRE_REPO}@{sha[:10]} via {where}")
                try:
                    write_cache(directory, bundle, sha, now_utc())
                except OSError as e:
                    log(f"could not write the cache ({type(e).__name__}); continuing")
                return bundle
            except (FetchError, ValueError) as e:
                why = f"{e} (auth from {where})"
    record = read_cache(directory)
    if record:
        log(f"source=cache  IRE @{str(record.get('source_sha'))[:10]} fetched {record.get('fetched_at')}"
            f"  (GitHub skipped: {why})")
        return record["bundle"]
    log(f"source=defaults  built-in picks  (GitHub skipped: {why}; no cache yet)")
    return validate(load_defaults())


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Print the launcher's IRE recommendations as JSON.")
    ap.add_argument("--offline", action="store_true", help="skip GitHub; use the cache, then defaults")
    ap.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT, help="seconds for the whole fetch (default 5)")
    ap.add_argument("--cache-dir", type=Path, default=None, help="override the cache folder")
    ap.add_argument("--out", type=Path, default=None, help="write the JSON here instead of stdout")
    a = ap.parse_args(argv)
    bundle = get_recommendations(offline=a.offline, timeout=a.timeout, directory=a.cache_dir)
    text = json.dumps(bundle, indent=2) + "\n"
    if a.out:
        a.out.parent.mkdir(parents=True, exist_ok=True)
        a.out.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
