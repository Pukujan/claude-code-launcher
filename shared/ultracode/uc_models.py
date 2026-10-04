#!/usr/bin/env python3
"""Build UltraCode-Shim's config.json and orchestrator/worker choices for the launchers.

UltraCode-Shim (OnlyTerp/UltraCode-Shim, pinned in the launchers) routes every
request by tier: the main interactive loop goes to the ORCHESTRATOR model and
every sub-agent / background call goes to the WORKER model. Its picker lists the
ids in config.json "models", and the pick lives in the shim's selection.json
(read when the shim proxy starts) or is set on a running shim with
POST /uc/select. The launchers show their own arrow-key picks instead of the
shim's TUI and preselect the result with this helper.

  build      write config.json and a tab-separated list of choices (id, label)
  preselect  set the pick: POST /uc/select on a matching running shim, else
             write selection.json (moving to a free port when a different shim
             holds ours). Prints the port the shim should use.

The choices are:
  * InferHub seats on the local LiteLLM (sonnet = main seat with its fallback
    ladder, opus = advisor seat, small-fast = fast seat)
  * UltraCode's own options from the shim's config.example.json (or a base
    config of your own), kept only when usable on this machine
  * the IRE Top 20 as ih/<id>
InferHub entries are Anthropic-format passthrough routes to LiteLLM's
/v1/messages, so the proxy-side fixes (request_fixes, web search) still apply.
CKFF routes are never offered. Standard library only; run with
`uv run --no-project python`. Never prints keys.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

IH_PREFIX = "claude-ih-"
WORKER_PREFIX = "claude-worker-"
SEATS = (
    ("main", "sonnet"),
    ("advisor", "opus"),
    ("fast", "small-fast"),
)
_ENV_REF = re.compile(r"\$\{([^}]+)\}")


def is_ckff(route_id: str, route: dict | None = None) -> bool:
    """CKFF is never offered: by id (anything with "ckff": ckff-*, ckff_astra,
    claude-ckff-*) or by upstream host. InferHub's Astra routes are not CKFF."""
    rid = (route_id or "").lower()
    if "ckff" in rid:
        return True
    up = str((route or {}).get("upstream") or "").lower()
    return "ckff" in urllib.parse.urlsplit(up).netloc


def strip_comments(obj):
    if isinstance(obj, dict):
        return {k: strip_comments(v) for k, v in obj.items() if not str(k).startswith("_")}
    if isinstance(obj, list):
        return [strip_comments(x) for x in obj]
    return obj


def _auth_ok(auth, env) -> bool:
    if not isinstance(auth, str) or not auth.strip():
        return False
    if "REPLACE_WITH" in auth:
        return False
    return all((env.get(v) or "").strip() for v in _ENV_REF.findall(auth))


def _loopback_reachable(url: str, timeout: float = 0.3) -> bool:
    parts = urllib.parse.urlsplit(url)
    host = parts.hostname or ""
    if host not in ("127.0.0.1", "localhost", "::1"):
        return True
    port = parts.port or (443 if parts.scheme == "https" else 80)
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def route_usable(route_id: str, route: dict, env=None, which=shutil.which, home=None) -> tuple[bool, str]:
    """(usable, reason). Unusable routes are left out of the choices."""
    env = os.environ if env is None else env
    if is_ckff(route_id, route):
        return False, "CKFF"
    rtype = route.get("type") or "anthropic"
    if rtype == "auto":
        return True, "auto"
    if rtype == "codex_oauth":
        codex_home = Path(env.get("CODEX_HOME") or Path(home or Path.home()) / ".codex")
        return ((codex_home / "auth.json").is_file(), "needs `codex login`")
    if rtype == "cursor_agent":
        return (bool(which("cursor-agent")), "needs the cursor-agent CLI")
    if rtype == "openai_compat":
        if not _auth_ok(route.get("auth"), env):
            return False, "no key"
        if not _loopback_reachable(str(route.get("upstream") or "")):
            return False, "local server not running"
        return True, "ok"
    if rtype == "anthropic":
        if not route.get("upstream"):
            # Real Anthropic: with the shim's upstream set to LiteLLM this would
            # be silently answered by the main seat, so it is not offered.
            return False, "real Anthropic (not served through LiteLLM)"
        if route.get("auth") and not _auth_ok(route.get("auth"), env):
            return False, "no key"
        return True, "ok"
    return False, "unknown route type"


def slug(model_id: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", model_id.lower()).strip("-")


def read_top20(path) -> list[dict]:
    """rank|name|id|eligible|cost lines (the launchers' table format)."""
    rows = []
    if not path:
        return rows
    for line in Path(path).read_text(encoding="utf-8-sig").splitlines():
        parts = line.strip().split("|")
        if len(parts) < 3 or not parts[2]:
            continue
        rows.append({"rank": parts[0], "name": parts[1], "id": parts[2],
                     "eligible": (parts[3].strip().lower() in ("true", "yes", "1")) if len(parts) > 3 else True})
    return rows


def build(example: dict, top20: list[dict], proxy_base: str, port: int,
          main_name: str = "", advisor_name: str = "", fast_name: str = "",
          env=None, which=shutil.which, home=None) -> tuple[dict, list[tuple[str, str]], list[str]]:
    """Returns (config, choices[(id, label)], notes)."""
    base = strip_comments(example or {})
    proxy_base = proxy_base.rstrip("/")
    models, routes, choices, notes = [], {}, [], []

    def add(mid, label, route):
        if mid in routes:
            return
        models.append({"id": mid, "display_name": label})
        routes[mid] = route
        choices.append((mid, label))

    # 1. InferHub seats (the seat aliases carry the fallback ladders).
    seat_labels = {
        "main": "InferHub main seat (sonnet)" + (": " + main_name if main_name else ""),
        "advisor": "InferHub advisor seat (opus)" + (": " + advisor_name if advisor_name else ""),
        "fast": "InferHub fast seat (small-fast)" + (": " + fast_name if fast_name else ""),
    }
    for role, alias in SEATS:
        if role == "advisor" and not advisor_name:
            continue  # advisor OFF: opus would just be the main seat again
        add(IH_PREFIX + role, seat_labels[role], {"upstream": proxy_base, "model": alias})

    # 2. UltraCode's own options, kept when usable here; never CKFF.
    own_routes = base.get("routes") if isinstance(base.get("routes"), dict) else {}
    own = []
    for m in base.get("models") or []:
        mid = m.get("id") if isinstance(m, dict) else None
        if not isinstance(mid, str) or not mid.startswith("claude") or mid.startswith(WORKER_PREFIX):
            continue
        route = own_routes.get(mid)
        if not isinstance(route, dict):
            notes.append(f"skip {mid}: no route")
            continue
        ok, why = route_usable(mid, route, env=env, which=which, home=home)
        if not ok:
            notes.append(f"skip {mid}: {why}")
            continue
        own.append((mid, m.get("display_name") or mid, route))
    kept_ids = {mid for mid, _, r in own if (r.get("type") or "") != "auto"}

    router = None
    rcfg = base.get("router") if isinstance(base.get("router"), dict) else None
    for mid, label, route in own:
        if (route.get("type") or "") == "auto":
            cands = []
            for c in (rcfg or {}).get("candidates") or []:
                cid = c.get("id") if isinstance(c, dict) else None
                if cid and cid in kept_ids and not is_ckff(cid, own_routes.get(cid)):
                    cands.append(c)
            if not rcfg or not rcfg.get("enabled", True) or not cands:
                notes.append(f"skip {mid}: no usable non-CKFF Auto Router candidate")
                continue
            cheapest = min(cands, key=lambda c: float(c.get("cost") or 0))["id"]
            router = dict(rcfg)
            router["id"] = mid
            router["candidates"] = cands
            if router.get("classifier") not in kept_ids:
                router["classifier"] = cheapest
            if router.get("default") not in kept_ids:
                router["default"] = cheapest
        add(mid, label, route)

    # 3. The IRE Top 20 through LiteLLM (ih/<id> deployments).
    for row in top20:
        tag = "" if row.get("eligible", True) else ", gated"
        add(IH_PREFIX + slug(row["id"]), f"{row['name']} (InferHub #{row['rank']}{tag})",
            {"upstream": proxy_base, "model": "ih/" + row["id"]})

    proxy = {
        "listen_port": int(port),
        "anthropic_upstream": proxy_base,
        "include_stock_models": False,
        "learn_stock_models": False,
    }
    floor = (base.get("proxy") or {}).get("max_tokens_floor")
    if floor:
        proxy["max_tokens_floor"] = floor
    config = {"proxy": proxy, "models": models, "routes": routes}
    if router:
        config["router"] = router
    return config, choices, notes


def selection_payload(orch: str, worker: str) -> dict:
    """selection.json contents, matching the shim's own _set_selection()."""
    if worker and worker != orch:
        return {"orch": orch, "worker": worker, "worker_explicit": True}
    return {"orch": orch, "worker": orch, "worker_explicit": False}


def _get_json(url: str, timeout: float = 1.5):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def health_matches(health: dict, config: dict) -> bool:
    """Is the shim on this port running exactly this config?"""
    if not isinstance(health, dict) or not health.get("ok"):
        return False
    if (health.get("upstream") or "").rstrip("/") != config["proxy"]["anthropic_upstream"]:
        return False
    want = {m["id"] for m in config["models"]}
    have = {m.get("id") for m in health.get("custom_models") or []
            if isinstance(m, dict) and not str(m.get("id", "")).startswith(WORKER_PREFIX)}
    if want != have:
        return False
    slots = health.get("slots") or {}
    for mid, route in config["routes"].items():
        s = slots.get(mid)
        if not isinstance(s, dict) or s.get("model") != route.get("model"):
            return False
    return True


def port_free(port: int) -> bool:
    """Nothing is listening on 127.0.0.1:port.

    A connect probe, not a bind: a bind fails for a minute after the previous
    shim exits (TIME_WAIT), which would hop ports on every quick relaunch."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.5)
        try:
            s.connect(("127.0.0.1", port))
            return False
        except OSError:
            return True


def write_json(path, obj) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(obj, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def preselect(config_path, state_file, orch: str, worker: str, timeout: float = 1.5,
              max_tries: int = 20) -> tuple[int, str]:
    """Returns (port, how) with how = "posted" or "written"."""
    config = json.loads(Path(config_path).read_text(encoding="utf-8"))
    ids = {m["id"] for m in config["models"]}
    if orch not in ids or (worker and worker not in ids):
        raise SystemExit(f"uc_models: {orch!r}/{worker!r} not in {config_path}")
    port = int(config["proxy"]["listen_port"])
    for _ in range(max_tries):
        try:
            health = _get_json(f"http://127.0.0.1:{port}/healthz", timeout)
        except (OSError, ValueError, urllib.error.URLError):
            health = None
        if health is not None and health_matches(health, config):
            body = json.dumps({"orchestrator": orch, "worker": worker if worker != orch else ""}).encode()
            req = urllib.request.Request(f"http://127.0.0.1:{port}/uc/select", data=body,
                                         headers={"Content-Type": "application/json"}, method="POST")
            with urllib.request.urlopen(req, timeout=timeout) as r:
                if json.loads(r.read().decode("utf-8")).get("ok"):
                    return port, "posted"  # the running shim saves its own selection.json
        if health is None and port_free(port):
            break
        port += 1  # a different shim (or something else) holds this port
    else:
        raise SystemExit("uc_models: no free port for the UltraCode shim")
    if port != int(config["proxy"]["listen_port"]):
        config["proxy"]["listen_port"] = port
        write_json(config_path, config)
    write_json(state_file, selection_payload(orch, worker))
    return port, "written"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--example", required=True, help="the shim's config.example.json")
    b.add_argument("--base", default=os.environ.get("CCL_UC_BASE_CONFIG", ""),
                   help="your own shim config to take UltraCode options from (default: --example)")
    b.add_argument("--top20", default="", help="rank|name|id|eligible|cost lines")
    b.add_argument("--proxy-base", required=True)
    b.add_argument("--port", type=int, required=True)
    b.add_argument("--main-name", default="")
    b.add_argument("--advisor-name", default="")
    b.add_argument("--fast-name", default="")
    b.add_argument("--config-out", required=True)
    b.add_argument("--list-out", required=True)
    p = sub.add_parser("preselect")
    p.add_argument("--config", required=True)
    p.add_argument("--state-file", required=True, help="the shim's selection.json")
    p.add_argument("--orch", required=True)
    p.add_argument("--worker", default="", help="empty = same as orchestrator")
    a = ap.parse_args(argv)

    if a.cmd == "build":
        src = a.base if a.base and Path(a.base).is_file() else a.example
        example = json.loads(Path(src).read_text(encoding="utf-8-sig"))
        config, choices, notes = build(example, read_top20(a.top20), a.proxy_base, a.port,
                                       a.main_name, a.advisor_name, a.fast_name)
        write_json(a.config_out, config)
        Path(a.list_out).parent.mkdir(parents=True, exist_ok=True)
        Path(a.list_out).write_text("".join(f"{i}\t{label}\n" for i, label in choices), encoding="utf-8")
        for n in notes:
            print("uc_models: " + n, file=sys.stderr)
        print(f"uc_models: {len(choices)} choices -> {a.config_out}", file=sys.stderr)
        return 0
    port, how = preselect(a.config, a.state_file, a.orch, a.worker)
    print(f"uc_models: orchestrator={a.orch} worker={a.worker or '(same)'} {how} (shim port {port})",
          file=sys.stderr)
    print(port)
    return 0


if __name__ == "__main__":
    sys.exit(main())
