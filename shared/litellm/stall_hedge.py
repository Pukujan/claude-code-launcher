"""Race the next slot model when the one in front stays silent.

A fallback model cannot continue another model's generation. It has to re-read
the prompt. This holds the client stream until one attempt produces a content
token, then releases that attempt only. The quiet model is benched and is
offered the next real call again after the bench expires (issue #109, parent #53).

CCL_STALL_HEDGE=0 turns the race off. The live proxy on port 4000 is not
what this module binds; the launcher installs the hook, and a running proxy
picks it up on its next start.
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import time
from dataclasses import dataclass

INNER_HEADER = b"x-ccl-stall-inner"
MESSAGES_PATHS = ("/v1/messages", "/anthropic/v1/messages")
STREAM_HEADERS = [
    (b"content-type", b"text/event-stream"),
    (b"cache-control", b"no-cache"),
]


@dataclass(frozen=True)
class Settings:
    enabled: bool = True
    floor_s: float = 20.0
    cap_s: float = 90.0
    mult: float = 1.5
    bench_s: float = 30.0
    bench_cap_s: float = 600.0
    ping_s: float = 5.0
    gap_s: float = 120.0
    max_inflight: int = 2


def settings_from_env(env=None) -> Settings:
    env = os.environ if env is None else env

    def num(name, default, lo, hi):
        raw = (env.get(name) or "").strip()
        if not raw:
            return default
        try:
            value = float(raw)
        except ValueError:
            return default
        if not lo <= value <= hi:
            return default
        return value

    flag = (env.get("CCL_STALL_HEDGE") or "1").strip().lower()
    return Settings(
        enabled=flag not in ("0", "false", "off", "no"),
        floor_s=num("CCL_STALL_FLOOR_S", 20.0, 0.01, 600.0),
        cap_s=num("CCL_STALL_CAP_S", 90.0, 0.01, 600.0),
        mult=num("CCL_STALL_MULT", 1.5, 1.0, 10.0),
        bench_s=num("CCL_STALL_BENCH_S", 30.0, 1.0, 3600.0),
        bench_cap_s=num("CCL_STALL_BENCH_CAP_S", 600.0, 1.0, 86400.0),
        ping_s=num("CCL_STALL_PING_S", 5.0, 0.01, 60.0),
        gap_s=num("CCL_STALL_GAP_S", 120.0, 0.01, 600.0),
    )


class Ewma:
    """Successful time-to-first-token only. Abandoned calls stay out of the average."""

    def __init__(self, alpha: float = 0.3):
        self.alpha = alpha
        self.values: dict[str, float] = {}

    def observe(self, name: str, sample: float) -> None:
        prev = self.values.get(name)
        self.values[name] = sample if prev is None else self.alpha * sample + (1.0 - self.alpha) * prev

    def budget(self, name: str, settings: Settings) -> float:
        sample = self.values.get(name)
        if sample is None:
            return settings.floor_s
        return min(settings.cap_s, max(settings.floor_s, sample * settings.mult))


class RungBook:
    """Per-rung bench. The first silence is bench_s; the next doubles, up to bench_cap_s."""

    def __init__(self, base_s: float, cap_s: float):
        self.base_s = base_s
        self.cap_s = cap_s
        self.level: dict[str, int] = {}
        self.until: dict[str, float] = {}

    def available(self, name: str, now: float) -> bool:
        return now >= self.until.get(name, 0.0)

    def mark_slow(self, name: str, now: float) -> float:
        level = self.level.get(name, 0) + 1
        self.level[name] = level
        delay = min(self.cap_s, self.base_s * (2 ** (level - 1)))
        self.until[name] = now + delay
        return delay

    def mark_recovered(self, name: str) -> None:
        self.level.pop(name, None)
        self.until.pop(name, None)


def chain_for(model: str, fallbacks) -> list[str]:
    """Preferred model, then the rungs listed for it. Unknown names are a chain of one."""
    for entry in fallbacks or []:
        if isinstance(entry, dict) and model in entry:
            rest = [r for r in (entry.get(model) or []) if isinstance(r, str) and r and r != model]
            return [model, *rest]
    return [model] if model else []


def eligible(chain: list[str], book: RungBook, now: float, router_benched) -> list[str]:
    """Skip a benched rung. The last rung is always eligible, so a chain can still answer."""
    if not chain:
        return []
    last = chain[-1]
    out = []
    for name in chain:
        if name == last or (book.available(name, now) and not router_benched(name)):
            out.append(name)
    return out


class Assembler:
    def __init__(self):
        self.buf = ""

    def feed(self, data: bytes) -> list[str]:
        if not data:
            return []
        self.buf += data.decode("utf-8", "replace")
        ready = []
        while "\n\n" in self.buf:
            block, self.buf = self.buf.split("\n\n", 1)
            if block.strip():
                ready.append(block + "\n\n")
        return ready


def event_kind(block: str) -> str:
    """content once the model is actually writing. message_start and pings are not."""
    stripped = block.lstrip()
    if stripped.startswith(":"):
        return "ping"
    event = ""
    data_lines = []
    for line in block.splitlines():
        if line.startswith("event:"):
            event = line.split(":", 1)[1].strip()
        elif line.startswith("data:"):
            data_lines.append(line.split(":", 1)[1].strip())
    if event == "ping":
        return "ping"
    if event in ("content_block_start", "content_block_delta"):
        return "content"
    if not data_lines:
        return "other"
    try:
        obj = json.loads("".join(data_lines))
    except json.JSONDecodeError:
        return "other"
    if not isinstance(obj, dict):
        return "other"
    if obj.get("type") in ("content_block_start", "content_block_delta"):
        return "content"
    if obj.get("type") == "error":
        return "error"
    delta = obj.get("delta")
    if isinstance(delta, dict) and delta.get("type") in ("text_delta", "thinking_delta", "input_json_delta"):
        return "content"
    return "other"


class Attempt:
    def __init__(self, name: str, queue: asyncio.Queue, task: asyncio.Task, started: float):
        self.name = name
        self.queue = queue
        self.task = task
        self.started = started
        self.assembler = Assembler()
        self.held: list[str] = []
        self.status: int | None = None
        self.saw_content = False
        self.done = False
        self.failed = False

    def cancel(self) -> None:
        if not self.task.done():
            self.task.cancel()


def _status_exception(status: int):
    class _Status(Exception):
        def __init__(self):
            super().__init__(f"status {status}")
            self.status_code = status

    return _Status()


def should_bench_status(status: int | None) -> bool:
    """Same bench rule as hard failures: 429, 408 and 5xx. A bad request does not bench."""
    try:
        import bench_after_retries as bar
    except ImportError:
        if status is None:
            return False
        if status in (429, 408, 401, 404):
            return True
        return status >= 500
    return bar.should_bench(_status_exception(status if status is not None else 0))


async def _read_body(receive) -> bytes:
    chunks = []
    while True:
        message = await receive()
        if message.get("type") != "http.request":
            continue
        chunks.append(message.get("body") or b"")
        if not message.get("more_body", False):
            break
    return b"".join(chunks)


def _replay(body: bytes):
    pending = {"body": body}

    async def receive():
        body = pending.pop("body", b"")
        return {"type": "http.request", "body": body, "more_body": False}

    return receive


def wants(scope) -> bool:
    if scope.get("type") != "http":
        return False
    if str(scope.get("method", "GET")).upper() != "POST":
        return False
    if str(scope.get("path", "")) not in MESSAGES_PATHS:
        return False
    for key, value in scope.get("headers") or []:
        if key.lower() == INNER_HEADER and value == b"1":
            return False
    return True


def _copy_scope(scope, body_model_headers: bool) -> dict:
    copied = dict(scope)
    headers = [(k, v) for k, v in (scope.get("headers") or []) if k.lower() != INNER_HEADER]
    if body_model_headers:
        headers.append((INNER_HEADER, b"1"))
    copied["headers"] = headers
    return copied


async def run_race(
    order: list[str],
    open_attempt,
    *,
    budget_for,
    settings: Settings,
    send,
    on_bench,
    on_ttft,
    clock=time.monotonic,
):
    """Hold the client until one attempt writes content, then stream only that attempt.

    open_attempt(name) -> Attempt. on_bench(name) records a silence past that
    model's own budget, or a hard failure. Cancelling a hedge because another
    model spoke first does not bench it. The last name in *order* is never benched.
    """
    if not order:
        await _fail(send, False, "no model in the chain")
        return None

    last = order[-1]
    pending = list(order)
    inflight: dict[str, Attempt] = {}
    spawned: list[Attempt] = []
    client_started = False
    winner: Attempt | None = None
    last_ping = clock()

    async def ensure_client():
        nonlocal client_started, last_ping
        if client_started:
            return
        client_started = True
        last_ping = clock()
        await send({"type": "http.response.start", "status": 200, "headers": list(STREAM_HEADERS)})

    async def start_one():
        if not pending or len(inflight) >= settings.max_inflight:
            return
        name = pending.pop(0)
        attempt = await open_attempt(name)
        attempt.started = clock()
        inflight[name] = attempt
        spawned.append(attempt)

    def bench(name: str):
        if name == last:
            return
        on_bench(name)

    async def take(attempt: Attempt, message):
        if message is None:
            attempt.done = True
            if not attempt.saw_content:
                attempt.failed = True
            return
        kind = message.get("type")
        if kind == "http.response.start":
            attempt.status = int(message.get("status") or 0)
            if attempt.status >= 400:
                attempt.failed = True
                attempt.done = True
            return
        if kind != "http.response.body":
            return
        body = message.get("body") or b""
        if message.get("more_body") is False and not body:
            attempt.done = True
            if not attempt.saw_content:
                attempt.failed = True
            return
        for block in attempt.assembler.feed(body):
            kind = event_kind(block)
            if kind == "content" and not attempt.saw_content:
                attempt.saw_content = True
                on_ttft(attempt.name, max(0.0, clock() - attempt.started))
            elif kind == "error":
                attempt.failed = True
                attempt.done = True
            attempt.held.append(block)
        if message.get("more_body") is False:
            attempt.done = True

    try:
        await start_one()
        while True:
            for attempt in list(inflight.values()):
                while True:
                    try:
                        message = attempt.queue.get_nowait()
                    except asyncio.QueueEmpty:
                        break
                    await take(attempt, message)
                    # Leave the rest of this attempt queued. The winner's stream
                    # reads it, and a later silence is not the end of the reply.
                    if attempt.saw_content:
                        break

            for name, attempt in list(inflight.items()):
                if attempt.saw_content and winner is None:
                    winner = attempt
                elif attempt.failed and not attempt.saw_content and (attempt.done or attempt.status):
                    # A closed connection or a bad request moves on. Only a hard
                    # status (429/408/5xx) benches; silence is benched from the budget.
                    if attempt.status is not None and should_bench_status(attempt.status):
                        bench(name)
                    attempt.cancel()
                    inflight.pop(name, None)

            if winner is not None:
                now = clock()
                for name, attempt in list(inflight.items()):
                    if attempt is winner:
                        continue
                    if (not attempt.saw_content) and (now - attempt.started >= budget_for(attempt.name)):
                        bench(name)
                    attempt.cancel()
                await _stream_winner(winner, send, ensure_client, settings, clock, bench)
                return winner.name

            if pending and inflight:
                oldest = min(inflight.values(), key=lambda item: item.started)
                if clock() - oldest.started >= budget_for(oldest.name):
                    before = (len(inflight), len(pending))
                    if len(inflight) >= settings.max_inflight and not oldest.saw_content:
                        bench(oldest.name)
                        oldest.cancel()
                        inflight.pop(oldest.name, None)
                    await start_one()
                    if (len(inflight), len(pending)) != before:
                        continue

            if not inflight and pending:
                await start_one()
                continue

            if not inflight and not pending:
                await _fail(send, client_started, "every model in the chain failed")
                return None

            if inflight and not pending and all(
                (not item.saw_content) and (clock() - item.started >= budget_for(item.name))
                for item in inflight.values()
            ):
                for name, attempt in list(inflight.items()):
                    bench(name)
                    attempt.cancel()
                await _fail(send, client_started, "the model stayed silent")
                return None

            now = clock()
            if not client_started and inflight:
                oldest = min(inflight.values(), key=lambda item: item.started)
                if now - oldest.started >= min(settings.ping_s, budget_for(oldest.name)):
                    # Pings keep the client connection alive. They are not answer text,
                    # and they start only once this call is already waiting out a silence.
                    if now - oldest.started >= settings.ping_s:
                        await ensure_client()
                        await send({"type": "http.response.body", "body": b": ping\n\n", "more_body": True})
                        last_ping = clock()
            elif client_started and now - last_ping >= settings.ping_s:
                await send({"type": "http.response.body", "body": b": ping\n\n", "more_body": True})
                last_ping = clock()

            timeout = settings.ping_s
            if client_started:
                timeout = min(timeout, max(0.0, settings.ping_s - (clock() - last_ping)))
            soonest = None
            for item in inflight.values():
                remain = budget_for(item.name) - (clock() - item.started)
                if remain > 0 and (soonest is None or remain < soonest):
                    soonest = remain
            if soonest is not None:
                timeout = min(timeout, soonest)
            await _wait_progress(inflight, max(0.01, timeout))
    finally:
        await _settle(spawned)


async def _settle(attempts):
    """Finish cancelled upstream tasks so a lost attempt cannot keep running."""
    tasks = []
    for attempt in attempts:
        if not attempt.task.done():
            attempt.task.cancel()
        tasks.append(attempt.task)
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)


async def _wait_progress(inflight: dict, timeout: float):
    """Block until any attempt's queue has a message, or until *timeout*.

    Leave the message in the queue. Taking it out and putting it back sends
    the tail of the stream ahead of the head.
    """
    if timeout < 0:
        timeout = 0.0
    if not inflight:
        await asyncio.sleep(timeout)
        return
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while True:
        if any(item.queue.qsize() for item in inflight.values()):
            return
        remain = deadline - loop.time()
        if remain <= 0:
            return
        await asyncio.sleep(min(0.005, remain))


async def _stream_winner(winner: Attempt, send, ensure_client, settings: Settings, clock, bench):
    """Release the winner's buffered events, then keep its stream. A later silence ends the turn."""
    await ensure_client()
    if winner.held:
        payload = "".join(winner.held).encode("utf-8")
        await send({"type": "http.response.body", "body": payload, "more_body": True})
        winner.held.clear()
    # The race may already have read this attempt's completion while deciding
    # the winner. That is the end of the reply, not a silence.
    if winner.done and winner.queue.empty():
        await send({"type": "http.response.body", "body": b"", "more_body": False})
        return
    last_content = clock()
    while True:
        remain = settings.gap_s - (clock() - last_content)
        if remain <= 0:
            bench(winner.name)
            await send({
                "type": "http.response.body",
                "body": _error_sse("the model stopped writing"),
                "more_body": False,
            })
            winner.cancel()
            return
        try:
            message = await asyncio.wait_for(winner.queue.get(), timeout=remain)
        except asyncio.TimeoutError:
            bench(winner.name)
            await send({
                "type": "http.response.body",
                "body": _error_sse("the model stopped writing"),
                "more_body": False,
            })
            winner.cancel()
            return
        if message is None:
            await send({"type": "http.response.body", "body": b"", "more_body": False})
            return
        if message.get("type") != "http.response.body":
            continue
        body = message.get("body") or b""
        if any(event_kind(block) == "content" for block in winner.assembler.feed(body)):
            last_content = clock()
        await send({
            "type": "http.response.body",
            "body": body,
            "more_body": bool(message.get("more_body", True)),
        })
        if message.get("more_body") is False:
            return


def _error_sse(message: str) -> bytes:
    payload = json.dumps({"type": "error", "error": {"type": "api_error", "message": message}})
    return f"event: error\ndata: {payload}\n\n".encode("utf-8")


async def _fail(send, client_started: bool, message: str):
    if client_started:
        await send({"type": "http.response.body", "body": _error_sse(message), "more_body": False})
        return
    body = json.dumps({"type": "error", "error": {"type": "api_error", "message": message}}).encode("utf-8")
    await send({
        "type": "http.response.start",
        "status": 502,
        "headers": [(b"content-type", b"application/json")],
    })
    await send({"type": "http.response.body", "body": body, "more_body": False})


_SHARED = {"book": None, "ewma": None}


def shared_book(settings: Settings) -> RungBook:
    book = _SHARED["book"]
    if not isinstance(book, RungBook):
        _SHARED["book"] = RungBook(settings.bench_s, settings.bench_cap_s)
    return _SHARED["book"]


def shared_ewma() -> Ewma:
    if not isinstance(_SHARED["ewma"], Ewma):
        _SHARED["ewma"] = Ewma()
    return _SHARED["ewma"]


def _loaded_proxy():
    """The running proxy module, if this process already loaded it.

    Importing it from a request stalls the loop for seconds, and a unit test
    has no router to cool down.
    """
    return sys.modules.get("litellm.proxy.proxy_server")


def live_chain(model: str) -> list[str]:
    ps = _loaded_proxy()
    router = getattr(ps, "llm_router", None) if ps is not None else None
    return chain_for(model, getattr(router, "fallbacks", None))


def live_router_benched(name: str) -> bool:
    ps = _loaded_proxy()
    router = getattr(ps, "llm_router", None) if ps is not None else None
    if router is None:
        return False
    try:
        import bench_after_retries as bar

        return any(bar._is_benched(router, model_id) for model_id, _cd in bar._managed_deployments(router, name))
    except Exception:
        return False


def live_cooldown(name: str, seconds: float) -> None:
    ps = _loaded_proxy()
    router = getattr(ps, "llm_router", None) if ps is not None else None
    if router is None or getattr(router, "disable_cooldowns", False):
        return
    try:
        import bench_after_retries as bar
    except Exception:
        return
    cache = getattr(router, "cooldown_cache", None)
    if cache is None:
        return
    try:
        deps = bar._managed_deployments(router, name)
    except Exception:
        return
    for model_id, _cd in deps:
        try:
            cache.add_deployment_to_cooldown(
                model_id=model_id,
                original_exception=TimeoutError(name),
                exception_status=408,
                cooldown_time=seconds,
            )
        except Exception as exc:
            print(f"[stall] cooldown {name} failed: {exc}", flush=True)


def _enqueue(queue: asyncio.Queue):
    async def send(message):
        await queue.put(message)

    return send


async def open_upstream(inner, scope, payload: dict, name: str, clock) -> Attempt:
    """One rung, with router fallbacks turned off so this race decides the swap."""
    queue: asyncio.Queue = asyncio.Queue()
    rewritten = dict(payload)
    rewritten["model"] = name
    rewritten["stream"] = True
    rewritten["disable_fallbacks"] = True
    body = json.dumps(rewritten).encode("utf-8")
    scope2 = _copy_scope(scope, True)

    async def runner():
        try:
            await inner(scope2, _replay(body), _enqueue(queue))
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            print(f"[stall] {name} attempt failed: {exc}", flush=True)
        finally:
            try:
                queue.put_nowait(None)
            except Exception:
                pass

    task = asyncio.create_task(runner())
    return Attempt(name, queue, task, clock())


async def handle(scope, receive, send, inner, *, settings: Settings | None = None,
                 book: RungBook | None = None, ewma: Ewma | None = None,
                 chain_for_fn=None, router_benched=None, clock=time.monotonic) -> bool:
    """Race a streaming /v1/messages call. Return False when this request is not ours."""
    settings = settings_from_env() if settings is None else settings
    if not settings.enabled or not wants(scope):
        return False
    body = await _read_body(receive)
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        await inner(scope, _replay(body), send)
        return True
    if not isinstance(payload, dict) or payload.get("stream") is not True:
        await inner(scope, _replay(body), send)
        return True
    model = payload.get("model")
    if not isinstance(model, str) or not model:
        await inner(scope, _replay(body), send)
        return True
    chain = (chain_for_fn or live_chain)(model)
    book = shared_book(settings) if book is None else book
    ewma = shared_ewma() if ewma is None else ewma
    # A chain of one is the normal proxy path. A longer chain still races when
    # only the last rung is eligible, so a benched primary is not tried again.
    if len(chain) < 2:
        await inner(scope, _replay(body), send)
        return True
    order = eligible(chain, book, clock(), router_benched or live_router_benched)

    def on_bench(name: str):
        delay = book.mark_slow(name, clock())
        live_cooldown(name, delay)
        print(f"[stall] {name} stayed silent; benched for {delay:g}s", flush=True)

    def on_ttft(name: str, seconds: float):
        ewma.observe(name, seconds)
        book.mark_recovered(name)

    async def open_attempt(name: str):
        return await open_upstream(inner, scope, payload, name, clock)

    await run_race(
        order,
        open_attempt,
        budget_for=lambda name: ewma.budget(name, settings),
        settings=settings,
        send=send,
        on_bench=on_bench,
        on_ttft=on_ttft,
        clock=clock,
    )
    return True
