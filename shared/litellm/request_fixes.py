"""Small request/response fixes for Claude Code traffic through the proxy.

1. Unknown claude-* ids. Claude Code sends whatever id it was told or defaults
   to (claude-opus-4-8, claude-sonnet-4-6, sonnet[1m], ...). A name the proxy
   does not serve would fail with "model not found", so any unknown name that
   starts with "claude-" or ends with "[1m]" is sent to the main seat (and its
   fallbacks). Names the proxy already serves are left alone.
2. Dangling tool calls. When an assistant tool_use has no tool_result in the
   next user message (the user rejected it or the run was cut short), strict
   backends such as DeepSeek answer 400. A placeholder tool_result is added.
   Anthropic-format messages only.
3. Empty replies. A non-streaming reply with no text and no tool call is turned
   into a retryable error, so the usual retries and fallbacks take over.
   Streaming replies are not checked (the content is not known until the
   stream has already started going to the client).

Standard library plus litellm; imported lazily by sitecustomize.py.
"""
from __future__ import annotations

MAIN = "main"
PLACEHOLDER = "Tool call was rejected or not run."

_installed = {"done": False}


def catchall_model(model, served) -> str | None:
    """The name to use instead of *model*, or None to leave it alone."""
    if not isinstance(model, str) or model in served or MAIN not in served:
        return None
    if model.startswith("claude-") or model.endswith("[1m]"):
        return MAIN
    return None


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


def make_logger(served=_served):
    import litellm
    from litellm.integrations.custom_logger import CustomLogger

    class RequestFixes(CustomLogger):
        async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
            if isinstance(data, dict):
                new = catchall_model(data.get("model"), served())
                if new:
                    print(f"[request-fixes] unknown model {data['model']} -> {new}", flush=True)
                    data["model"] = new
                if "messages" in data:
                    data["messages"] = add_missing_tool_results(data["messages"])
            return data

        async def async_post_call_success_deployment_hook(self, request_data, response, call_type):
            if not (request_data or {}).get("stream") and is_empty_reply(response):
                model = (request_data or {}).get("model") or ""
                raise litellm.InternalServerError(
                    message="empty reply (no text, no tool call); retrying", llm_provider="openai", model=model)
            return None

    return RequestFixes()


def install() -> bool:
    """Register once in litellm.callbacks. Safe to call more than once."""
    if _installed["done"]:
        return True
    import litellm

    if not any(type(c).__name__ == "RequestFixes" for c in (litellm.callbacks or [])):
        litellm.callbacks.append(make_logger())
        print("[sitecustomize] request fixes installed (claude-* catch-all, tool_result stand-ins, empty reply retry)", flush=True)
    _installed["done"] = True
    return True
