"""Catch-all claude-* names, stand-in tool results, empty reply retry."""
import asyncio
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "shared" / "litellm"))
import request_fixes as rf  # noqa: E402

SERVED = {"main", "sonnet", "opus", "claude-sonnet-5", "claude-opus-5-5", "small-fast", "claude-sonnet-4-5"}


def test_unknown_claude_ids_go_to_main():
    assert rf.catchall_model("claude-opus-4-8", SERVED) == "main"
    assert rf.catchall_model("claude-sonnet-4-6", SERVED) == "main"
    assert rf.catchall_model("claude-sonnet-5[1m]", SERVED) == "main"
    assert rf.catchall_model("sonnet[1m]", SERVED) == "main"


def test_known_and_other_names_are_left_alone():
    for name in SERVED:
        assert rf.catchall_model(name, SERVED) is None
    assert rf.catchall_model("gpt-5", SERVED) is None
    assert rf.catchall_model("claude-opus-4-8", {"opus"}) is None  # no main seat to send it to


def _tool_use(i):
    return {"type": "tool_use", "id": i, "name": "Bash", "input": {}}


def test_dangling_tool_use_gets_a_stand_in_result():
    msgs = [
        {"role": "user", "content": "hi"},
        {"role": "assistant", "content": [{"type": "text", "text": "ok"}, _tool_use("a"), _tool_use("b")]},
        {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "b", "content": "done"}]},
    ]
    out = rf.add_missing_tool_results(msgs)
    results = [b for b in out[2]["content"] if b["type"] == "tool_result"]
    assert [b["tool_use_id"] for b in results] == ["a", "b"]
    assert results[0]["content"] == rf.PLACEHOLDER
    assert msgs[2]["content"][0]["tool_use_id"] == "b"  # input not modified


def test_text_reply_after_tool_use_and_trailing_tool_use():
    msgs = [{"role": "assistant", "content": [_tool_use("a")]}, {"role": "user", "content": "no, stop"}]
    out = rf.add_missing_tool_results(msgs)
    assert out[1]["content"] == [rf._stand_in("a"), {"type": "text", "text": "no, stop"}]
    out = rf.add_missing_tool_results([{"role": "user", "content": "x"}, {"role": "assistant", "content": [_tool_use("z")]}])
    assert out[-1] == {"role": "user", "content": [rf._stand_in("z")]}


def test_complete_history_is_unchanged():
    msgs = [{"role": "assistant", "content": [_tool_use("a")]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "a", "content": "ok"}]},
            {"role": "assistant", "content": "plain text"}]
    assert rf.add_missing_tool_results(msgs) == msgs


def test_empty_reply_detection():
    assert rf.is_empty_reply({"choices": [{"message": {"content": "", "tool_calls": None}}]})
    assert rf.is_empty_reply({"choices": [{"message": {"content": "  "}}]})
    assert not rf.is_empty_reply({"choices": [{"message": {"content": "hi"}}]})
    assert not rf.is_empty_reply({"choices": [{"message": {"content": None, "tool_calls": [{"id": "1"}]}}]})
    assert rf.is_empty_reply({"type": "message", "content": [{"type": "thinking", "thinking": "hmm"}]})
    assert rf.is_empty_reply({"type": "message", "content": []})
    assert not rf.is_empty_reply({"type": "message", "content": [{"type": "text", "text": "hi"}]})
    assert not rf.is_empty_reply({"type": "message", "content": [_tool_use("a")]})
    assert not rf.is_empty_reply({"data": []})  # not a chat reply


def test_hooks_rewrite_and_raise_retryable():
    litellm = pytest.importorskip("litellm")
    logger = rf.make_logger(served=lambda: SERVED)
    data = {"model": "claude-opus-4-8", "messages": [{"role": "assistant", "content": [_tool_use("a")]}]}
    out = asyncio.run(logger.async_pre_call_hook(None, None, data, "anthropic_messages"))
    assert out["model"] == "main" and out["messages"][-1]["content"][0]["tool_use_id"] == "a"
    empty = {"type": "message", "content": []}
    with pytest.raises(litellm.InternalServerError):
        asyncio.run(logger.async_post_call_success_deployment_hook({"model": "main"}, empty, None))
    assert asyncio.run(logger.async_post_call_success_deployment_hook({"model": "main", "stream": True}, empty, None)) is None
