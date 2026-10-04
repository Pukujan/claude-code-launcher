"""End-to-end repro of the advisor echo against a throwaway proxy (never 4000).

Skipped unless CCL_ADVISOR_E2E_PORT names a running test proxy, for example one
started with: start-litellm.ps1 -Background -SkipSync -Port 4017. It costs two
small model calls on the advisor seat.

1. The advisor sub-call exactly as LiteLLM builds it (history with tool_use and
   tool_result blocks, no system prompt, no tools). Without advisor_fix the
   DeepSeek seat answers with raw "<｜｜DSML｜｜ invoke ...>" tool-call text.
2. The same call after advisor_fix.flatten_messages: plain-text advice.
"""
import json
import os
import sys
import urllib.request
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "shared" / "litellm"))
import advisor_fix as af  # noqa: E402

PORT = os.environ.get("CCL_ADVISOR_E2E_PORT", "").strip()
MODEL = os.environ.get("CCL_ADVISOR_E2E_MODEL", "claude-opus-5-5")
pytestmark = pytest.mark.skipif(not PORT, reason="set CCL_ADVISOR_E2E_PORT to a throwaway proxy port")

HISTORY = [
    {"role": "user", "content": "Check whether file profile/soul.md exists in the repo and tell me its size."},
    {"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_01A", "name": "Bash",
                                       "input": {"command": "ls -la profile/soul.md"}}]},
    {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_01A",
                                  "content": "-rw-r--r-- 1 u u 6888 Oct  4 profile/soul.md"}]},
    {"role": "user", "content": "Is the soul file the intended identity source? Give guidance."},
]
TOOL_MARKUP = ("DSML", "<tool_call", "invoke name=", "<function")


def _ask(messages):
    assert PORT != "4000", "never test against the live proxy"
    body = {"model": MODEL, "max_tokens": 1024, "messages": messages}
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/messages", data=json.dumps(body).encode(),
                                 headers={"content-type": "application/json", "anthropic-version": "2023-06-01"})
    with urllib.request.urlopen(req, timeout=300) as r:
        out = json.loads(r.read())
    return "\n".join(b.get("text", "") for b in out.get("content", []) if b.get("type") == "text").strip()


def test_flattened_advisor_call_returns_plain_text_advice():
    text = _ask(af.flatten_messages(HISTORY))
    print("flattened advisor reply:", text[:600])
    assert text, "advisor returned no text"
    assert not any(m in text for m in TOOL_MARKUP), text[:600]


def test_raw_advisor_call_shows_the_bug():
    """Informational: records what the unpatched shape gets back. Not a gate,
    because a model may sometimes answer sensibly even without the fix."""
    text = _ask(HISTORY)
    print("raw advisor reply:", text[:600])
    print("raw reply contains tool-call markup:", any(m in text for m in TOOL_MARKUP))
