"""Small request/response fixes for Claude Code traffic through the proxy.

1. Unknown claude-* ids. Claude Code sends whatever id it was told or defaults
   to (claude-opus-4-8, claude-sonnet-4-6, sonnet[1m], ...). A name the proxy
   does not serve is mapped explicitly to the slot of its family: sonnet, opus,
   haiku or fable (issue #53). A claude-* name of no known family still goes to
   sonnet so the request works, but with a loud WARNING line in the proxy log,
   because it means a call landed on a model nobody picked for it. Names the
   proxy already serves are left alone.
2. Dangling tool calls. When an assistant tool_use has no tool_result in the
   next user message (the user rejected it or the run was cut short), strict
   backends such as DeepSeek answer 400. A placeholder tool_result is added.
   Anthropic-format messages only.
3. Empty replies. A non-streaming reply with no text and no tool call is
   retried once on the same model, then handed to the next model in the chain.
   An empty reply says something about that request, not about the model's
   health, so it never benches the model (it used to become a 500 that benched
   the whole chain for 180 s, which then answered everything with 429s).
   Streaming replies are not checked (the content is not known until the
   stream has already started going to the client).

Standard library plus litellm; imported lazily by sitecustomize.py.
"""
from __future__ import annotations

import re
import time

MAIN = "sonnet"
PLACEHOLDER = "Tool call was rejected or not run."

# Claude model families -> the proxy's slot names (scripts/slots.py).
FAMILY_SLOT = {"sonnet": "sonnet", "opus": "opus", "haiku": "haiku", "fable": "fable"}
_FAMILY = re.compile(r"^claude-(?:\d+(?:[-.]\d+)*-)?(sonnet|opus|haiku|fable)\b")

_installed = {"done": False}


def catchall_model(model, served) -> str | None:
    """The name to use instead of *model*, or None to leave it alone."""
    new, _ = map_model(model, served)
    return new


def map_model(model, served) -> tuple[str | None, bool]:
    """(slot name to use or None, loud). loud=True means no family matched."""
    if not isinstance(model, str) or model in served:
        return None, False
    base = model[:-4] if model.endswith("[1m]") else model
    if base in served:
        return base, False
    if base in FAMILY_SLOT and FAMILY_SLOT[base] in served:
        return FAMILY_SLOT[base], False
    m = _FAMILY.match(base)
    if m and FAMILY_SLOT[m.group(1)] in served:
        return FAMILY_SLOT[m.group(1)], False
    if base.startswith("claude-") and MAIN in served:
        return MAIN, True
    return None, False


def add_missing_tool_results(messages):
    """Give every assistant tool_use a tool_result in the next user message."""
    if not isinstance(messages, list):
        return messages
    messages, out = list(messages), []
    for i, msg in enumerate(messages):
        out.append(msg)
        if not isinstance(msg, dict) or msg.get("role") != "assistant" or not isinstance(msg.get("content"), list):
            continue
        ids = [b.get("id") for b in msg["content"] if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("id")]
        if not ids:
            continue
        nxt = messages[i + 1] if i + 1 < len(messages) else None
        if isinstance(nxt, dict) and nxt.get("role") == "user":
            content = nxt.get("content")
            blocks = content if isinstance(content, list) else ([{"type": "text", "text": content}] if content else [])
            have = {b.get("tool_use_id") for b in blocks if isinstance(b, dict) and b.get("type") == "tool_result"}
            missing = [t for t in ids if t not in have]
            if missing:
                messages[i + 1] = dict(nxt, content=[_stand_in(t) for t in missing] + blocks)
        else:
            out.append({"role": "user", "content": [_stand_in(t) for t in ids]})
    return out


def _stand_in(tool_use_id):
    return {"type": "tool_result", "tool_use_id": tool_use_id, "content": PLACEHOLDER}


def _get(obj, key):
    return obj.get(key) if isinstance(obj, dict) else getattr(obj, key, None)


def is_empty_reply(response) -> bool:
    """True for a finished reply with no text and no tool call (chat or Anthropic format)."""
    choices = _get(response, "choices")
    if isinstance(choices, list) and choices:
        msg = _get(choices[0], "message")
        if msg is None:
            return False
        return not (_get(msg, "content") or "").strip() and not _get(msg, "tool_calls")
    content = _get(response, "content")
    if isinstance(content, list) and _get(response, "type") == "message":
        for b in content:
            t = _get(b, "type")
            if t in ("tool_use", "server_tool_use") or (t == "text" and (_get(b, "text") or "").strip()):
                return False
        return True
    return False


def _served():
    try:
        from litellm.proxy import proxy_server as ps
        r = getattr(ps, "llm_router", None)
        return set(r.get_model_names()) | set(r.model_group_alias or {}) if r else set()
    except Exception:
        return set()


class EmptyReply(Exception):
    """Mixin marking the error raised for an empty reply: never benches a model."""

    ccl_empty_reply = True


def is_empty_reply_error(exc) -> bool:
    return bool(getattr(exc, "ccl_empty_reply", False)) or "empty reply (no text, no tool call)" in str(exc)[:300]


# (call id, model) -> (empty replies seen, first seen). One retry on the same model.
_EMPTY_SEEN: dict = {}
_EMPTY_TTL = 600.0


def _empty_attempt(request_data) -> int:
    now = time.monotonic()
    for k in [k for k, (_, t) in _EMPTY_SEEN.items() if now - t > _EMPTY_TTL]:
        _EMPTY_SEEN.pop(k, None)
    rd = request_data or {}
    key = (rd.get("litellm_call_id") or id(rd), rd.get("model") or "")
    n, t = _EMPTY_SEEN.get(key, (0, now))
    _EMPTY_SEEN[key] = (n + 1, t)
    return n + 1


def empty_reply_error(request_data):
    """The error for an empty reply: retryable the first time, then one that moves
    straight on to the next model. Both are marked so nothing benches the model."""
    import litellm

    model = (request_data or {}).get("model") or ""
    if _empty_attempt(request_data) <= 1:
        cls = type("EmptyReplyRetry", (EmptyReply, litellm.InternalServerError), {})
        msg = "empty reply (no text, no tool call); retrying once on the same model"
    else:
        cls = type("EmptyReplyNext", (EmptyReply, litellm.BadRequestError), {})
        msg = "empty reply (no text, no tool call) twice; trying the next model in the chain"
    print(f"[request-fixes] {msg} ({model})", flush=True)
    return cls(message=msg, llm_provider="openai", model=model)


def _no_cooldown_for_empty_replies() -> None:
    """LiteLLM's own cooldown skips errors marked as empty replies."""
    try:
        import litellm.router as lr
        from litellm.router_utils import cooldown_handlers as ch
    except Exception:
        return
    orig = getattr(ch, "_set_cooldown_deployments", None)
    if orig is None or getattr(orig, "_ccl_empty", False):
        return

    def _set_cooldown_deployments(*args, **kwargs):
        exc = kwargs.get("original_exception")
        if exc is not None and is_empty_reply_error(exc):
            return False
        return orig(*args, **kwargs)

    _set_cooldown_deployments._ccl_empty = True
    ch._set_cooldown_deployments = _set_cooldown_deployments
    if getattr(lr, "_set_cooldown_deployments", None) is orig:
        lr._set_cooldown_deployments = _set_cooldown_deployments


def make_logger(served=_served):
    from litellm.integrations.custom_logger import CustomLogger

    class RequestFixes(CustomLogger):
        async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
            if isinstance(data, dict):
                new, loud = map_model(data.get("model"), served())
                if new:
                    if loud:
                        print(f"[request-fixes] WARNING: unmapped model {data['model']!r} has no slot; sent to "
                              f"{new}. Pin it with ANTHROPIC_DEFAULT_*_MODEL or add it to slots.py.", flush=True)
                    else:
                        print(f"[request-fixes] model {data['model']} -> slot {new}", flush=True)
                    data["model"] = new
                if "messages" in data:
                    data["messages"] = add_missing_tool_results(data["messages"])
            return data

        async def async_post_call_success_deployment_hook(self, request_data, response, call_type):
            if not (request_data or {}).get("stream") and is_empty_reply(response):
                raise empty_reply_error(request_data)
            return None

    return RequestFixes()


def install() -> bool:
    """Register once in litellm.callbacks. Safe to call more than once."""
    if _installed["done"]:
        return True
    import litellm

    if not any(type(c).__name__ == "RequestFixes" for c in (litellm.callbacks or [])):
        litellm.callbacks.append(make_logger())
        _no_cooldown_for_empty_replies()
        print("[sitecustomize] request fixes installed (claude-* names -> slots, tool_result stand-ins, "
              "empty reply retry without benching)", flush=True)
    _installed["done"] = True
    return True
