"""Apply a fallback-ladder plan to a running LiteLLM router, in memory.

Called by the proxy's existing no-restart path, POST /workbench/reload_runtime
with {"scope": "ladder", "plan": {...}} (see shared/litellm/sitecustomize.py).
LiteLLM's own admin routes for fallbacks and models (/fallback, /model/new,
/config/update) need a database, and this proxy runs without one and without
a master key, so they are not usable here.

What it changes: the ih/<route> rung deployments it is given (added or
replaced), the fallback list for each seat alias it is given, the retry
policy for those aliases, and a per-deployment cooldown on the seat aliases
and the rungs. It never changes which model a seat alias points to.
"""
from __future__ import annotations

import copy
import os

_state = {"last_plan": None}


def _resolve(params: dict) -> dict:
    out = dict(params)
    for k, v in list(out.items()):
        if isinstance(v, str) and v.startswith("os.environ/"):
            out[k] = os.environ.get(v.split("/", 1)[1])
    return out


def _supports_deployment_policy() -> bool:
    try:
        from litellm.router_utils import cooldown_handlers as ch
        return hasattr(ch, "_should_cooldown_based_on_deployment_policy")
    except Exception:
        return False


def _deployments(router, name):
    return [d for d in (router.model_list or []) if d.get("model_name") == name]


def apply_plan(router, plan: dict) -> dict:
    from litellm.types.router import Deployment, LiteLLM_Params, ModelInfo
    from litellm.types.router import RetryPolicy

    cd = plan.get("cooldown") or {}
    cooldown = float(cd.get("cooldown_time", 180))
    afp = cd.get("allowed_fails_policy") if isinstance(cd.get("allowed_fails_policy"), dict) else None
    per_dep = _supports_deployment_policy()
    upserted, patched = [], []
    for raw in plan.get("deployments") or []:
        d = copy.deepcopy(raw)
        name = d["model_name"]
        params = _resolve(d.get("litellm_params") or {})
        info = dict(d.get("model_info") or {})
        if per_dep:
            info["cooldown_time"] = cooldown  # router-internal, never sent upstream
        else:
            params["cooldown_time"] = cooldown
        if afp and per_dep:
            info["allowed_fails_policy"] = dict(afp)
        existing = list(router.get_model_ids(model_name=name) or [])
        for extra in existing[1:]:
            router.delete_deployment(id=extra)
        if existing:
            info["id"] = existing[0]
        router.upsert_deployment(Deployment(model_name=name, litellm_params=LiteLLM_Params(**params),
                                            model_info=ModelInfo(**info)))
        upserted.append(name)

    fallbacks = plan.get("fallbacks") or {}
    # Seat aliases keep their target; only their cooldown is set so a failing
    # primary is skipped for the cooldown window.
    for name in fallbacks:
        for d in _deployments(router, name):
            if per_dep:
                mi = d.setdefault("model_info", {})
                mi["cooldown_time"] = cooldown
                if afp:
                    mi["allowed_fails_policy"] = dict(afp)
            else:
                d.setdefault("litellm_params", {})["cooldown_time"] = cooldown
            patched.append(name)

    names = set(fallbacks)
    kept = [f for f in (router.fallbacks or []) if isinstance(f, dict) and not (set(f) & names)]
    new = [{n: list(t)} for n, t in fallbacks.items() if t]
    router.update_settings(fallbacks=kept + new)

    pol = plan.get("retry_policy")
    if isinstance(pol, dict):
        mgrp = dict(getattr(router, "model_group_retry_policy", None) or {})
        for n in names:
            mgrp[n] = RetryPolicy(**pol)
        router.update_settings(model_group_retry_policy=mgrp)

    # LiteLLM only benches a single-deployment group when an allowed-fails
    # policy covers the error. Newer builds read it per deployment (set above,
    # nothing else is affected). Older builds only have the router-wide policy;
    # set that only if the router has none, so an operator's policy is kept.
    afp_set = "per-deployment" if (afp and per_dep) else False
    if afp and not per_dep and getattr(router, "allowed_fails_policy", None) is None:
        from litellm.types.router import AllowedFailsPolicy
        router.allowed_fails_policy = AllowedFailsPolicy(**afp)
        afp_set = "router-wide"

    _state["last_plan"] = {"seats": plan.get("seats"), "fallbacks": fallbacks}
    try:
        from litellm.proxy import proxy_server as ps
        ps.llm_model_list = router.get_model_list()
    except Exception:
        pass
    return {"ok": True, "upserted": upserted, "seat_cooldown_patched": sorted(set(patched)),
            "fallbacks_set": len(new), "allowed_fails_policy_set": afp_set}


def read_state(router) -> dict:
    pol = getattr(router, "model_group_retry_policy", None) or {}
    return {
        "fallbacks": router.fallbacks or [],
        "retry_policy": {k: (v.model_dump() if hasattr(v, "model_dump") else v) for k, v in pol.items()},
        "rungs": sorted({d.get("model_name") for d in (router.model_list or [])
                         if str(d.get("model_name", "")).startswith("ih/")}),
        "allowed_fails_policy": (router.allowed_fails_policy.model_dump()
                                 if getattr(router, "allowed_fails_policy", None) is not None else None),
        "cooldown": {d.get("model_name"): (d.get("model_info") or {}).get("cooldown_time",
                     (d.get("litellm_params") or {}).get("cooldown_time"))
                     for d in (router.model_list or []) if d.get("model_name") in {"sonnet", "opus"}
                     or str(d.get("model_name", "")).startswith("ih/")},
        "last_plan": _state["last_plan"],
    }
