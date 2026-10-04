"""Catch-all claude-* names, stand-in tool results, empty reply retry."""
import asyncio
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "shared" / "litellm"))
import request_fixes as rf  # noqa: E402

SERVED = {"sonnet", "opus", "haiku", "fable", "claude-sonnet-5", "claude-opus-5-5", "claude-fable-5",
          "claude-haiku-4-5-20251001", "small-fast", "main"}


def test_unknown_claude_ids_go_to_their_own_slot():
    assert rf.catchall_model("claude-opus-4-8", SERVED) == "opus"
    assert rf.catchall_model("claude-sonnet-4-6", SERVED) == "sonnet"
    assert rf.catchall_model("claude-sonnet-5[1m]", SERVED) == "claude-sonnet-5"
    assert rf.catchall_model("sonnet[1m]", SERVED) == "sonnet"
    assert rf.catchall_model("claude-haiku-4-5", SERVED) == "haiku"
    assert rf.catchall_model("claude-3-5-haiku-20241022", SERVED) == "haiku"
    assert rf.catchall_model("claude-fable-5-2", SERVED) == "fable"
    assert rf.catchall_model("claude-opus-5[1m]", SERVED) == "opus"


def test_a_claude_name_with_no_family_goes_to_sonnet_loudly():
    assert rf.map_model("claude-ih-main", SERVED) == ("sonnet", True)
    assert rf.map_model("claude-opus-4-8", SERVED) == ("opus", False)


def test_known_and_other_names_are_left_alone():
    for name in SERVED:
        assert rf.catchall_model(name, SERVED) is None
    assert rf.catchall_model("gpt-5", SERVED) is None
    assert rf.catchall_model("claude-ih-main", {"opus"}) is None  # no sonnet slot to send it to


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


def test_hooks_rewrite_and_raise_retryable(capsys):
    litellm = pytest.importorskip("litellm")
    logger = rf.make_logger(served=lambda: SERVED)
    data = {"model": "claude-opus-4-8", "messages": [{"role": "assistant", "content": [_tool_use("a")]}]}
    out = asyncio.run(logger.async_pre_call_hook(None, None, data, "anthropic_messages"))
    assert out["model"] == "opus" and out["messages"][-1]["content"][0]["tool_use_id"] == "a"
    out = asyncio.run(logger.async_pre_call_hook(None, None, {"model": "claude-ih-main"}, "anthropic_messages"))
    assert out["model"] == "sonnet" and "WARNING: unmapped model 'claude-ih-main'" in capsys.readouterr().out
    empty = {"type": "message", "content": []}
    req = {"model": "openai/cb/deepseek-v4.1-flash", "litellm_call_id": "call-1"}
    # first empty reply: retried on the same model (a retryable 500 type), marked so it never benches
    with pytest.raises(litellm.InternalServerError) as e1:
        asyncio.run(logger.async_post_call_success_deployment_hook(dict(req), empty, None))
    assert rf.is_empty_reply_error(e1.value)
    # second empty reply for the same request and model: a non-retried error, so the chain moves on
    with pytest.raises(litellm.BadRequestError) as e2:
        asyncio.run(logger.async_post_call_success_deployment_hook(dict(req), empty, None))
    assert rf.is_empty_reply_error(e2.value) and not isinstance(e2.value, litellm.InternalServerError)
    # the next model in the chain gets its own retry
    with pytest.raises(litellm.InternalServerError):
        asyncio.run(logger.async_post_call_success_deployment_hook(dict(req, model="openai/ali/qwen3.8-flash"), empty, None))
    assert asyncio.run(logger.async_post_call_success_deployment_hook({"model": "x", "stream": True}, empty, None)) is None


def test_empty_replies_never_bench():
    pytest.importorskip("litellm")
    import bench_after_retries as bar
    from litellm.router_utils import cooldown_handlers as ch

    rf._no_cooldown_for_empty_replies()
    err = rf.empty_reply_error({"model": "m", "litellm_call_id": "bench-1"})
    assert bar.should_bench(err) is False
    assert ch._set_cooldown_deployments(litellm_router_instance=None, original_exception=err,
                                         exception_status=500, deployment="x") is False
