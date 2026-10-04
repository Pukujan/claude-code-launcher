#!/usr/bin/env python3
"""Fetch IRE recommendations for the Claude Code launcher, on demand.

What it pulls from the private repo Pukujan/inference-recommendation-engine:
  - the Top 20 recommendation list (CSV)
  - the daily shortlist, which IRE treats as its "Top 20+" list (CSV)
  - the price policy line in docs/INFERHUB-API-SETUP.md (the $/1M-token cap)
  - fallback picks, if IRE publishes them (optional JSON; see FALLBACK_PICKS_PATH)

Order of sources, first one that works wins:
  1. GitHub, using whatever auth this machine already has
     (GH_TOKEN / GITHUB_TOKEN, then the `gh` CLI, then git's credential helper)
  2. the last good copy cached on this machine
  3. the built-in defaults shipped next to this file (defaults.json)

Standard library only, so it runs on stock Python 3.8+ on Windows and macOS.
It never prints a token. Output is one JSON document (the "bundle") on stdout
or in --out; progress and warnings go to stderr.
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
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULTS_PATH = HERE / "defaults.json"
SCHEMA = "ccl-ire-bundle/v1"

IRE_REPO = os.environ.get("CCL_IRE_REPO", "Pukujan/inference-recommendation-engine")
IRE_REF = os.environ.get("CCL_IRE_REF", "main")
LISTS_DIR = "operational/telemetry/gravebuster/pipeline/ihub/lists"
TOP20_PATH = f"{LISTS_DIR}/research_model_top20_recommendations.csv"
SHORTLIST_PATH = f"{LISTS_DIR}/research_model_daily_shortlist.csv"
POLICY_PATH = "docs/INFERHUB-API-SETUP.md"
# IRE does not publish this file yet (checked 2026-10-03). When it does, the
# launcher uses it as the default ladders; until then ladders are derived.
FALLBACK_PICKS_PATH = "operational/recommendations/claude-code-fallbacks.v1.json"

POLICY_RE = re.compile(
    r"below\s*\*{0,2}\s*\$\s*([0-9]+(?:\.[0-9]+)?)\s*(?:USDC|USD)?\s*per\s*1\s*million\s*tokens",
    re.IGNORECASE,
)


def log(msg: str) -> None:
    print(f"[ire] {msg}", file=sys.stderr, flush=True)


def now_utc() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def default_cache_dir() -> Path:
    env = os.environ.get("CCL_CACHE_DIR")
    if env:
        return Path(env) / "ire"
    if os.name == "nt":
        base = os.environ.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local")
        return Path(base) / "claude-code-launcher" / "ire"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Caches" / "claude-code-launcher" / "ire"
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "claude-code-launcher" / "ire"


# --------------------------------------------------------------------------- transports


class FetchError(Exception):
    """GitHub could not be reached or refused us (network, auth, rate limit)."""


class NotFound(Exception):
    """The file does not exist at that ref (a real answer, not an outage)."""


class TokenTransport:
    """GitHub REST contents API with a bearer token (or none, for tests)."""

    def __init__(self, token: str | None, label: str, timeout: float,
                 api_base: str = "https://api.github.com"):
        self._token = token
        self.label = label
        self.timeout = timeout
        self.api_base = api_base.rstrip("/")

    def _get(self, url: str, accept: str) -> bytes:
        headers = {"Accept": accept, "User-Agent": "claude-code-launcher-ire",
                   "X-GitHub-Api-Version": "2022-11-28"}
        if self._token:
            headers["Authorization"] = f"Bearer {self._token}"
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                raise NotFound(url) from None
            raise FetchError(f"HTTP {e.code} from GitHub via {self.label}") from None
        except (urllib.error.URLError, OSError, TimeoutError) as e:
            raise FetchError(f"network error via {self.label}: {getattr(e, 'reason', e)}") from None

    def get_file(self, repo: str, path: str, ref: str) -> bytes:
        q = urllib.parse.quote(path)
        return self._get(f"{self.api_base}/repos/{repo}/contents/{q}?ref={urllib.parse.quote(ref)}",
                         "application/vnd.github.raw")

    def get_sha(self, repo: str, ref: str) -> str:
        return self._get(f"{self.api_base}/repos/{repo}/commits/{urllib.parse.quote(ref)}",
                         "application/vnd.github.sha").decode().strip()


class GhCliTransport:
    """Shells out to `gh api`, so the token never passes through this process."""

    label = "gh CLI"

    def __init__(self, gh: str, timeout: float):
        self.gh = gh
        self.timeout = timeout

    def _api(self, endpoint: str, accept: str) -> bytes:
        try:
            p = subprocess.run([self.gh, "api", "-H", f"Accept: {accept}", endpoint],
                               capture_output=True, timeout=self.timeout)
        except (OSError, subprocess.TimeoutExpired) as e:
            raise FetchError(f"gh CLI failed: {type(e).__name__}") from None
        if p.returncode == 0:
            return p.stdout
        err = (p.stderr or b"").decode("utf-8", "replace")
        if "404" in err or "Not Found" in err:
            raise NotFound(endpoint)
        first = err.strip().splitlines()[0] if err.strip() else f"exit {p.returncode}"
        raise FetchError(f"gh CLI: {first[:160]}")

    def get_file(self, repo: str, path: str, ref: str) -> bytes:
        return self._api(f"repos/{repo}/contents/{urllib.parse.quote(path)}?ref={urllib.parse.quote(ref)}",
                         "application/vnd.github.raw")

    def get_sha(self, repo: str, ref: str) -> str:
        return self._api(f"repos/{repo}/commits/{urllib.parse.quote(ref)}",
                         "application/vnd.github.sha").decode().strip()


def _gh_is_authed(gh: str, timeout: float) -> bool:
    try:
        p = subprocess.run([gh, "auth", "status", "--hostname", "github.com"],
                           capture_output=True, timeout=timeout)
        return p.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def _git_credential_token(timeout: float) -> str | None:
    """Ask git's configured credential helper for the github.com password/token.

    Non-interactive: prompts are disabled, so a machine without a stored
    credential simply returns None.
    """
    git = shutil.which("git")
    if not git:
        return None
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="never", GIT_ASKPASS="")
    try:
        p = subprocess.run([git, "credential", "fill"], input=b"protocol=https\nhost=github.com\n\n",
                           capture_output=True, timeout=timeout, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if p.returncode != 0:
        return None
    for line in p.stdout.decode("utf-8", "replace").splitlines():
        if line.startswith("password="):
            return line.split("=", 1)[1].strip() or None
    return None


def pick_transports(timeout: float) -> list:
    """Every auth route this machine has, best first. Empty list = no auth."""
    api_base = os.environ.get("CCL_IRE_API_BASE", "https://api.github.com")
    out = []
    for name in ("GH_TOKEN", "GITHUB_TOKEN"):
        if os.environ.get(name):
            out.append(TokenTransport(os.environ[name], f"${name}", timeout, api_base))
            break
    if os.environ.get("CCL_IRE_NO_GH") != "1" and api_base == "https://api.github.com":
        gh = shutil.which("gh")
        if gh and _gh_is_authed(gh, timeout):
            out.append(GhCliTransport(gh, timeout))
    if os.environ.get("CCL_IRE_NO_GIT_CRED") != "1":
        tok = _git_credential_token(timeout)
        if tok:
            out.append(TokenTransport(tok, "git credential helper", timeout, api_base))
    if os.environ.get("CCL_IRE_ANON") == "1":  # tests / public mirrors only
        out.append(TokenTransport(None, "anonymous", timeout, api_base))
    return out


# --------------------------------------------------------------------------- parsing


def _f(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _ids(v: str) -> list:
    return [x.strip() for x in (v or "").split(";") if x.strip()]


def parse_top20(text: str) -> list:
    rows = []
    for r in csv.DictReader(io.StringIO(text)):
        rank = r.get("recommendation_rank") or r.get("rank")
        ids = _ids(r.get("model_ids", ""))
        if not rank or not ids:
            continue
        rows.append({
            "rank": int(rank),
            "name": r.get("model_family", "").strip(),
            "vendor": r.get("vendor", "").strip(),
            "eligible": str(r.get("recommendation_eligible", "true")).strip().lower() == "true",
            "gate_reasons": r.get("gate_reasons", "").strip(),
            "cost_per_mtok": _f(r.get("supply_weighted_median_cost_usdc_per_1m")),
            "price_regime": r.get("price_regime", "").strip(),
            "ids": ids,
        })
    rows.sort(key=lambda x: x["rank"])
    return rows


def parse_shortlist(text: str) -> list:
    out = []
    for r in csv.DictReader(io.StringIO(text)):
        ids = _ids(r.get("model_ids", ""))
        if r.get("rank") and ids:
            out.append({"rank": int(r["rank"]), "name": r.get("model_family", "").strip(),
                        "vendor": r.get("vendor", "").strip(),
                        "cost_per_mtok": _f(r.get("supply_weighted_median_cost_usdc_per_1m")),
                        "ids": ids})
    return out


def parse_price_policy(md: str) -> float | None:
    m = POLICY_RE.search(md)
    return float(m.group(1)) if m else None


def parse_fallback_picks(raw: str) -> dict:
    doc = json.loads(raw)
    out = {}
    for role in ("main", "advisor"):
        spec = doc.get(role) or {}
        fb = [x for x in (spec.get("fallbacks") or []) if isinstance(x, str)]
        out[role] = {"primary": spec.get("primary"), "fallbacks": fb[:3]}
    return out


# --------------------------------------------------------------------------- bundle


def load_defaults() -> dict:
    doc = json.loads(DEFAULTS_PATH.read_text(encoding="utf-8"))
    doc["source"] = {"kind": "defaults", "detail": "built-in defaults.json"}
    doc["fetched_at"] = None
    return doc


def validate(bundle: dict) -> None:
    if bundle.get("schema") != SCHEMA:
        raise ValueError("wrong schema")
    if not bundle.get("top20"):
        raise ValueError("empty top20")
    cap = (bundle.get("price_policy") or {}).get("max_cost_per_mtok")
    if not isinstance(cap, (int, float)) or not (0 < cap < 100):
        raise ValueError("bad price cap")


def fetch_online(transport, repo: str = IRE_REPO, ref: str = IRE_REF) -> dict:
    defaults = load_defaults()
    warnings = []
    top20 = parse_top20(transport.get_file(repo, TOP20_PATH, ref).decode("utf-8-sig"))
    try:
        shortlist = parse_shortlist(transport.get_file(repo, SHORTLIST_PATH, ref).decode("utf-8-sig"))
    except NotFound:
        shortlist, _ = [], warnings.append("IRE shortlist (Top 20+) not found; skipped")
    cap = None
    try:
        cap = parse_price_policy(transport.get_file(repo, POLICY_PATH, ref).decode("utf-8"))
    except NotFound:
        pass
    if cap is None:
        cap = defaults["price_policy"]["max_cost_per_mtok"]
        warnings.append("could not read the price line in IRE docs; using the built-in $%.2f cap" % cap)
    picks, picks_from = None, "derived"
    try:
        picks = parse_fallback_picks(transport.get_file(repo, FALLBACK_PICKS_PATH, ref).decode("utf-8"))
        picks_from = "ire"
    except NotFound:
        warnings.append("IRE publishes no fallback picks yet; ladders are derived from the Top 20 and the built-in chains")
    except (ValueError, json.JSONDecodeError):
        warnings.append("IRE fallback picks file is malformed; ignored")
    sha = None
    try:
        sha = transport.get_sha(repo, ref)
    except (FetchError, NotFound):
        pass
    bundle = {
        "schema": SCHEMA,
        "source": {"kind": "github", "detail": f"{repo}@{ref}", "commit": sha, "auth": transport.label},
        "fetched_at": now_utc(),
        "price_policy": {"max_cost_per_mtok": cap, "unit": "USDC per 1M tokens", "source": POLICY_PATH},
        "top20": top20,
        "shortlist": shortlist,
        # Built-in chains stay as the base; IRE picks override when published.
        "ladders": picks if picks else defaults["ladders"],
        "ladders_from": picks_from,
        "retry": defaults["retry"],
        "warnings": warnings,
    }
    validate(bundle)
    return bundle


def cache_file(cache_dir: Path) -> Path:
    return cache_dir / "ire-bundle.json"


def write_cache(cache_dir: Path, bundle: dict) -> None:
    cache_dir.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(cache_dir), prefix=".ire-", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(bundle, fh, indent=2)
    os.replace(tmp, cache_file(cache_dir))


def read_cache(cache_dir: Path) -> dict | None:
    p = cache_file(cache_dir)
    if not p.is_file():
        return None
    try:
        b = json.loads(p.read_text(encoding="utf-8"))
        validate(b)
    except (ValueError, OSError, json.JSONDecodeError):
        return None
    when = b.get("fetched_at")
    b["source"] = dict(b.get("source") or {}, kind="cache", detail=f"cached copy from {when} ({p})")
    return b


def get_bundle(offline: bool = False, cache_dir: Path | None = None, timeout: float = 8.0) -> dict:
    cache_dir = cache_dir or default_cache_dir()
    reasons = []
    if offline or os.environ.get("CCL_IRE_OFFLINE") == "1":
        reasons.append("offline mode requested")
    else:
        transports = pick_transports(timeout)
        if not transports:
            reasons.append("no GitHub auth on this machine (no GH_TOKEN/GITHUB_TOKEN, gh not logged in, no git credential)")
        for t in transports:
            try:
                b = fetch_online(t)
                log(f"fetched IRE from GitHub via {t.label}" + (f" @ {b['source']['commit'][:10]}" if b["source"].get("commit") else ""))
                try:
                    write_cache(cache_dir, b)
                except OSError as e:
                    log(f"warning: could not write cache: {e}")
                return b
            except (FetchError, NotFound, ValueError) as e:
                reasons.append(f"{t.label}: {e}")
    for r in reasons:
        log(f"GitHub fetch skipped/failed: {r}")
    b = read_cache(cache_dir)
    if b:
        log(f"using cached IRE copy from {b.get('fetched_at')}")
    else:
        log("no cached IRE copy; using built-in defaults")
        b = load_defaults()
    b.setdefault("warnings", [])
    b["warnings"] = list(b["warnings"]) + [f"GitHub unavailable: {r}" for r in reasons]
    return b


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--offline", action="store_true", help="skip GitHub; use cache, then defaults")
    ap.add_argument("--cache-dir", type=Path, default=None)
    ap.add_argument("--timeout", type=float, default=8.0)
    ap.add_argument("--out", type=Path, default=None, help="write the bundle here instead of stdout")
    ap.add_argument("--summary", action="store_true", help="print a short human summary to stderr")
    a = ap.parse_args(argv)
    b = get_bundle(offline=a.offline, cache_dir=a.cache_dir, timeout=a.timeout)
    text = json.dumps(b, indent=2)
    if a.out:
        a.out.parent.mkdir(parents=True, exist_ok=True)
        a.out.write_text(text + "\n", encoding="utf-8")
    else:
        sys.stdout.write(text + "\n")
    if a.summary:
        src = b["source"]
        log(f"source={src['kind']} ({src.get('detail')}) cap=${b['price_policy']['max_cost_per_mtok']}/1M "
            f"top20={len(b['top20'])} ladders_from={b.get('ladders_from', 'defaults')}")
        for w in b.get("warnings") or []:
            log(f"note: {w}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
