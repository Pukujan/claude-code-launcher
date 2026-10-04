#!/usr/bin/env python3
"""Launcher entry point for fallback ladders (Windows and Mac call the same thing).

  catalog  [--bundle B]                       pickable routes as JSON (Top 20 + opted-in extras)
  choose   --state S --role main --primary ID [--bundle B]
  choose   --state S --role advisor --primary ID              ('' = advisor OFF)
  primary  --role main|advisor [--allow-off] [--list frontier|top20] --out F
                                              pick a seat primary from either IRE list;
                                              writes "id<TAB>name" to F (exit 2 = cancelled)
  apply    --state S [--base-url http://127.0.0.1:4000]       push to the running proxy
  show     [--base-url ...]                                   read back what the proxy has

Defaults come from inputs.load_inputs(): an IRE bundle when one is available
(--bundle, or the shared/ire module), otherwise the launchers' Top 20 table
and the fixed chains. The first `choose` stores those inputs in the state
file so both seats and `apply` use the same snapshot.

`choose` shows the default ladder, waits for Enter or picks, and records the
result in the state file S. `apply` turns the state into a plan and sends it
through the proxy's existing no-restart path, POST /workbench/reload_runtime
with scope "ladder". The proxy is keyless and accepts that call from loopback
only, so no key is sent. If LITELLM_MASTER_KEY happens to be set, it is sent
as a bearer token (a keyed proxy needs it) and never printed.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import inputs as I  # noqa: E402
import ladder as L  # noqa: E402

DEFAULT_API_BASE = "https://api.inferhub.dev/v1"


def log(m):
    print(m, file=sys.stderr, flush=True)


def load_json(p: Path, default=None):
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def save_json(p: Path, obj):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(obj, indent=2) + "\n", encoding="utf-8")


def get_inputs(a, st=None):
    if st is not None and st.get("inputs"):
        return st["inputs"]
    b = I.load_inputs(getattr(a, "bundle", None), use_ire=not getattr(a, "no_ire", False))
    if st is not None:
        st["inputs"] = b
    return b


def cmd_catalog(a):
    b = get_inputs(a)
    print(json.dumps(L.catalog(b), indent=2))
    return 0


def cmd_choose(a):
    st = load_json(a.state, {}) or {}
    b = get_inputs(a, st)
    primary = a.primary.strip() or None
    other = "advisor" if a.role == "main" else "main"
    blocked = []
    if not a.allow_shared_vendors and st.get(other):
        o = st[other]
        rungs = o.get("fallbacks") or []
        if o.get("source") == "default":
            # those rungs will yield to this seat's primary vendor (see below)
            rungs = [r for r in rungs if L.prefix(r) != L.prefix(primary)]
        blocked = [L.prefix(o.get("primary"))] + [L.prefix(r) for r in rungs]
    if a.role == "advisor" and not primary:
        st["advisor"] = {"primary": None, "fallbacks": [], "source": "off"}
        log("Advisor OFF: advisor aliases follow the main seat and its ladder.")
        save_json(a.state, st)
        return 0
    if a.picks is not None:
        picks = [r.strip() for r in a.picks.split(",") if r.strip()]
        probs = L.validate_picks(b, primary, picks)
        if probs:
            for pr in probs:
                log(f"can't use that: {pr}")
            return 2
        res = {"fallbacks": picks, "source": "picked" if picks else "none"}
    elif a.non_interactive:
        res = {"fallbacks": L.default_ladder(b, a.role, primary, () if a.allow_shared_vendors else blocked),
               "source": "default"}
    else:
        res = L.prompt_ladder(b, a.role, primary, blocked, allow_shared=a.allow_shared_vendors, which=a.list)
    st[a.role] = {"primary": primary, **res}
    # The other seat's default rungs yield to this seat's primary vendor.
    if not a.allow_shared_vendors and st.get(other, {}).get("source") == "default":
        kept, dropped = L.prune_for_other_seat(st[other]["fallbacks"], [L.prefix(primary)])
        if dropped:
            st[other]["fallbacks"] = kept
            log(f"Note: dropped {', '.join(dropped)} from the {other} ladder because the {a.role} seat "
                f"uses '{L.prefix(primary)}/'. Run with --allow-shared-vendors to keep it.")
    elif st.get(other) and st[other].get("source") == "picked":
        shared = [r for r in st[other]["fallbacks"] if L.prefix(r) == L.prefix(primary)]
        if shared and not a.allow_shared_vendors:
            log(f"Warning: your hand-picked {other} ladder shares '{L.prefix(primary)}/' with this seat: {shared}")
    save_json(a.state, st)
    log(f"{a.role} ladder: {primary} > " + (" > ".join(st[a.role]['fallbacks']) or "(no fallbacks)"))
    return 0


def cmd_primary(a):
    b = get_inputs(a)
    row = L.prompt_primary(b, a.role, allow_off=a.allow_off, which=a.list)
    if row is None:
        return 2
    text = f"{row['id']}\t{row.get('name') or row['id']}\n"
    if a.out:
        a.out.parent.mkdir(parents=True, exist_ok=True)
        a.out.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


RELOAD_PATH = "/workbench/reload_runtime"


def _req(url, method="GET", body=None, timeout=10.0):
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    key = os.environ.get("LITELLM_MASTER_KEY")
    if key:
        headers["Authorization"] = f"Bearer {key}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"raw": raw.decode("utf-8", "replace")[:300]}


def cmd_apply(a):
    st = load_json(a.state, {}) or {}
    m = st.get("main")
    if not m:
        log("ERROR: no main seat in state; run `choose --role main` first")
        return 2
    adv = st.get("advisor") or {"primary": None, "fallbacks": []}
    # CCL_RETRIES / CCL_COOLDOWN_S at apply time win over the snapshot in the state file
    retry = I.retry_settings((st.get("inputs") or {}).get("retry"))
    plan = L.build_plan(m["primary"], m["fallbacks"], adv.get("primary"), adv.get("fallbacks") or [],
                        a.api_base, retries=int(retry["retries"]), cooldown=float(retry["cooldown_seconds"]))
    save_json(a.state.with_name("ladder-plan.json"), plan)
    url = a.base_url.rstrip("/") + RELOAD_PATH
    try:
        status, res = _req(url, "POST", {"scope": "ladder", "plan": plan})
    except (urllib.error.URLError, OSError) as e:
        log(f"Proxy not reachable at {a.base_url} ({getattr(e, 'reason', e)}). Ladder saved to the plan "
            f"file; apply it after the proxy is up.")
        return 3
    if status == 404 or (status == 400 and "scope" in json.dumps(res)):
        log("This proxy's reload endpoint has no ladder scope (or is missing). Start it from "
            "shared/litellm so its sitecustomize loads; later changes then apply live.")
        return 4
    if status != 200:
        log(f"Apply failed: HTTP {status}: {res}")
        return 5
    log(f"Applied to {a.base_url} without restart: rungs={res.get('upserted')} "
        f"fallbacks_set={res.get('fallbacks_set')} allowed_fails_policy_set={res.get('allowed_fails_policy_set')}")
    status, cur = _req(url, "POST", {"scope": "ladder"})
    fb = {k: v for d in (cur.get("state") or {}).get("fallbacks") or [] for k, v in d.items()}
    for names in (L.MAIN_NAMES, L.ADVISOR_NAMES):
        log(f"  proxy now: {names[1]} -> {fb.get(names[1], [])}")
    return 0


def cmd_show(a):
    status, cur = _req(a.base_url.rstrip("/") + RELOAD_PATH, "POST", {"scope": "ladder"})
    print(json.dumps(cur, indent=2))
    return 0 if status == 200 else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    c = sp.add_parser("catalog")
    c.add_argument("--bundle", type=Path, default=None)
    c.add_argument("--no-ire", action="store_true")
    c = sp.add_parser("choose")
    c.add_argument("--bundle", type=Path, default=None, help="IRE bundle JSON (optional)")
    c.add_argument("--no-ire", action="store_true", help="skip the IRE module; use built-in chains")
    c.add_argument("--state", type=Path, required=True)
    c.add_argument("--role", choices=("main", "advisor"), required=True)
    c.add_argument("--primary", required=True)
    c.add_argument("--allow-shared-vendors", action="store_true",
                   help="let the DEFAULT ladder share vendors too (hand picks always may)")
    c.add_argument("--list", choices=L.LISTS, default="top20", help="list shown first for hand picks")
    c.add_argument("--non-interactive", action="store_true", help="take the default ladder without asking")
    c.add_argument("--picks", default=None,
                   help="comma-separated hand-picked fallbacks (up to 3); skips the prompt")
    c = sp.add_parser("primary")
    c.add_argument("--bundle", type=Path, default=None)
    c.add_argument("--no-ire", action="store_true")
    c.add_argument("--role", choices=("main", "advisor"), required=True)
    c.add_argument("--allow-off", action="store_true")
    c.add_argument("--list", choices=L.LISTS, default="frontier")
    c.add_argument("--out", type=Path, default=None)
    c = sp.add_parser("apply")
    c.add_argument("--state", type=Path, required=True)
    c.add_argument("--base-url", default="http://127.0.0.1:4000")
    c.add_argument("--api-base", default=DEFAULT_API_BASE)
    c = sp.add_parser("show")
    c.add_argument("--base-url", default="http://127.0.0.1:4000")
    a = ap.parse_args(argv)
    return {"catalog": cmd_catalog, "choose": cmd_choose, "apply": cmd_apply, "show": cmd_show,
            "primary": cmd_primary}[a.cmd](a)


if __name__ == "__main__":
    raise SystemExit(main())
