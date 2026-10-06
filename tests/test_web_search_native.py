"""Claude Code's WebSearch sub-request gets native blocks (issue #77).

LiteLLM 1.103.0 answers the search-only request without a model, but its
pre-request hook has already swapped the native web_search tool for
litellm_web_search, so the answer came back as text only and Claude Code showed
"Did 0 searches". These tests need no LiteLLM: the patch takes LiteLLM's pieces
as arguments.
"""
import asyncio
import json
import types

import web_search as ws

FLAG = "_websearch_interception_emit_native_blocks"
LITELLM_TOOL = {"name": "litellm_web_search", "description": "x", "input_schema": {"type": "object"}}
NATIVE = {"type": "web_search_20250305", "name": "web_search", "max_uses": 8}


def is_native(t):
    return str(t.get("type", "")).startswith("web_search_")


def is_search(t):
    return is_native(t) or t.get("name") in ("litellm_web_search", "web_search", "WebSearch")


def ok_block(tid, n=2):
    return {"type": "web_search_tool_result", "tool_use_id": tid,
            "content": [{"type": "web_search_result", "url": f"https://e.example/{i}", "title": f"t{i}",
                         "page_age": None, "encrypted_content": "", "snippet": "s"} for i in range(n)]}


def short_circuit_like_litellm(model, messages, tools, custom_llm_provider, stream, kwargs=None):
    """What LiteLLM 1.103.0's short-circuit returns: native blocks only if it sees a native tool."""
    content = []
    native = next((t for t in tools or [] if is_native(t)), None)
    if native is not None:
        content += [{"type": "server_tool_use", "id": "srvtoolu_1", "name": native.get("name") or "web_search",
                     "input": {"query": "Perform a web search for the query: neo4j editions"}},
                    ok_block("srvtoolu_1")]
    content.append({"type": "text", "text": "Title: t0\nURL: https://e.example/0\nSnippet: s"})
    resp = {"id": "msg_1", "type": "message", "role": "assistant", "model": model, "content": content,
            "stop_reason": "end_turn", "stop_sequence": None, "usage": {"input_tokens": 0, "output_tokens": 0}}
    return ("STREAM", resp) if stream else resp


def patched(record=None):
    async def orig(model, messages, tools, custom_llm_provider, stream, kwargs=None):
        if record is not None:
            record.append({"tools": tools, "stream": stream})
        return short_circuit_like_litellm(model, messages, tools, custom_llm_provider, stream, kwargs)

    return ws.wrap_short_circuit(orig, is_native=is_native, is_search=is_search, flag=FLAG,
                                 stream_cls=lambda resp: ("OURSTREAM", resp))


def call(fn, *, tools, kwargs, stream=False):
    return asyncio.run(fn(model="claude-haiku", messages=[], tools=tools, custom_llm_provider="openai",
                          stream=stream, kwargs=kwargs))


def test_flagged_request_gets_server_tool_use_and_result_blocks():
    resp = call(patched(), tools=[LITELLM_TOOL], kwargs={FLAG: True})
    types_ = [b["type"] for b in resp["content"]]
    assert types_ == ["server_tool_use", "web_search_tool_result", "text"]
    assert resp["content"][0]["name"] == "web_search"


def test_server_tool_use_query_has_no_claude_code_prompt():
    resp = call(patched(), tools=[LITELLM_TOOL], kwargs={FLAG: True})
    assert resp["content"][0]["input"] == {"query": "neo4j editions"}


def test_usage_counts_successful_searches():
    resp = call(patched(), tools=[LITELLM_TOOL], kwargs={FLAG: True})
    assert resp["usage"]["server_tool_use"] == {"web_search_requests": 1}


def test_unflagged_request_is_left_alone():
    seen = []
    resp = call(patched(seen), tools=[LITELLM_TOOL], kwargs={})
    assert seen[0]["tools"] == [LITELLM_TOOL]
    assert [b["type"] for b in resp["content"]] == ["text"]
    assert "server_tool_use" not in resp["usage"]


def test_other_tools_are_kept_and_native_tool_not_duplicated():
    other = {"name": "Bash", "input_schema": {}}
    seen = []
    call(patched(seen), tools=[other, LITELLM_TOOL], kwargs={FLAG: True})
    assert seen[0]["tools"][0] == other and is_native(seen[0]["tools"][1]) and len(seen[0]["tools"]) == 2
    seen.clear()
    call(patched(seen), tools=[NATIVE], kwargs={FLAG: True})
    assert seen[0]["tools"] == [NATIVE]


def test_no_short_circuit_passes_none_through():
    async def orig(**kw):
        return None

    fn = ws.wrap_short_circuit(orig, is_native=is_native, is_search=is_search, flag=FLAG, stream_cls=list)
    assert call(fn, tools=[LITELLM_TOOL], kwargs={FLAG: True}, stream=True) is None


def test_streaming_caller_gets_our_stream_built_from_the_full_response():
    seen = []
    out = call(patched(seen), tools=[LITELLM_TOOL], kwargs={FLAG: True}, stream=True)
    assert seen[0]["stream"] is False  # we build the stream ourselves
    assert out[0] == "OURSTREAM" and out[1]["usage"]["server_tool_use"]["web_search_requests"] == 1


def test_error_block_counts_zero():
    resp = {"content": [{"type": "server_tool_use", "id": "s", "name": "web_search", "input": {"query": "q"}},
                        {"type": "web_search_tool_result", "tool_use_id": "s",
                         "content": {"type": "web_search_tool_result_error", "error_code": "unavailable"}}],
            "usage": {"input_tokens": 0, "output_tokens": 0}}
    assert ws.add_search_usage(resp)["usage"]["server_tool_use"] == {"web_search_requests": 0}


def events(chunks):
    out = []
    for c in chunks:
        text = c.decode() if isinstance(c, bytes) else c
        name, data = text.strip().split("\n", 1)
        assert name.startswith("event: ") and data.startswith("data: ")
        ev = json.loads(data[len("data: "):])
        assert ev["type"] == name[len("event: "):]
        out.append(ev)
    return out


def test_sse_matches_anthropic_streaming_shape():
    resp = ws.add_search_usage(call(patched(), tools=[LITELLM_TOOL], kwargs={FLAG: True}))
    evs = events(ws.sse_chunks(resp))
    assert [e["type"] for e in evs][0] == "message_start" and evs[-1]["type"] == "message_stop"
    starts = [e for e in evs if e["type"] == "content_block_start"]
    assert [s["content_block"]["type"] for s in starts] == ["server_tool_use", "web_search_tool_result", "text"]
    # server_tool_use starts with empty input and gets the query as an input_json_delta, like Anthropic.
    assert starts[0]["content_block"]["input"] == {}
    deltas = [e for e in evs if e["type"] == "content_block_delta" and e["index"] == 0]
    assert json.loads("".join(d["delta"]["partial_json"] for d in deltas)) == {"query": "neo4j editions"}
    assert len(starts[1]["content_block"]["content"]) == 2
    text = "".join(e["delta"]["text"] for e in evs if e["type"] == "content_block_delta" and e["index"] == 2)
    assert "https://e.example/0" in text
    stops = [e["index"] for e in evs if e["type"] == "content_block_stop"]
    assert stops == [0, 1, 2]
    md = next(e for e in evs if e["type"] == "message_delta")
    assert md["usage"]["server_tool_use"] == {"web_search_requests": 1}
    assert md["delta"]["stop_reason"] == "end_turn"


def test_install_patches_the_messages_handler_module():
    calls = []

    async def orig(model, messages, tools, custom_llm_provider, stream, kwargs=None):
        calls.append(tools)
        return short_circuit_like_litellm(model, messages, tools, custom_llm_provider, stream, kwargs)

    handler_mod = types.SimpleNamespace(_try_websearch_short_circuit=orig)
    assert ws.install_native_blocks(handler_mod, is_native=is_native, is_search=is_search, flag=FLAG,
                                    stream_cls=list) is True
    assert ws.install_native_blocks(handler_mod, is_native=is_native, is_search=is_search, flag=FLAG,
                                    stream_cls=list) is False  # once only
    resp = asyncio.run(handler_mod._try_websearch_short_circuit("m", [], [LITELLM_TOOL], "openai", False,
                                                                kwargs={FLAG: True}))
    assert resp["usage"]["server_tool_use"]["web_search_requests"] == 1 and len(calls) == 1
