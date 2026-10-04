#!/usr/bin/env python3
"""Merge CKFF config.yaml + InferHub fragments into config/runtime.yaml.

ONE local proxy serves both groups. CKFF entries keep their model_names;
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
    ckff_models = list(ckff_doc.get("model_list") or [])
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

    ih_fallbacks = build_inferhub_fallbacks(args.inferhub_fallbacks, ih_top + ih_alias)
    if ih_fallbacks:
        rs = dict(merged.get("router_settings") or {})
        generated = {k for d in ih_fallbacks for k in d}
        kept = [d for d in (rs.get("fallbacks") or []) if isinstance(d, dict) and not (set(d) & generated)]
        rs["fallbacks"] = kept + ih_fallbacks
        # Fail over fast on seat names: InferHub 402 no_provider_under_bid / 5xx are not
        # transient within seconds, so 1 retry then fall back (issue #36).
        fb_doc = yaml.safe_load(args.inferhub_fallbacks.read_text(encoding="utf-8")) or {}
        pol, cd = apply_env_overrides(fb_doc.get("retry_policy"), fb_doc.get("cooldown"))
        targets = set(generated) | {t for d in ih_fallbacks for v in d.values() for t in v}
        if isinstance(pol, dict):
            mgrp = dict(rs.get("model_group_retry_policy") or {})
            # every seat name and every chain target gets the same retries
            for name in targets:
                mgrp[name] = dict(pol)
            rs["model_group_retry_policy"] = mgrp
        merged["router_settings"] = rs
        # Per-deployment benching (cooldown_time + allowed_fails_policy in model_info, which
        # stays router-internal and is not sent upstream).
        if isinstance(cd, dict):
            for m in ih_top + ih_alias:
                if isinstance(m, dict) and m.get("model_name") in targets:
                    mi = dict(m.get("model_info") or {})
                    if cd.get("cooldown_time") is not None:
                        mi["cooldown_time"] = float(cd["cooldown_time"])
                    if isinstance(cd.get("allowed_fails_policy"), dict):
                        mi["allowed_fails_policy"] = dict(cd["allowed_fails_policy"])
                    m["model_info"] = mi

    gs = dict(merged.get("general_settings") or {})
    gs.setdefault("master_key", "os.environ/LITELLM_MASTER_KEY")
    merged["general_settings"] = gs

    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    header = (
        f"# GENERATED by scripts/merge_litellm_config.py at {now}\n"
        f"# Sources: {args.ckff.name} + {args.inferhub_top20.name} + {args.inferhub_aliases.name} + {args.inferhub_fallbacks.name}\n"
        f"# Local-only unified proxy (CKFF + InferHub). Do not hand-edit.\n"
    )
    args.out.parent.mkdir(parents=True, exist_ok=True)
    body = yaml.safe_dump(merged, sort_keys=False, allow_unicode=True)
    args.out.write_text(header + body, encoding="utf-8")
    print(
        f"Wrote {args.out} "
        f"(ckff={len(ckff_models)} ih_top20={len(ih_top)} ih_aliases={len(ih_alias)} "
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
