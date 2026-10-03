#!/usr/bin/env python3
"""POST /workbench/reload_runtime on the local LiteLLM proxy (no secrets printed).

Uses LITELLM_MASTER_KEY when one is set (process env, the files listed in
CLAUDE_IH_ENV_FILES, or the repository .env; names only logged). The proxy
runs keyless by default, and then the request goes without an Authorization
header; the endpoint accepts that only from loopback when no master key is set.
If the proxy is not reachable, exits 0 with a skip message so apply/merge can
stay non-fatal when the proxy is down.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parents[1]
DEFAULT_BASE = "http://127.0.0.1:4000"


def env_candidates() -> list[Path]:
    """Env files to read: the launcher's list (CLAUDE_IH_ENV_FILES, os.pathsep
    separated), then the repository .env."""
    paths = [Path(p) for p in os.environ.get("CLAUDE_IH_ENV_FILES", "").split(os.pathsep) if p.strip()]
    paths.append(REPO_ROOT / ".env")
    return paths


def load_dotenv_files() -> list[str]:
    loaded: list[str] = []
    for path in env_candidates():
        if not path.is_file():
            continue
        for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            m = re.match(r"^\s*([A-Za-z0-9_.-]+)\s*=\s*(.*?)\s*$", line)
            if not m:
                continue
            key, val = m.group(1), m.group(2)
            if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
                val = val[1:-1]
            os.environ.setdefault(key, val)
        loaded.append(str(path))
    return loaded


def master_key() -> str | None:
    return os.environ.get("LITELLM_MASTER_KEY") or None


def request_headers(key: str | None) -> dict[str, str]:
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if key:
        headers["Authorization"] = f"Bearer {key}"
    return headers


def liveliness_ok(base: str, timeout: float) -> bool:
    try:
        with urllib.request.urlopen(base.rstrip("/") + "/health/liveliness", timeout=timeout) as resp:
            return 200 <= resp.status < 300
    except Exception:
        return False


def post_reload(base: str, scope: str, key: str | None, timeout: float) -> tuple[int, dict | str]:
    url = base.rstrip("/") + "/workbench/reload_runtime"
    body = json.dumps({"scope": scope}).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers=request_headers(key),
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            try:
                return resp.status, json.loads(raw)
            except json.JSONDecodeError:
                return resp.status, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, raw


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base-url", default=os.environ.get("LITELLM_BASE_URL", DEFAULT_BASE))
    ap.add_argument("--scope", choices=("seat", "all"), default="seat")
    ap.add_argument("--timeout", type=float, default=15.0)
    ap.add_argument(
        "--strict",
        action="store_true",
        help="Exit non-zero when proxy is down or reload fails (default: soft-skip when down)",
    )
    args = ap.parse_args()

    loaded = load_dotenv_files()
    if loaded:
        print(f"loaded env names from {len(loaded)} file(s) [values not printed]")

    key = master_key()
    if not key:
        print("no LITELLM_MASTER_KEY set; calling reload without auth (keyless proxy)")

    if not liveliness_ok(args.base_url, min(args.timeout, 5.0)):
        msg = f"proxy not reachable at {args.base_url} (/health/liveliness)"
        print(f"SKIP reload: {msg}")
        return 1 if args.strict else 0

    status, payload = post_reload(args.base_url, args.scope, key, args.timeout)
    if status == 404:
        print(
            "SKIP reload: /workbench/reload_runtime missing "
            "(restart proxy with PYTHONPATH=repo root so sitecustomize loads)"
        )
        return 1 if args.strict else 0
    if status >= 400:
        print(f"ERROR reload HTTP {status}: {payload}", file=sys.stderr)
        return 1

    if isinstance(payload, dict):
        aliases = payload.get("aliases") or {}
        print(
            f"Reloaded scope={payload.get('scope', args.scope)} "
            f"updated={payload.get('updated', '?')} "
            f"sonnet={aliases.get('sonnet')} opus={aliases.get('opus')}"
        )
    else:
        print(f"Reloaded OK: {payload}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
