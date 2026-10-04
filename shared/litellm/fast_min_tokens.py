"""Give the fast seat enough max_tokens to finish thinking and still answer.

Claude Code sends WebFetch page summaries (and other background calls) to the
fast seat with a small max_tokens. On reasoning models the thinking can use the
whole budget, so the reply came back empty. This raises max_tokens to a floor
for the fast aliases only, before the request leaves the proxy. A request that
already asks for more is left alone. CCL_FAST_MIN_MAX_TOKENS sets the floor
(default 4096; 0 turns it off).

Standard library plus litellm; imported lazily by sitecustomize.py.
"""
from __future__ import annotations

import os

# Same names as FAST_ALIASES in scripts/apply_inferhub_seat.py.
FAST_ALIASES = {"haiku", "claude-haiku-5", "claude-haiku-4-5-20251001", "small-fast", "ih-haiku", "ih-small-fast", "inferhub-haiku"}
DEFAULT_FLOOR = 4096

_installed = {"done": False}


def floor_from_env(env=None) -> int:
    raw = (env if env is not None else os.environ).get("CCL_FAST_MIN_MAX_TOKENS", "")
    try:
        return max(0, int(raw)) if str(raw).strip() else DEFAULT_FLOOR
    except ValueError:
        return DEFAULT_FLOOR


def apply_floor(data: dict, floor: int) -> dict:
    """Raise max_tokens (or max_completion_tokens) to *floor* for a fast-alias request."""
    if floor <= 0 or not isinstance(data, dict) or data.get("model") not in FAST_ALIASES:
        return data
    for key in ("max_tokens", "max_completion_tokens"):
        v = data.get(key)
        if isinstance(v, int) and v < floor:
            data[key] = floor
    return data


def make_logger():
    from litellm.integrations.custom_logger import CustomLogger

    class FastMinTokens(CustomLogger):
        async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
            return apply_floor(data, floor_from_env())

    return FastMinTokens()


def install() -> bool:
    """Register once in litellm.callbacks. Safe to call more than once."""
    if _installed["done"]:
        return True
    import litellm

    if floor_from_env() > 0 and not any(type(c).__name__ == "FastMinTokens" for c in (litellm.callbacks or [])):
        litellm.callbacks.append(make_logger())
        print(f"[sitecustomize] fast seat max_tokens floor {floor_from_env()} installed", flush=True)
    _installed["done"] = True
    return True
