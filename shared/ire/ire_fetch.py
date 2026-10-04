#!/usr/bin/env python3
"""Fetch IRE recommendations for the Claude Code launcher at start-up.

Both launchers (windows/ and mac/) run this file. It reads three things from the
private repo Pukujan/inference-recommendation-engine on main:

  - the Top 20 list (CSV)
  - the price policy line in docs/INFERHUB-API-SETUP.md
    ("below $0.10 USDC per 1 million tokens" counts as effectively free)
  - fallback picks, if IRE ever publishes them (optional JSON, see PICKS_PATH)

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
# The frontier list (IRE PR #68, 9a8fba0): stronger models with live route prices,
# next to the cheap Top 20. All three files are optional; a missing one is fine.
LISTS_DIR = "operational/telemetry/gravebuster/pipeline/ihub/lists"
FRONTIER_PATHS = {
    "recommendations_csv": f"{LISTS_DIR}/research_model_frontier_recommendations.csv",
    "recommendations_json": f"{LISTS_DIR}/research_model_frontier_recommendations.json",
    "routes_csv": f"{LISTS_DIR}/research_model_frontier_routes.csv",
}
FRONTIER_KEYS = ("available", "source", "ire_sha", "files", "schema", "generated_at", "models", "routes")

DEFAULT_TIMEOUT = 5.0
CACHE_NAME = "ire-cache.json"
KEYS = ("source", "top20", "price_policy", "ladders", "retries", "cooldown_s")

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


def _bool(v) -> bool:
    return str(v).strip().lower() == "true"


def _list(v) -> list[str]:
    if isinstance(v, list):
        return [str(x).strip() for x in v if str(x).strip()]
    return [x.strip() for x in str(v or "").split(";") if x.strip()]


def frontier_model(r: dict) -> dict:
    """One frontier model row, from the CSV or the JSON (same field names)."""
    rank = str(r.get("frontier_rank") or "").strip()
    return {
        "rank": int(rank) if rank.isdigit() else None,
        "name": str(r.get("model_family") or "").strip(),
        "vendor": str(r.get("vendor") or "").strip(),
        "tier": str(r.get("tier") or "").strip(),
        "eligible": _bool(r.get("recommendation_eligible")),
        "gate_reasons": _list(r.get("gate_reasons")),
        "best_route": str(r.get("best_route") or "").strip(),
        "cost_per_mtok": _cost(r.get("best_route_blended_min_ask_3to1")),
        "system_prompt_handling": str(r.get("best_route_system_prompt_handling") or "").strip(),
        "preferred_endpoint": str(r.get("best_route_preferred_endpoint") or "").strip(),
        "ids": _list(r.get("model_ids")),
    }


def _health(r: dict) -> str:
    h = r.get("health_status") or r.get("health") or ""
    if isinstance(h, dict):
        h = h.get("status") or h.get("health_status") or ""
    return str(h).strip()


def frontier_route(r: dict) -> dict:
    """One frontier route row. system_prompt_handling and preferred_endpoint are kept as IRE
    wrote them (cx routes say developer_message and /v1/responses)."""
    rank = str(r.get("frontier_rank") or "").strip()
    return {
        "rank": int(rank) if rank.isdigit() else None,
        "name": str(r.get("model_family") or "").strip(),
        "route": str(r.get("route") or "").strip(),
        "best": _bool(r.get("is_best_route")),
        "health": _health(r),
        "cost_per_mtok": _cost(r.get("blended_min_ask_3to1")),
        "system_prompt_handling": str(r.get("system_prompt_handling") or "").strip(),
        "preferred_endpoint": str(r.get("preferred_endpoint") or "").strip(),
        "required_instructions_value": str(r.get("required_instructions_value") or "").strip(),
    }


def empty_frontier(source: str = "none") -> dict:
    return {"available": False, "source": source, "ire_sha": None,
            "files": {k: False for k in FRONTIER_PATHS}, "schema": None, "generated_at": None,
            "models": [], "routes": []}


def parse_frontier(texts: dict, sha: str | None) -> dict:
    """texts maps FRONTIER_PATHS keys to file text or None. CSVs win; the JSON fills gaps."""
    out = empty_frontier("live")
    out["ire_sha"] = sha
    out["files"] = {k: texts.get(k) is not None for k in FRONTIER_PATHS}
    doc = {}
    if texts.get("recommendations_json"):
        try:
            doc = json.loads(texts["recommendations_json"])
            if not isinstance(doc, dict):
                doc = {}
        except json.JSONDecodeError:
            log(f"ignoring malformed {FRONTIER_PATHS['recommendations_json']}")
            doc = {}
    out["schema"] = doc.get("schema")
    out["generated_at"] = doc.get("generated_at")
    if texts.get("recommendations_csv"):
        rows = list(csv.DictReader(io.StringIO(texts["recommendations_csv"])))
        out["models"] = [frontier_model(r) for r in rows]
        if not out["generated_at"] and rows:
            out["generated_at"] = rows[0].get("generated_at") or None
    elif isinstance(doc.get("models"), list):
        out["models"] = [frontier_model(r) for r in doc["models"] if isinstance(r, dict)]
    if texts.get("routes_csv"):
        out["routes"] = [frontier_route(r) for r in csv.DictReader(io.StringIO(texts["routes_csv"]))]
    elif isinstance(doc.get("routes"), list):
        out["routes"] = [frontier_route(r) for r in doc["routes"] if isinstance(r, dict)]
    out["models"] = sorted((m for m in out["models"] if m["name"]),
                           key=lambda m: (m["rank"] is None, m["rank"] or 0))
    out["routes"] = [r for r in out["routes"] if r["route"]]
    out["available"] = bool(out["models"] or out["routes"])
    return out


def fetch_frontier(gh: "GitHub", sha: str, repo: str = IRE_REPO) -> dict:
    """The optional frontier list at the same IRE commit. Never raises: a missing file,
    a timeout or a parse problem gives a partial or empty answer."""
    texts = {}
    for key, path in FRONTIER_PATHS.items():
        try:
            texts[key] = gh.file(repo, path, sha)
        except FetchError as e:
            log(f"frontier list: skipped {path.rsplit('/', 1)[-1]} ({e})")
            texts[key] = None
    try:
        return parse_frontier(texts, sha)
    except (ValueError, TypeError, AttributeError, csv.Error) as e:
        log(f"frontier list unusable ({type(e).__name__}); continuing without it")
        return empty_frontier()


# ---------------------------------------------------------------- bundle


def load_defaults() -> dict:
    doc = json.loads(DEFAULTS_PATH.read_text(encoding="utf-8"))
    doc["source"] = "defaults"
    return {k: doc[k] for k in KEYS}


def validate(bundle: dict) -> dict:
    if set(bundle) != set(KEYS):
        raise ValueError(f"bundle keys must be exactly {KEYS}")
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
    return validate(bundle), sha


def write_cache(directory: Path, bundle: dict, sha: str, fetched_at: str,
                frontier: dict | None = None) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    record = {"fetched_at": fetched_at, "source_sha": sha, "repo": IRE_REPO, "ref": IRE_REF,
              "bundle": bundle}
    if frontier is not None:
        record["frontier"] = frontier
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
        record["bundle"] = validate(bundle)
        return record
    except (OSError, ValueError, KeyError, TypeError, AttributeError, json.JSONDecodeError):
        return None


def now_utc() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _cached_frontier(record: dict | None) -> dict:
    fr = (record or {}).get("frontier")
    if isinstance(fr, dict) and set(fr) == set(FRONTIER_KEYS):
        return dict(fr, source="cache")
    return empty_frontier()


def get_recommendations_and_frontier(offline: bool = False, timeout: float = DEFAULT_TIMEOUT,
                                     directory: Path | None = None) -> tuple[dict, dict]:
    """(bundle, frontier). The bundle is the six-key contract; the frontier list is
    separate so the ladder picker's schema does not change. Never raises for network trouble."""
    directory = directory or cache_dir()
    if offline or os.environ.get("CCL_IRE_OFFLINE") == "1":
        why = "offline mode"
    else:
        token, where = find_token(timeout)
        if token is None:
            why = where
        else:
            try:
                gh = GitHub(token, timeout)
                bundle, sha = fetch_live(gh)
                log(f"source=live  IRE {IRE_REPO}@{sha[:10]} via {where}")
                frontier = fetch_frontier(gh, sha)
                if frontier["available"]:
                    log(f"frontier list: {len(frontier['models'])} models, {len(frontier['routes'])} routes")
                else:
                    log("frontier list: not published at this IRE commit (optional)")
                try:
                    write_cache(directory, bundle, sha, now_utc(), frontier)
                except OSError as e:
                    log(f"could not write the cache ({type(e).__name__}); continuing")
                return bundle, frontier
            except (FetchError, ValueError) as e:
                why = f"{e} (auth from {where})"
    record = read_cache(directory)
    if record:
        log(f"source=cache  IRE @{str(record.get('source_sha'))[:10]} fetched {record.get('fetched_at')}"
            f"  (GitHub skipped: {why})")
        return record["bundle"], _cached_frontier(record)
    log(f"source=defaults  built-in picks  (GitHub skipped: {why}; no cache yet)")
    return validate(load_defaults()), empty_frontier()


def get_recommendations(offline: bool = False, timeout: float = DEFAULT_TIMEOUT,
                        directory: Path | None = None) -> dict:
    """The one entry point for the bundle. Always returns a valid bundle."""
    return get_recommendations_and_frontier(offline, timeout, directory)[0]


def write_json(path: Path, doc: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")


def top20_csv(bundle: dict) -> str:
    """The bundle's Top 20 in the CSV shape sync_inferhub_top20.py reads."""
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(["recommendation_rank", "model_family", "vendor", "recommendation_eligible",
                "supply_weighted_median_cost_usdc_per_1m", "model_ids"])
    for r in bundle["top20"]:
        w.writerow([r["rank"], r["name"], r.get("vendor", ""), "true" if r["eligible"] else "false",
                    "" if r.get("cost_per_mtok") is None else r["cost_per_mtok"], ";".join(r["ids"])])
    return buf.getvalue()


def shell_table(bundle: dict) -> str:
    """rank|name|id|eligible|cost lines for the Mac launcher (first InferHub id per row)."""
    lines = []
    for r in bundle["top20"]:
        name = r["name"].replace("|", "/").replace("\n", " ") or r["ids"][0]
        cost = "" if r.get("cost_per_mtok") is None else f"{r['cost_per_mtok']:.3f}"
        lines.append(f"{r['rank']}|{name}|{r['ids'][0]}|{'true' if r['eligible'] else 'false'}|{cost}")
    return "\n".join(lines) + "\n"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Print the launcher's IRE recommendations as JSON.")
    ap.add_argument("--offline", action="store_true", help="skip GitHub; use the cache, then defaults")
    ap.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT, help="seconds for the whole fetch (default 5)")
    ap.add_argument("--cache-dir", type=Path, default=None, help="override the cache folder")
    ap.add_argument("--out", type=Path, default=None, help="write the JSON here instead of stdout")
    ap.add_argument("--frontier-out", type=Path, default=None,
                    help="also write the optional frontier list here (empty when IRE has none)")
    ap.add_argument("--top20-csv", type=Path, default=None,
                    help="also write the Top 20 as a CSV for sync_inferhub_top20.py")
    ap.add_argument("--table-out", type=Path, default=None,
                    help="also write rank|name|id|eligible|cost lines (the Mac picker table)")
    a = ap.parse_args(argv)
    bundle, frontier = get_recommendations_and_frontier(offline=a.offline, timeout=a.timeout,
                                                        directory=a.cache_dir)
    if a.out:
        write_json(a.out, bundle)
    else:
        sys.stdout.write(json.dumps(bundle, indent=2) + "\n")
    if a.frontier_out:
        write_json(a.frontier_out, frontier)
    for path, text in ((a.top20_csv, top20_csv), (a.table_out, shell_table)):
        if path:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text(bundle), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
