"""Silence race for streaming /v1/messages. No network and no port 4000.

A fallback model re-reads the prompt; it cannot continue another model's
tokens. These tests drive fake ASGI streams on short budgets.
"""
import asyncio
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "shared" / "litellm"))
import stall_hedge as sh  # noqa: E402


def run(coro, limit=2.5):
    async def bounded():
        return await asyncio.wait_for(coro, limit)

    return asyncio.run(bounded())


def cfg(**overrides):
    data = dict(
        enabled=True,
        floor_s=0.25,
        cap_s=0.5,
        mult=1.5,
        bench_s=30.0,
        bench_cap_s=600.0,
        ping_s=30.0,
        gap_s=2.0,
        max_inflight=2,
    )
    data.update(overrides)
    return sh.Settings(**data)


def sse(event, obj):
    return f"event: {event}\ndata: {json.dumps(obj)}\n\n".encode()


def message_start(mid):
    return sse("message_start", {"type": "message_start", "message": {"id": mid, "role": "assistant"}})


def text_delta(text):
    return sse("content_block_delta", {
        "type": "content_block_delta",
        "index": 0,
        "delta": {"type": "text_delta", "text": text},
    })


def thinking_delta(text):
    return sse("content_block_delta", {
        "type": "content_block_delta",
        "index": 0,
        "delta": {"type": "thinking_delta", "thinking": text},
    })


def start(status=200):
    return {"type": "http.response.start", "status": status, "headers": []}


def body(data, more=True):
    return {"type": "http.response.body", "body": data, "more_body": more}


def end():
    return {"type": "http.response.body", "body": b"", "more_body": False}


def post_scope(path="/v1/messages", headers=None, method="POST"):
    return {"type": "http", "method": method, "path": path, "headers": list(headers or [])}


def once(payload: bytes):
    sent = {"done": False}

    async def receive():
        if sent["done"]:
            return {"type": "http.request", "body": b"", "more_body": False}
        sent["done"] = True
        return {"type": "http.request", "body": payload, "more_body": False}

    return receive


class Script:
    def __init__(self, events):
        self.events = events
        self.opened = []
        self.attempts = []

    def open_attempt(self):
        async def open_attempt(name):
            self.opened.append((name, time.monotonic()))
            queue = asyncio.Queue()
            events = self.events.get(name, [])

            async def runner():
                try:
                    for pause, msg in events:
                        if pause:
                            await asyncio.sleep(pause)
                        await queue.put(msg)
                finally:
                    queue.put_nowait(None)

            task = asyncio.create_task(runner())
            attempt = sh.Attempt(name, queue, task, time.monotonic())
            self.attempts.append(attempt)
            return attempt

        return open_attempt


def client():
    messages = []

    async def send(msg):
        messages.append(msg)

    return messages, send


def text_of(messages):
    chunks = []
    for msg in messages:
        if msg.get("type") == "http.response.body":
            chunks.append(msg.get("body") or b"")
    return b"".join(chunks).decode("utf-8", "replace")


def statuses(messages):
    return [msg["status"] for msg in messages if msg.get("type") == "http.response.start"]


async def race(order, events, settings, benches, ttfts=None):
    messages, send = client()
    script = Script(events)
    winner = await sh.run_race(
        order,
        script.open_attempt(),
        budget_for=lambda _name: settings.floor_s,
        settings=settings,
        send=send,
        on_bench=benches.append,
        on_ttft=(lambda name, seconds: ttfts.append((name, seconds))) if ttfts is not None else (lambda *_a: None),
        clock=time.monotonic,
    )
    return winner, messages, script


def test_event_kind_ignores_message_start_and_pings():
    assert sh.event_kind(message_start("m").decode()) == "other"
    assert sh.event_kind(text_delta("hi").decode()) == "content"
    assert sh.event_kind(thinking_delta("hmm").decode()) == "content"
    assert sh.event_kind(": ping\n\n") == "ping"
    assert sh.event_kind("event: ping\ndata: {}\n\n") == "ping"
    err = sse("error", {"type": "error", "error": {"type": "api_error", "message": "no"}})
    assert sh.event_kind(err.decode()) == "error"
    assert sh.should_bench_status(None) is False
    assert sh.should_bench_status(400) is False
    assert sh.should_bench_status(500) is True
    assert sh.should_bench_status(429) is True


def test_chain_book_and_ewma():
    fallbacks = [{"opus": ["ccl-opus-2", "ccl-opus-3", "opus"]}, {"sonnet": ["x"]}]
    assert sh.chain_for("opus", fallbacks) == ["opus", "ccl-opus-2", "ccl-opus-3"]
    assert sh.chain_for("missing", fallbacks) == ["missing"]

    book = sh.RungBook(30, 600)
    chain = ["opus", "flash", "last"]
    assert book.mark_slow("opus", 0) == 30
    assert book.until["opus"] == 30
    assert sh.eligible(chain, book, 10, lambda _n: False) == ["flash", "last"]
    assert sh.eligible(chain, book, 30, lambda _n: False)[0] == "opus"
    assert book.mark_slow("opus", 100) == 60
    assert book.until["opus"] == 160
    now = 0
    delay = 0
    capped = sh.RungBook(30, 600)
    for _ in range(8):
        delay = capped.mark_slow("opus", now)
        now = capped.until["opus"]
    assert delay == 600
    book.mark_recovered("opus")
    assert book.available("opus", 0)
    assert "opus" not in book.level

    assert sh.eligible(chain, sh.RungBook(30, 600), 0, lambda name: name != "last") == ["last"]

    ewma = sh.Ewma()
    settings = sh.Settings(floor_s=20, cap_s=90, mult=1.5)
    assert ewma.budget("opus", settings) == 20
    ewma.observe("opus", 30)
    assert ewma.budget("opus", settings) == 45
    ewma.observe("opus", 400)
    assert ewma.budget("opus", settings) == 90


def test_settings_from_env_clamps_and_disables():
    assert sh.settings_from_env({"CCL_STALL_HEDGE": "0"}).enabled is False
    for flag in ("false", "off", "no", "FALSE"):
        assert sh.settings_from_env({"CCL_STALL_HEDGE": flag}).enabled is False
    assert sh.settings_from_env({}).enabled is True
    bad = sh.settings_from_env({
        "CCL_STALL_FLOOR_S": "0",
        "CCL_STALL_CAP_S": "9999",
        "CCL_STALL_MULT": "nope",
        "CCL_STALL_BENCH_S": "30",
    })
    assert (bad.floor_s, bad.cap_s, bad.mult, bad.bench_s) == (20.0, 90.0, 1.5, 30.0)
    tuned = sh.settings_from_env({"CCL_STALL_FLOOR_S": "12.5", "CCL_STALL_GAP_S": "40"})
    assert tuned.floor_s == 12.5 and tuned.gap_s == 40


def test_primary_content_does_not_open_the_next_rung():
    settings = cfg(floor_s=0.4)
    benches = []
    ttfts = []
    winner, messages, script = run(race(
        ["opus", "flash"],
        {"opus": [(0.05, start()), (0.0, body(text_delta("HELLO"))), (0.0, end())],
         "flash": [(0.0, start()), (0.0, body(text_delta("NOPE")))]},
        settings, benches, ttfts,
    ))
    assert winner == "opus"
    assert [name for name, _t in script.opened] == ["opus"]
    assert benches == []
    assert ttfts and ttfts[0][0] == "opus"
    assert "HELLO" in text_of(messages) and "NOPE" not in text_of(messages)
    assert ": ping" not in text_of(messages)
    assert statuses(messages) == [200]


def test_thinking_token_commits_the_primary():
    settings = cfg(floor_s=0.4)
    benches = []
    winner, messages, script = run(race(
        ["opus", "flash"],
        {"opus": [(0.05, start()), (0.0, body(thinking_delta("plan"))), (0.0, end())]},
        settings, benches,
    ))
    assert winner == "opus"
    assert [name for name, _t in script.opened] == ["opus"]
    assert "plan" in text_of(messages)


def test_split_content_event_still_counts():
    settings = cfg(floor_s=0.4)
    benches = []
    part1 = b'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"HEL'
    part2 = b'LO"}}\n\n'
    winner, messages, script = run(race(
        ["opus", "flash"],
        {"opus": [(0.0, start()), (0.02, body(part1)), (0.0, body(part2)), (0.0, end())]},
        settings, benches,
    ))
    assert winner == "opus"
    assert [name for name, _t in script.opened] == ["opus"]
    assert "HELLO" in text_of(messages)


def test_silent_primary_loses_to_the_next_rung_without_splicing():
    settings = cfg(floor_s=0.2, ping_s=30)
    benches = []
    winner, messages, script = run(race(
        ["opus", "flash"],
        {
            "opus": [(0.0, start()), (0.0, body(message_start("msg_opus"))), (2.0, body(text_delta("PRIMARY_LATE")))],
            "flash": [(0.02, start()), (0.0, body(message_start("msg_flash") + text_delta("FALLBACK_WORD"))), (0.0, end())],
        },
        settings, benches,
    ))
    assert winner == "flash"
    names = [name for name, _t in script.opened]
    assert names == ["opus", "flash"]
    assert script.opened[1][1] - script.opened[0][1] >= 0.12
    assert benches == ["opus"]
    text = text_of(messages)
    assert "FALLBACK_WORD" in text and "msg_flash" in text
    assert "msg_opus" not in text and "PRIMARY_LATE" not in text
    assert statuses(messages) == [200]


def test_primary_can_still_win_after_the_hedge_starts():
    settings = cfg(floor_s=0.2)
    benches = []
    winner, messages, script = run(race(
        ["opus", "flash"],
        {
            "opus": [(0.28, start()), (0.0, body(text_delta("PRIMARY_OK"))), (0.0, end())],
            "flash": [(0.6, start()), (0.0, body(text_delta("FLASH_LATE")))],
        },
        settings, benches,
    ))
    assert winner == "opus"
    assert [name for name, _t in script.opened] == ["opus", "flash"]
    assert "PRIMARY_OK" in text_of(messages) and "FLASH_LATE" not in text_of(messages)
    assert "opus" not in benches


def test_slow_tokens_after_commit_stay_on_that_model():
    settings = cfg(floor_s=0.4, gap_s=0.25)
    benches = []
    winner, messages, script = run(race(
        ["opus", "flash"],
        {"opus": [(0.0, start()), (0.0, body(text_delta("AB"))), (0.08, body(text_delta("CD"))), (0.0, end())]},
        settings, benches,
    ))
    assert winner == "opus"
    assert [name for name, _t in script.opened] == ["opus"]
    assert benches == []
    text = text_of(messages)
    assert "AB" in text and "CD" in text
    assert "stopped writing" not in text_of(messages)


def test_gap_after_commit_ends_the_turn_and_ignores_pings():
    settings = cfg(floor_s=0.4, gap_s=0.12, ping_s=30)
    benches = []

    async def go():
        messages, send = client()
        script = Script({})

        async def open_attempt(name):
            script.opened.append((name, time.monotonic()))
            queue = asyncio.Queue()

            async def runner():
                try:
                    await queue.put(start())
                    await queue.put(body(text_delta("HELLO")))
                    while True:
                        await asyncio.sleep(0.02)
                        await queue.put(body(b": ping\n\n"))
                finally:
                    queue.put_nowait(None)

            task = asyncio.create_task(runner())
            return sh.Attempt(name, queue, task, time.monotonic())

        winner = await sh.run_race(
            ["opus", "flash"], open_attempt, budget_for=lambda _n: settings.floor_s,
            settings=settings, send=send, on_bench=benches.append, on_ttft=lambda *_a: None,
        )
        return winner, messages, script

    winner, messages, script = run(go(), limit=1.5)
    assert winner == "opus"
    assert [name for name, _t in script.opened] == ["opus"]
    assert benches == ["opus"]
    text = text_of(messages)
    assert "HELLO" in text and "stopped writing" in text
    assert statuses(messages) == [200]


def test_last_rung_silence_is_not_benched():
    settings = cfg(floor_s=0.12, ping_s=0.05, gap_s=2)
    benches = []
    winner, messages, script = run(race(
        ["opus", "last"],
        {"opus": [(5.0, start())], "last": [(5.0, start())]},
        settings, benches,
    ))
    assert winner is None
    assert benches == ["opus"]
    assert "the model stayed silent" in text_of(messages)
    assert statuses(messages) == [200]


def test_hard_failure_benches_immediately_and_a_bad_request_does_not():
    settings = cfg(floor_s=0.8)
    benches = []
    _winner, messages, script = run(race(
        ["opus", "flash"],
        {"opus": [(0.0, start(500))],
         "flash": [(0.0, start()), (0.0, body(text_delta("NEXT"))), (0.0, end())]},
        settings, benches,
    ))
    assert benches == ["opus"]
    assert "NEXT" in text_of(messages)
    assert script.opened[1][1] - script.opened[0][1] < 0.25

    benches = []
    _winner, messages, script = run(race(
        ["opus", "flash"],
        {"opus": [(0.0, start(400))],
         "flash": [(0.0, start()), (0.0, body(text_delta("AFTER400"))), (0.0, end())]},
        settings, benches,
    ))
    assert benches == []
    assert "AFTER400" in text_of(messages)
    assert script.opened[1][1] - script.opened[0][1] < 0.25


def test_dropped_connection_does_not_bench():
    settings = cfg(floor_s=0.8)
    benches = []
    _winner, messages, script = run(race(
        ["opus", "flash"],
        {"opus": [], "flash": [(0.0, start()), (0.0, body(text_delta("UP"))), (0.0, end())]},
        settings, benches,
    ))
    assert benches == []
    assert "UP" in text_of(messages)
    assert [name for name, _t in script.opened] == ["opus", "flash"]


def test_third_rung_starts_when_two_silent_attempts_fill_the_cap():
    settings = cfg(floor_s=0.15, max_inflight=2)
    benches = []
    winner, messages, script = run(race(
        ["a", "b", "c"],
        {
            "a": [(5.0, start())],
            "b": [(5.0, start())],
            "c": [(0.02, start()), (0.0, body(text_delta("THIRD"))), (0.0, end())],
        },
        settings, benches,
    ))
    assert winner == "c"
    assert [name for name, _t in script.opened] == ["a", "b", "c"]
    assert benches == ["a"]
    assert "THIRD" in text_of(messages)


def test_every_hard_failure_is_502_before_any_client_bytes():
    settings = cfg(floor_s=0.8, ping_s=30)
    benches = []
    winner, messages, _script = run(race(
        ["opus", "last"],
        {"opus": [(0.0, start(500))], "last": [(0.0, start(503))]},
        settings, benches,
    ))
    assert winner is None
    assert benches == ["opus"]
    assert statuses(messages) == [502]
    assert "every model in the chain failed" in text_of(messages)


def test_ping_while_waiting_is_not_answer_text():
    settings = cfg(floor_s=0.8, ping_s=0.05)
    benches = []
    _winner, messages, _script = run(race(
        ["opus", "flash"],
        {"opus": [(0.25, start()), (0.0, body(text_delta("HELLO"))), (0.0, end())]},
        settings, benches,
    ))
    text = text_of(messages)
    assert text.find(": ping") != -1 and text.find(": ping") < text.find("HELLO")
    assert statuses(messages) == [200]
    assert benches == []


def test_disabled_handle_does_not_read_the_body():
    calls = {"n": 0}

    async def receive():
        calls["n"] += 1
        return {"type": "http.request", "body": b"{}", "more_body": False}

    async def send(_msg):
        raise AssertionError("sent")

    async def inner(_scope, _receive, _send):
        raise AssertionError("inner")

    async def go():
        return await sh.handle(
            post_scope(), receive, send, inner, settings=sh.Settings(enabled=False),
        )

    assert run(go()) is False
    assert calls["n"] == 0

    async def inner_header():
        scope = post_scope(headers=[(b"x-ccl-stall-inner", b"1")])
        return await sh.handle(scope, receive, send, inner, settings=cfg())

    assert run(inner_header()) is False
    assert calls["n"] == 0


def test_passthrough_keeps_the_original_body():
    original = json.dumps({"model": "opus", "stream": True, "messages": [{"role": "user", "content": "hi"}]}).encode()

    async def scenario(body, chain, stream_body=None):
        seen = {}

        async def inner(_scope, receive, send):
            msg = await receive()
            seen["body"] = msg["body"]
            seen["headers"] = list(_scope.get("headers") or [])
            await send(start())
            await send(end())

        messages, send = client()
        payload = stream_body if stream_body is not None else body
        ok = await sh.handle(
            post_scope(), once(payload), send, inner, settings=cfg(),
            book=sh.RungBook(30, 600), ewma=sh.Ewma(),
            chain_for_fn=lambda _model: chain, router_benched=lambda _n: False,
        )
        return ok, seen, messages

    ok, seen, _messages = run(scenario(original, ["opus"]))
    assert ok is True and seen["body"] == original

    not_stream = json.dumps({"model": "opus", "messages": []}).encode()
    ok, seen, _messages = run(scenario(original, ["opus", "flash"], stream_body=not_stream))
    assert ok is True and seen["body"] == not_stream

    ok, seen, _messages = run(scenario(b"not-json", ["opus", "flash"], stream_body=b"not-json"))
    assert ok is True and seen["body"] == b"not-json"


def _speaking(name_ok, word):
    async def inner(scope, receive, _send):
        msg = await receive()
        payload = json.loads(msg["body"])
        headers = {k.lower(): v for k, v in scope.get("headers") or []}
        inner.calls.append((payload, time.monotonic(), headers))
        assert payload["disable_fallbacks"] is True
        assert payload["stream"] is True
        assert headers[b"x-ccl-stall-inner"] == b"1"
        name = payload["model"]
        if name == name_ok:
            await _send(start())
            await _send(body(message_start("msg_" + name) + text_delta(word)))
            await _send(end())
            return
        await _send(start())
        await _send(body(message_start("msg_" + name)))
        await asyncio.sleep(5)

    inner.calls = []
    return inner


def test_handle_races_a_silent_primary_and_rewrites_the_inner_call():
    book = sh.RungBook(30, 600)
    ewma = sh.Ewma()
    inner = _speaking("flash", "FALLBACK_WORD")
    messages, send = client()
    payload = json.dumps({"model": "opus", "stream": True, "messages": [{"role": "user", "content": "plan"}]}).encode()

    async def go():
        return await sh.handle(
            post_scope("/anthropic/v1/messages"), once(payload), send, inner,
            settings=cfg(floor_s=0.2, ping_s=30), book=book, ewma=ewma,
            chain_for_fn=lambda model: [model, "flash"],
            router_benched=lambda _n: False,
        )

    assert run(go()) is True
    models = [call[0]["model"] for call in inner.calls]
    assert models == ["opus", "flash"]
    assert inner.calls[1][1] - inner.calls[0][1] >= 0.12
    text = text_of(messages)
    assert "FALLBACK_WORD" in text and "msg_opus" not in text
    assert book.level.get("opus") == 1
    assert "opus" not in ewma.values and "flash" in ewma.values
    assert statuses(messages) == [200]


def test_benched_primary_is_skipped_until_the_bench_ends():
    book = sh.RungBook(30, 600)
    book.mark_slow("opus", time.monotonic())
    inner = _speaking("flash", "SKIPPED")
    messages, send = client()
    payload = json.dumps({"model": "opus", "stream": True, "messages": []}).encode()

    async def go():
        return await sh.handle(
            post_scope(), once(payload), send, inner, settings=cfg(floor_s=0.4),
            book=book, ewma=sh.Ewma(),
            chain_for_fn=lambda _m: ["opus", "flash", "last"],
            router_benched=lambda _n: False,
        )

    assert run(go()) is True
    assert [call[0]["model"] for call in inner.calls] == ["flash"]
    assert "SKIPPED" in text_of(messages)

    book.until["opus"] = time.monotonic() - 1
    book.level["opus"] = 3
    inner2 = _speaking("opus", "BACK")
    messages, send = client()

    async def again():
        return await sh.handle(
            post_scope(), once(payload), send, inner2, settings=cfg(floor_s=0.4),
            book=book, ewma=sh.Ewma(),
            chain_for_fn=lambda _m: ["opus", "flash", "last"],
            router_benched=lambda _n: False,
        )

    assert run(again()) is True
    assert [call[0]["model"] for call in inner2.calls] == ["opus"]
    assert "BACK" in text_of(messages)
    assert "opus" not in book.level


def test_sitecustomize_wires_the_race_to_the_original_app():
    src = (ROOT / "shared" / "litellm" / "sitecustomize.py").read_text(encoding="utf-8")
    assert "import stall_hedge" in src
    assert "/v1/messages" in src and "/anthropic/v1/messages" in src
    assert "_o(self, sc, rc, sd)" in src
