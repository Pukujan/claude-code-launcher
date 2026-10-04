"""Bench a model once it has used up its retries, so later requests skip it.

Why this exists (LiteLLM 1.103.0, checked in router.py, cooldown_handlers.py and
litellm_core_utils/litellm_logging.py):

The router benches a deployment from its failure callback,
Router.deployment_callback_on_failure, which counts failures against
allowed_fails / allowed_fails_policy. On the proxy every request carries one
Logging object (litellm_logging_obj) that all retries of that request share,
and Logging.failure_handler runs once per object (should_run_logging checks
model_call_details["has_logged_sync_failure"]). So a request that fails
1 + 3 retries counts as ONE failure, logged after the first attempt. With
allowed fails 3, a primary is benched only after 4 failed requests inside
the counter's TTL (the cooldown time), which in practice never happens:
every request kept hitting the dead primary 4 times. Setting allowed fails
to 0 doesn't help either: the bench would then land after the first attempt
and cut the retries short.

The fix: when the router gives up on a model group and moves to a fallback
(that only happens after the group's retries are used up), put that group's
deployments in cooldown for their own cooldown_time. LiteLLM's fallback
events (CustomLogger.log_success_fallback_event / log_failure_fallback_event)
fire exactly then. Only deployments that carry cooldown_time in model_info
(the launcher's seat aliases and ladder rungs) are touched, only for errors
LiteLLM itself would cool down for (429, 401, 404, 408, 5xx), and a group
that is already benched is left alone, so its bench isn't extended and the
first model comes back on time.

Standard library plus litellm; imported lazily by sitecustomize.py.
"""
from __future__ import annotations

_installed = {"done": False}


def _status(exc) -> int | None:
    for attr in ("status_code", "code"):
        v = getattr(exc, attr, None)
        try:
            return int(v)
        except (TypeError, ValueError):
            continue
    return None


# The router's own "every deployment of this group is benched" error. It says nothing
# new about the upstream, so it never benches anything (issue #53).
_ROUTER_NO_DEPLOYMENTS = ("No deployments available", "RouterRateLimitError")


def should_bench(exc) -> bool:
    """Same rule as LiteLLM's _is_cooldown_required: 429/401/404/408 and 5xx bench,
    other 4xx (bad request, context window) do not; connection errors never do.
    Empty replies (request_fixes.py) and the router's own no-deployments error never do."""
    if exc is None or "APIConnectionError" in type(exc).__name__ or "APIConnectionError" in str(exc)[:200]:
        return False
    if getattr(exc, "ccl_empty_reply", False) or "empty reply (no text, no tool call)" in str(exc)[:300]:
        return False
    if any(m in type(exc).__name__ or m in str(exc)[:300] for m in _ROUTER_NO_DEPLOYMENTS):
        return False
    s = _status(exc)
    if s is None:
        return True
    if 400 <= s < 500:
        return s in (429, 401, 404, 408)
    return s >= 500


def _managed_deployments(router, group: str) -> list:
    """(id, cooldown_time) for deployments of *group* that opted in via model_info.cooldown_time."""
    out = []
    for d in getattr(router, "model_list", None) or []:
        if d.get("model_name") != group:
            continue
        mi = d.get("model_info") or {}
        cd = mi.get("cooldown_time")
        if cd is None:
            cd = (d.get("litellm_params") or {}).get("cooldown_time")
        if mi.get("id") and cd is not None and float(cd) > 0:
            out.append((mi["id"], float(cd)))
    return out


def _is_benched(router, model_id: str) -> bool:
    cc = getattr(router, "cooldown_cache", None)
    if cc is None:
        return False
    try:
        key = cc.get_cooldown_cache_key(model_id)
        return cc.cooldown_store.get_cache(key=key) is not None
    except Exception:
        return False


def bench_group(router, group: str | None, exc) -> list:
    """Put *group*'s managed deployments in cooldown. Returns the ids benched."""
    if router is None or not group or getattr(router, "disable_cooldowns", False) or not should_bench(exc):
        return []
    deps = _managed_deployments(router, group)
    if not deps or any(_is_benched(router, i) for i, _ in deps):
        return []
    status = _status(exc) or 500
    benched = []
    for model_id, cd in deps:
        router.cooldown_cache.add_deployment_to_cooldown(
            model_id=model_id, original_exception=exc, exception_status=status, cooldown_time=cd)
        benched.append(model_id)
    if benched:
        print(f"[bench] {group} used up its retries ({type(exc).__name__}); benched for {deps[0][1]:g} s",
              flush=True)
    return benched


def _router():
    try:
        from litellm.proxy import proxy_server as ps
        return getattr(ps, "llm_router", None)
    except Exception:
        return None


def make_logger(get_router=_router):
    from litellm.integrations.custom_logger import CustomLogger

    class BenchAfterRetries(CustomLogger):
        """Fallback events fire only after the failed group's retries are used up."""

        async def log_success_fallback_event(self, original_model_group, kwargs, original_exception):
            bench_group(get_router(), original_model_group, original_exception)

        async def log_failure_fallback_event(self, original_model_group, kwargs, original_exception):
            r = get_router()
            bench_group(r, original_model_group, original_exception)
            # the rung that was just tried failed its own retries as well
            hop = (kwargs or {}).get("model")
            if isinstance(hop, str) and hop != original_model_group:
                bench_group(r, hop, (kwargs or {}).get("exception") or original_exception)

    return BenchAfterRetries()


def install() -> bool:
    """Register once in litellm.callbacks. Safe to call on every request."""
    if _installed["done"]:
        return True
    try:
        import litellm
    except Exception:
        return False
    if not any(type(c).__name__ == "BenchAfterRetries" for c in (litellm.callbacks or [])):
        logger = make_logger()
        mgr = getattr(litellm, "logging_callback_manager", None)
        if mgr is not None and hasattr(mgr, "add_litellm_callback"):
            mgr.add_litellm_callback(logger)
        else:
            litellm.callbacks.append(logger)
        print("[bench] bench-after-retries hook installed", flush=True)
    _installed["done"] = True
    return True
