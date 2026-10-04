"""Give the advisor model a plain-text review request instead of the agent's transcript.

Claude Code's advisor tool (advisor_20260301) is run by LiteLLM's
AdvisorOrchestrationHandler for every non-Anthropic provider. For the advisor
sub-call it sends the whole conversation, including the agent's tool_use and
tool_result blocks, with no system prompt and no tools. A model such as
DeepSeek V4.1 Flash reads that as its own agent loop and keeps going: it writes
its next tool call as raw "<｜｜DSML｜｜ invoke ...>" text, or answers the user as
if it were the agent. Claude Code then gets that back as the advice and reports
the advisor as "returning malformed echoes".

This wraps LiteLLM's _build_advisor_context so the advisor sees:
- every tool call and tool result written out as plain text,
- consecutive turns from the same role merged (plain text has to alternate),
- a short reviewer framing in front of the question in the last user turn.

Nothing else about the advisor loop changes. Standard library only here;
litellm is imported lazily by install().
"""
from __future__ import annotations

import json

FRAME = (
    "You are the ADVISOR. Another AI agent is working on the task in the conversation above "
    "and is asking you for guidance. You cannot run tools and you are not the agent. "
    "Reply only with plain-text advice on the question below. Never write tool calls, "
    "function calls or tool-call markup."
)
MAX_TOOL_INPUT = 2000
MAX_TOOL_RESULT = 4000

_installed = {"done": False}


def _clip(text: str, limit: int) -> str:
    return text if len(text) <= limit else text[:limit] + " [...cut]"


def _result_text(content) -> str:
    if isinstance(content, str):
        return content
    parts = []
    for b in content or []:
        if isinstance(b, dict):
            if b.get("type") == "text":
                parts.append(b.get("text") or "")
            elif b.get("type") == "image":
                parts.append("[image]")
        elif isinstance(b, str):
            parts.append(b)
    return "\n".join(p for p in parts if p)


def block_text(block) -> str:
    """One content block as plain text ("" for blocks the advisor doesn't need)."""
    if isinstance(block, str):
        return block
    if not isinstance(block, dict):
        return ""
    t = block.get("type")
    if t == "text":
        return block.get("text") or ""
    if t in ("tool_use", "server_tool_use"):
        args = json.dumps(block.get("input") or {}, ensure_ascii=False)
        return "[The agent called the tool %s with input: %s]" % (block.get("name") or "?", _clip(args, MAX_TOOL_INPUT))
    if t == "tool_result" or (isinstance(t, str) and t.endswith("_tool_result")):
        label = "Tool error" if block.get("is_error") else "Tool result"
        return "[%s: %s]" % (label, _clip(_result_text(block.get("content")), MAX_TOOL_RESULT))
    if t == "image":
        return "[image]"
    return ""  # thinking, redacted_thinking and anything else the advisor can do without


def content_text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(p for p in (block_text(b) for b in content) if p.strip())
    return ""


def flatten_messages(messages):
    """Plain-text, strictly alternating messages ending in a framed user question."""
    merged = []
    for m in messages or []:
        if not isinstance(m, dict) or m.get("role") not in ("user", "assistant"):
            continue
        text = content_text(m.get("content")).strip()
        if not text:
            continue
        if merged and merged[-1]["role"] == m["role"]:
            merged[-1]["content"] += "\n\n" + text
        else:
            merged.append({"role": m["role"], "content": text})
    if not merged or merged[-1]["role"] != "user":
        merged.append({"role": "user", "content": "Please give guidance on the current task."})
    merged[-1]["content"] = FRAME + "\n\nQuestion from the agent:\n" + merged[-1]["content"]
    return merged


def wrap_builder(orig):
    """Wrap a _build_advisor_context-compatible function so its output is flattened."""
    if getattr(orig, "_ccl_advisor_fix", False):
        return orig

    def build(messages, executor_response, advisor_use_block):
        return flatten_messages(orig(messages, executor_response, advisor_use_block))

    build._ccl_advisor_fix = True
    build.__wrapped__ = orig
    return build


def install() -> bool:
    """Patch LiteLLM's advisor interceptor once. Safe to call more than once."""
    if _installed["done"]:
        return True
    from litellm.llms.anthropic.experimental_pass_through.messages.interceptors import advisor as _adv

    _adv._build_advisor_context = wrap_builder(_adv._build_advisor_context)
    _installed["done"] = True
    print("[sitecustomize] advisor fix installed (plain-text advisor context with reviewer framing)", flush=True)
    return True
