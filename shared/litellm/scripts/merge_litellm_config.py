#!/usr/bin/env python3
"""Merge config.yaml + the InferHub fragments into config/runtime.yaml.

ONE local proxy serves both groups. CKFF is OFF by default (since 2026-10-04;
see config/providers.yaml / LITELLM_ENABLE_CKFF). When it is off, no CKFF
deployments are written and every router reference to a CKFF model is dropped.
When it is on, CKFF entries keep their model_names;
InferHub uses ih/ prefix plus Claude seat aliases (sonnet/opus/main/advisor/ih-*).

After writing, optionally hot-reload the running proxy via
POST /workbench/reload_runtime (scope=all). Use --no-reload when the proxy
is not expected to be up.
"""
from __future__ import annotations

import argparse
import datetime as dt
import os
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML required (pip install pyyaml)", file=sys.stderr)
    raise SystemExit(1)

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import provider_switch  # noqa: E402
import slots  # noqa: E402

_ROUTER_FALLBACK_KEYS = ("fallbacks", "context_window_fallbacks", "content_policy_fallbacks")


def apply_master_key_setting(general_settings: dict | None, env: dict | None = None) -> dict:
    """Keep master_key only when LITELLM_MASTER_KEY is set.

    With no key the proxy runs keyless (start-litellm.ps1 then binds 127.0.0.1
    only), so runtime.yaml must not point at an empty environment variable.
    """
    env = os.environ if env is None else env
    gs = dict(general_settings or {})
    if (env.get("LITELLM_MASTER_KEY") or "").strip():
        gs.setdefault("master_key", "os.environ/LITELLM_MASTER_KEY")
    else:
        gs.pop("master_key", None)
    return gs


def apply_web_search(merged: dict) -> dict:
    """Make Claude Code's WebSearch work on non-Anthropic models.

    Its WebSearch sends Anthropic's server-side web_search tool, which only
    Anthropic runs. websearch_interception turns it into a normal tool and runs
    the search in the proxy; duckduckgo needs no key (sitecustomize sends it
    through ddgs, see web_search.py). Anything already in config.yaml wins.
    """
    ls = dict(merged.get("litellm_settings") or {})
    cbs = list(ls.get("callbacks") or [])
    if "websearch_interception" not in cbs:
        cbs.append("websearch_interception")
    ls["callbacks"] = cbs
    ls.setdefault("websearch_interception_params", {"enabled_providers": ["openai"]})
    merged["litellm_settings"] = ls
    if not merged.get("search_tools"):
        merged["search_tools"] = [{"search_tool_name": "web", "litellm_params": {"search_provider": "duckduckgo"}}]
    return merged


def prune_router_refs(router_settings: dict | None, served: set) -> dict:
    """Drop fallback entries/targets and aliases that point at models we no longer serve."""
    rs = dict(router_settings or {})
    for key in _ROUTER_FALLBACK_KEYS:
        chains = rs.get(key)
        if not isinstance(chains, list):
            continue
        kept = []
        for item in chains:
            if not isinstance(item, dict):
                continue
            new_item = {}
            for src, targets in item.items():
                if src not in served:
                    continue
                tlist = [t for t in (targets or []) if t in served]
                if tlist:
                    new_item[src] = tlist
            if new_item:
                kept.append(new_item)
        if kept:
            rs[key] = kept
        else:
            rs.pop(key, None)
    for key in ("default_fallbacks",):
        if isinstance(rs.get(key), list):
            rs[key] = [t for t in rs[key] if t in served]
            if not rs[key]:
                rs.pop(key)
    if isinstance(rs.get("model_group_alias"), dict):
        rs["model_group_alias"] = {
            k: v for k, v in rs["model_group_alias"].items()
            if (v if isinstance(v, str) else (v or {}).get("model")) in served
        }
        if not rs["model_group_alias"]:
            rs.pop("model_group_alias")
    return rs


def load_models(path: Path) -> list:
    if not path.is_file():
        return []
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    models = data.get("model_list") or []
    if not isinstance(models, list):
        raise SystemExit(f"model_list must be a list in {path}")
    return models


def build_inferhub_fallbacks(path: Path, ih_models: list, max_default: float = 0.10) -> list:
    """Generate role-aware router fallbacks for Claude seat aliases (issue #36).

    config/inferhub_fallbacks.yaml defines models (vendor/cost/eligible) and roles
    (names + ordered chain). The seated model is removed from its own chain; main-role
    chains drop the seated advisor's vendor and advisor-role chains drop the seated
    main's vendor; ineligible or over-cap models are skipped; only existing ih/ targets
    are emitted.
    """
    if not path.is_file():
        return []
    doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    cap = float(doc.get("max_cost_per_mtok", max_default))
    models = doc.get("models") or {}
    roles = doc.get("roles") or {}

    def vendor(mid):
        return (models.get(mid) or {}).get("vendor") or mid.split("/", 1)[0]

    def ok(mid):
        m = models.get(mid) or {}
        return bool(m.get("eligible")) and m.get("cost_per_mtok") is not None and float(m["cost_per_mtok"]) <= cap

    by_name = {}
    for m in ih_models:
        if isinstance(m, dict) and m.get("model_name"):
            raw = str((m.get("litellm_params") or {}).get("model") or "")
            for pre in ("openai/responses/", "openai/"):  # cx/ seats use Responses mode
                if raw.startswith(pre):
                    raw = raw[len(pre):]
                    break
            by_name[m["model_name"]] = raw

    def seated(role):
        for n in (roles.get(role) or {}).get("names") or []:
            if n in by_name:
                return by_name[n]
        return None

    main_seat, adv_seat = seated("main"), seated("advisor")
    avoid = {
        "main": {vendor(adv_seat)} if adv_seat else set(),
        "advisor": {vendor(main_seat)} if main_seat else set(),
    }
    out = []
    for role, spec in roles.items():
        chain = [c for c in (spec or {}).get("chain") or [] if ok(c)]
        for name in (spec or {}).get("names") or []:
            if name not in by_name:
                continue
            seat = by_name[name]
            targets = [
                f"ih/{c}" for c in chain
                if c != seat and vendor(c) not in avoid.get(role, set()) and f"ih/{c}" in by_name
            ]
            if targets:
                out.append({name: targets})
    return out


TRANSIENT = ("RateLimitError", "InternalServerError", "ServiceUnavailableError")


def _env_int(name, lo, hi):
    raw = os.environ.get(name, "").strip()
    if not raw:
        return None
    try:
        v = int(raw)
    except ValueError:
        v = None
    if v is None or not lo <= v <= hi:
        print(f"warning: ignoring {name}={raw!r} (want a whole number {lo}-{hi})", file=sys.stderr)
        return None
    return v


def apply_env_overrides(pol, cd):
    """CCL_RETRIES sets the retries for transient errors (rate limit, 5xx) and the
    allowed fails that bench a model, so a model is benched by the failure that
    uses up its last retry. CCL_COOLDOWN_S sets the bench time in seconds."""
    pol = dict(pol) if isinstance(pol, dict) else pol
    cd = dict(cd) if isinstance(cd, dict) else cd
    r = _env_int("CCL_RETRIES", 0, 10)
    c = _env_int("CCL_COOLDOWN_S", 1, 86400)
    if r is not None and isinstance(pol, dict):
        for k in TRANSIENT:
            pol[f"{k}Retries"] = r
    if isinstance(cd, dict):
        if r is not None and isinstance(cd.get("allowed_fails_policy"), dict):
            afp = dict(cd["allowed_fails_policy"])
            for k in TRANSIENT + ("BadGatewayError",):
                afp[f"{k}AllowedFails"] = r
            cd["allowed_fails_policy"] = afp
        if c is not None:
            cd["cooldown_time"] = c
    return pol, cd


def slot_chains(models: list) -> dict:
    """{slot: {"names": [...], "rungs": [ccl-<slot>-2, ...], "last": name}} from the
    ccl_slot / ccl_rung tags apply_inferhub_seat.py writes into model_info."""
    out = {}
    for m in models:
        if not isinstance(m, dict):
            continue
        mi = m.get("model_info") or {}
        slot, rung = mi.get("ccl_slot"), mi.get("ccl_rung")
        if slot not in slots.SLOTS or rung is None:
            continue
        d = out.setdefault(slot, {"names": [], "rungs": {}, "last": None})
        if int(rung) == 1:
            d["names"].append(m["model_name"])
        else:
            d["rungs"][int(rung)] = m["model_name"]
        if mi.get("ccl_last"):
            d["last"] = m["model_name"]
    for d in out.values():
        d["rungs"] = [d["rungs"][k] for k in sorted(d["rungs"])]
    return out


def slot_fallbacks(chains: dict) -> list:
    """Every slot name falls back to its own slot's rungs, in order."""
    return [{name: list(d["rungs"])} for d in chains.values() if d["rungs"] for name in d["names"]]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ckff", type=Path, default=ROOT / "config" / "config.yaml")
    ap.add_argument("--inferhub-top20", type=Path, default=ROOT / "config" / "inferhub_top20.yaml")
    ap.add_argument("--inferhub-aliases", type=Path, default=ROOT / "config" / "inferhub_aliases.yaml")
    ap.add_argument("--inferhub-fallbacks", type=Path, default=ROOT / "config" / "inferhub_fallbacks.yaml")
    ap.add_argument("--out", type=Path, default=ROOT / "config" / "runtime.yaml")
    ap.add_argument("--reload", dest="reload", action="store_true", default=True,
                    help="Hot-reload running proxy from runtime.yaml (default)")
    ap.add_argument("--no-reload", dest="reload", action="store_false",
                    help="Skip live reload")
    ap.add_argument("--base-url", default=None, help="Proxy base URL for reload")
    args = ap.parse_args()

    if not args.ckff.is_file():
        print(f"ERROR: missing CKFF config {args.ckff}", file=sys.stderr)
        return 1

    ckff_doc = yaml.safe_load(args.ckff.read_text(encoding="utf-8")) or {}
    merged = dict(ckff_doc)
    ckff_on = provider_switch.ckff_enabled()
    if ckff_on:
        ckff_models = list(ckff_doc.get("model_list") or [])
    else:
        # Keep general/litellm/router settings from config.yaml, but serve no CKFF models.
        ckff_models = []
        print("note: CKFF is disabled (config/providers.yaml or LITELLM_ENABLE_CKFF); serving InferHub only")
    ih_top = load_models(args.inferhub_top20)
    ih_alias = load_models(args.inferhub_aliases)

    ckff_names = {m.get("model_name") for m in ckff_models if isinstance(m, dict)}
    collisions = []
    for m in ih_top + ih_alias:
        n = m.get("model_name") if isinstance(m, dict) else None
        if n in ckff_names:
            collisions.append(n)
    if collisions:
        print("ERROR: InferHub model_name collides with CKFF: " + ", ".join(sorted(set(collisions))), file=sys.stderr)
        return 1

    merged["model_list"] = ckff_models + ih_top + ih_alias
    if not ckff_on:
        leaked = [m.get("model_name") for m in merged["model_list"] if provider_switch.is_ckff_deployment(m)]
        if leaked:
            print("ERROR: CKFF is off but these entries still route to CKFF: " + ", ".join(map(str, leaked)),
                  file=sys.stderr)
            return 1

    chains = slot_chains(ih_alias)
    slot_fb = slot_fallbacks(chains)
    ih_fallbacks = build_inferhub_fallbacks(args.inferhub_fallbacks, ih_top + ih_alias)
    slot_named = {k for d in slot_fb for k in d}
    ih_fallbacks = [d for d in ih_fallbacks if not (set(d) & slot_named)] + slot_fb
    last_rungs = {d["last"] for d in chains.values() if d["last"]}
    if ih_fallbacks or chains:
        rs = dict(merged.get("router_settings") or {})
        generated = {k for d in ih_fallbacks for k in d}
        kept = [d for d in (rs.get("fallbacks") or []) if isinstance(d, dict) and not (set(d) & generated)]
        rs["fallbacks"] = kept + ih_fallbacks
        # A context-window or content-filter error on a slot walks the same chain.
        for key in ("context_window_fallbacks", "content_policy_fallbacks"):
            kept = [d for d in (rs.get(key) or []) if isinstance(d, dict) and not (set(d) & slot_named)]
            if kept or slot_fb:
                rs[key] = kept + [dict(d) for d in slot_fb]
        fb_doc = yaml.safe_load(args.inferhub_fallbacks.read_text(encoding="utf-8")) or {}
        pol, cd = apply_env_overrides(fb_doc.get("retry_policy"), fb_doc.get("cooldown"))
        targets = set(generated) | {t for d in ih_fallbacks for v in d.values() for t in v}
        for d in chains.values():
            targets |= set(d["names"]) | set(d["rungs"])
        if isinstance(pol, dict):
            mgrp = dict(rs.get("model_group_retry_policy") or {})
            # every slot name, slot fallback and chain target gets the same retries
            for name in targets:
                mgrp[name] = dict(pol)
            rs["model_group_retry_policy"] = mgrp
        merged["router_settings"] = rs
        # Per-deployment benching (cooldown_time + allowed_fails_policy in model_info, which
        # stays router-internal and is not sent upstream). The last model of a slot chain
        # gets cooldown_time 0: LiteLLM and bench_after_retries.py then never bench it, so
        # a chain can't turn into "all deployments in cooldown" 429s.
        if isinstance(cd, dict):
            for m in ih_top + ih_alias:
                if not isinstance(m, dict) or m.get("model_name") not in targets:
                    continue
                mi = dict(m.get("model_info") or {})
                if m.get("model_name") in last_rungs or ((mi.get("ccl_rung") == 1) and mi.get("ccl_last")):
                    mi["cooldown_time"] = 0.0
                    mi.pop("allowed_fails_policy", None)
                else:
                    if cd.get("cooldown_time") is not None:
                        mi["cooldown_time"] = float(cd["cooldown_time"])
                    if isinstance(cd.get("allowed_fails_policy"), dict):
                        mi["allowed_fails_policy"] = dict(cd["allowed_fails_policy"])
                m["model_info"] = mi
        for s_, d in chains.items():
            print(f"note: slot {s_}: {len(d['names'])} names -> " + " -> ".join(["first", *d["rungs"]])
                  + f" (never benched: {d['last']})")

    if not ckff_on:
        served = {m.get("model_name") for m in merged["model_list"] if isinstance(m, dict)}
        merged["router_settings"] = prune_router_refs(merged.get("router_settings"), served)

    apply_web_search(merged)
    merged["general_settings"] = apply_master_key_setting(merged.get("general_settings"))
    if "master_key" not in merged["general_settings"]:
        print("note: LITELLM_MASTER_KEY not set; runtime.yaml has no master_key (keyless, 127.0.0.1 only)")

    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    header = (
        f"# GENERATED by scripts/merge_litellm_config.py at {now}\n"
        f"# Sources: {args.ckff.name} + {args.inferhub_top20.name} + {args.inferhub_aliases.name} + {args.inferhub_fallbacks.name}\n"
        f"# Local-only unified proxy ({'CKFF + InferHub' if ckff_on else 'InferHub only; CKFF off'}). Do not hand-edit.\n"
    )
    args.out.parent.mkdir(parents=True, exist_ok=True)
    body = yaml.safe_dump(merged, sort_keys=False, allow_unicode=True)
    args.out.write_text(header + body, encoding="utf-8")
    print(
        f"Wrote {args.out} "
        f"(ckff={'on' if ckff_on else 'off'}:{len(ckff_models)} ih_top20={len(ih_top)} ih_aliases={len(ih_alias)} "
        f"total={len(merged['model_list'])})"
    )

    if args.reload:
        reload_args = ["--scope", "all"]
        if args.base_url:
            reload_args.extend(["--base-url", args.base_url])
        cmd = [sys.executable, str(ROOT / "scripts" / "reload_runtime.py"), *reload_args]
        print(f"+ {' '.join(cmd)}")
        rc = subprocess.call(cmd)
        if rc != 0:
            return rc

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
