"""The advisor sub-call gets plain text and a reviewer framing, never tool blocks."""
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "shared" / "litellm"))
import advisor_fix as af  # noqa: E402


def litellm_like_builder(messages, executor_response, advisor_use_block):
    """Same shape as LiteLLM 1.103.0's _build_advisor_context: drops system rows,
    keeps the history as it is (tool blocks included), adds the executor's text
    and the advisor question as a final user turn."""
    question = (advisor_use_block.get("input") or {}).get("question") or "Please provide guidance on the current task."
    text_blocks = [b for b in executor_response.get("content") or [] if b.get("type") == "text"]
    out = [m for m in messages if m.get("role") != "system"]
    if text_blocks:
        out.append({"role": "assistant", "content": text_blocks})
    out.append({"role": "user", "content": question})
    return out


HISTORY = [
    {"role": "system", "content": "hook output"},
    {"role": "user", "content": "Check whether profile/soul.md exists and tell me its size."},
    {"role": "assistant", "content": [
        {"type": "thinking", "thinking": "let me look", "signature": ""},
        {"type": "text", "text": "Checking."},
        {"type": "tool_use", "id": "toolu_01A", "name": "Bash", "input": {"command": "ls -la profile/soul.md"}},
    ]},
    {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "toolu_01A",
         "content": [{"type": "text", "text": "-rw-r--r-- 1 u u 6888 Oct  4 profile/soul.md"}]},
    ]},
]
EXECUTOR = {"content": [
    {"type": "text", "text": "Let me ask the advisor."},
    {"type": "tool_use", "id": "toolu_02B", "name": "advisor", "input": {"question": "Is soul.md the identity source?"}},
]}
USE_BLOCK = EXECUTOR["content"][1]


def _all_blocks(messages):
    for m in messages:
        c = m["content"]
        if isinstance(c, list):
            yield from c


def check_flattened(out):
    assert all(isinstance(m["content"], str) for m in out), "every turn is plain text"
    assert not list(_all_blocks(out))
    assert [m["role"] for m in out] == ["user", "assistant", "user", "assistant", "user"][: len(out)]
    for a, b in zip(out, out[1:]):
        assert a["role"] != b["role"], "turns alternate"
    assert out[0]["role"] == "user" and out[-1]["role"] == "user"
    assert af.FRAME in out[-1]["content"]
    assert out[-1]["content"].rstrip().endswith("Is soul.md the identity source?")
    joined = "\n".join(m["content"] for m in out)
    assert "[The agent called the tool Bash with input: {\"command\": \"ls -la profile/soul.md\"}]" in joined
    assert "[Tool result: -rw-r--r-- 1 u u 6888 Oct  4 profile/soul.md]" in joined
    assert "let me look" not in joined  # thinking is dropped
    assert "hook output" not in joined  # system rows stay dropped


def test_wrapped_builder_leaves_no_tool_blocks_and_adds_frame():
    unwrapped = litellm_like_builder(HISTORY, EXECUTOR, USE_BLOCK)
    assert any(b.get("type") == "tool_use" for b in _all_blocks(unwrapped))  # the bug: tool blocks reach the advisor
    check_flattened(af.wrap_builder(litellm_like_builder)(HISTORY, EXECUTOR, USE_BLOCK))


def test_wrapping_twice_is_a_no_op():
    once = af.wrap_builder(litellm_like_builder)
    assert af.wrap_builder(once) is once


def test_tool_errors_long_inputs_and_other_result_types():
    long_cmd = "x" * (af.MAX_TOOL_INPUT + 500)
    msgs = [
        {"role": "user", "content": "go"},
        {"role": "assistant", "content": [{"type": "tool_use", "id": "a", "name": "Bash", "input": {"command": long_cmd}}]},
        {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "a", "is_error": True, "content": "boom"},
            {"type": "web_search_tool_result", "tool_use_id": "w", "content": "some results"},
            {"type": "image", "source": {}},
        ]},
    ]
    out = af.flatten_messages(msgs)
    text = out[-1]["content"]
    assert "[Tool error: boom]" in text and "[Tool result: some results]" in text and "[image]" in text
    assert "[...cut]" in out[1]["content"] and len(out[1]["content"]) < af.MAX_TOOL_INPUT + 200


def test_history_ending_with_assistant_still_ends_with_a_user_question():
    out = af.flatten_messages([{"role": "user", "content": "hi"}, {"role": "assistant", "content": "hello"}])
    assert out[-1]["role"] == "user" and af.FRAME in out[-1]["content"]


def test_install_patches_the_real_litellm_interceptor():
    adv = pytest.importorskip("litellm.llms.anthropic.experimental_pass_through.messages.interceptors.advisor")
    orig = adv._build_advisor_context
    try:
        af._installed["done"] = False
        assert af.install()
        out = adv._build_advisor_context(
            [dict(m) for m in HISTORY if m["role"] != "system"], EXECUTOR, USE_BLOCK)
        check_flattened(out)
    finally:
        adv._build_advisor_context = getattr(adv._build_advisor_context, "__wrapped__", orig)
        af._installed["done"] = False


def test_sitecustomize_installs_the_advisor_fix_after_request_fixes():
    text = (ROOT / "shared" / "litellm" / "sitecustomize.py").read_text(encoding="utf-8")
    assert "import advisor_fix as _af" in text and "_af.install()" in text
    assert text.index("_rf.install()") < text.index("_af.install()")
