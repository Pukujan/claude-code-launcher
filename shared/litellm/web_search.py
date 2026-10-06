"""Real web results for Claude Code's WebSearch tool, no API key.

Claude Code's WebSearch asks for Anthropic's server-side web_search tool, which
the InferHub/CKFF models can't run, so searches came back empty. LiteLLM's
websearch_interception callback (switched on in runtime.yaml by
merge_litellm_config.py) swaps that tool for a normal one and runs the search
itself through the configured search_tools. Its stock "duckduckgo" provider
calls DuckDuckGo's Instant Answer API, which only knows encyclopedia topics and
returns nothing for normal queries, so this sends duckduckgo searches through
a chain of backends instead. Other search providers are left alone.

The chain (CCL_WEB_SEARCH_CHAIN; default: tinyfish when TINYFISH_API_KEY is set,
then ddgs, then you_com) is tried in order until one returns results with a URL:
  ddgs      keyless scraping through the ddgs package. Several engines, tried
            one by one (CCL_DDGS_BACKENDS), then once more after a back-off.
  <other>   any LiteLLM search provider, e.g. searxng (SEARXNG_API_BASE),
            tinyfish (TINYFISH_API_KEY), you_com (keyless free tier when
            YOUCOM_API_KEY is unset), brave (BRAVE_API_KEY), tavily, serper,
            exa_ai. LiteLLM reads their own keys and base URLs from the
            environment; nothing is passed from here.
Scraped engines refuse requests now and then (rate limits), so a single engine
is never trusted. Results are cached for a few minutes. When every backend
fails, this raises instead of returning an empty list, so Claude Code sees
"Search failed: ..." with the reasons rather than a silent results=[].

Claude Code counts a search only when the answer carries Anthropic's native
server_tool_use + web_search_tool_result blocks ("Did N searches"). LiteLLM
1.103.0 answers the search-only request without a model but swaps the native
tool for litellm_web_search first, so it sent text only and every search read
"Did 0 searches" (issue #77). install_native_blocks() puts the native tool
back for that answer, adds usage.server_tool_use.web_search_requests, and
streams the blocks the way Anthropic does.
"""
import json
import asyncio
import os
import re
import threading
import time

DEFAULT_MAX_RESULTS = 8
# Yahoo answered most often in testing; DuckDuckGo's HTML page and ddgs's
# "auto" mix (Wikipedia, Grokipedia, Startpage, Brave, Google, ...) fill gaps.
DEFAULT_BACKENDS = ("yahoo", "duckduckgo", "auto")
# Pause before each round of backends: none, then one back-off.
ROUND_DELAYS = (0.0, 2.0)
# Stop starting new attempts once a search has run this long (seconds).
DEADLINE = 20.0
CACHE_TTL = 600.0
CACHE_MAX = 256
# Parallel searches from one Claude Code turn look like a burst to the engines.
_DDGS_SLOTS = threading.BoundedSemaphore(2)
# LiteLLM answers Claude Code's search-only request without calling the model and
# searches for the whole user message, which is this prompt around the query.
_CLAUDE_CODE_PROMPT = re.compile(r"^\s*perform a web search for the query:\s*", re.I)

_cache = {}
_cache_lock = threading.Lock()


class WebSearchUnavailable(Exception):
    """Every backend failed or found nothing; the message says why."""


def _log(msg):
    print(f"[web_search] {time.strftime('%H:%M:%S')} {msg}", flush=True)


def clean_query(q):
    return _CLAUDE_CODE_PROMPT.sub("", str(q)).strip()


# Short names for LiteLLM search providers, so CCL_WEB_SEARCH_CHAIN can say `exa`.
PROVIDER_ALIASES = {"exa": "exa_ai", "youcom": "you_com", "you": "you_com"}


def default_chain(env):
    """No CCL_WEB_SEARCH_CHAIN (issue #61): TinyFish only when its key is set, then
    keyless ddgs, then You.com's keyless free tier."""
    chain = ["tinyfish"] if (env.get("TINYFISH_API_KEY") or "").strip() else []
    return chain + ["ddgs", "you_com"]


def chain_from_env(env=None):
    env = os.environ if env is None else env
    raw = (env.get("CCL_WEB_SEARCH_CHAIN") or "").strip()
    if not raw:
        return default_chain(env)
    chain = [p.strip().lower() for p in raw.split(",") if p.strip()]
    chain = [PROVIDER_ALIASES.get(p, p) for p in chain]
    return [p for p in chain if p != "duckduckgo"] or ["ddgs"]  # duckduckgo would loop back here


def backends_from_env(env=None):
    env = os.environ if env is None else env
    raw = env.get("CCL_DDGS_BACKENDS")
    if not raw:
        return DEFAULT_BACKENDS
    return tuple(b.strip() for b in raw.split(",") if b.strip()) or DEFAULT_BACKENDS


def _usable(hits):
    """Keep hits that have a URL. An engine can return items without one (a
    block or "no results" page parsed as results); those count as nothing."""
    out = []
    for h in hits or []:
        url = (h.get("href") or h.get("url") or "") if isinstance(h, dict) else ""
        if url.startswith(("http://", "https://")):
            out.append({"title": h.get("title") or url, "url": url, "snippet": h.get("body") or h.get("snippet") or ""})
    return out


def ddgs_search(q, max_results, *, backends=DEFAULT_BACKENDS, delays=ROUND_DELAYS, deadline=DEADLINE,
                text=None, sleep=time.sleep, clock=time.monotonic):
    """Try each ddgs backend, then again after a back-off. Returns (hits, errors)."""
    if text is None:
        from ddgs import DDGS

        def text(query, backend):
            return DDGS(timeout=5).text(query, max_results=max_results, backend=backend)

    start, errors = clock(), []
    for rnd, delay in enumerate(delays):
        if rnd and clock() - start + delay > deadline:
            break
        if delay:
            sleep(delay)
        for backend in backends:
            if clock() - start > deadline:
                errors.append("deadline reached")
                return [], errors
            t = clock()
            try:
                with _DDGS_SLOTS:
                    raw = text(q, backend) or []
            except Exception as e:  # ddgs raises when it finds nothing or is refused
                errors.append(f"ddgs/{backend}: {type(e).__name__}: {e}")
                _log(f"ddgs/{backend} failed in {clock() - t:.1f}s for {q!r}: {type(e).__name__}: {e}")
                continue
            hits = _usable(raw)
            if hits:
                _log(f"ddgs/{backend} ok: {len(hits)} results in {clock() - t:.1f}s for {q!r}")
                return hits[:max_results], errors
            errors.append(f"ddgs/{backend}: {len(raw)} results without a URL")
            _log(f"ddgs/{backend} gave {len(raw)} results without a URL for {q!r}")
    return [], errors


def _cache_get(key, now):
    with _cache_lock:
        hit = _cache.get(key)
        if hit and now - hit[0] < CACHE_TTL:
            return hit[1]
        _cache.pop(key, None)
        return None


def _cache_put(key, hits, now):
    with _cache_lock:
        if len(_cache) >= CACHE_MAX:
            for k in sorted(_cache, key=lambda k: _cache[k][0])[: CACHE_MAX // 4]:
                _cache.pop(k, None)
        _cache[key] = (now, hits)


async def search_one(q, max_results, *, chain, orig=None, ddgs=None, kwargs=None):
    """Run one query down the chain. Returns hits or raises WebSearchUnavailable."""
    key = (q.lower(), max_results)
    cached = _cache_get(key, time.monotonic())
    if cached is not None:
        _log(f"cache hit: {len(cached)} results for {q!r}")
        return cached
    ddgs = ddgs or (lambda query, n: ddgs_search(query, n, backends=backends_from_env()))
    errors = []
    for provider in chain:
        if provider == "ddgs":
            hits, errs = await asyncio.to_thread(ddgs, q, max_results)
            errors += errs
        else:
            if orig is None:
                errors.append(f"{provider}: no LiteLLM search function")
                continue
            t = time.monotonic()
            try:
                resp = await orig(query=q, search_provider=provider, max_results=max_results, **(kwargs or {}))
            except Exception as e:
                errors.append(f"{provider}: {type(e).__name__}: {e}")
                _log(f"{provider} failed for {q!r}: {type(e).__name__}: {e}")
                continue
            raw = getattr(resp, "results", None) or []
            hits = [{"title": getattr(r, "title", "") or getattr(r, "url", ""), "url": getattr(r, "url", "") or "",
                     "snippet": getattr(r, "snippet", "") or ""}
                    for r in raw]
            hits = [h for h in hits if h["url"].startswith(("http://", "https://"))]
            if hits:
                _log(f"{provider} ok: {len(hits)} results in {time.monotonic() - t:.1f}s for {q!r}")
            else:
                errors.append(f"{provider}: no results")
                _log(f"{provider} gave 0 usable results ({len(raw)} returned) in {time.monotonic() - t:.1f}s for {q!r}")
        if hits:
            _cache_put(key, hits, time.monotonic())
            return hits
    _log(f"FAILED for {q!r}: " + "; ".join(errors))
    raise WebSearchUnavailable(
        f"web search found nothing for {q!r} (every backend failed; try again or rephrase): " + "; ".join(errors[-6:])
    )


async def run_search(query, max_results, *, chain, orig=None, ddgs=None, kwargs=None):
    """All queries of one request, as a LiteLLM SearchResponse."""
    from litellm.llms.base_llm.search.transformation import SearchResponse, SearchResult

    queries = [clean_query(q) for q in (query if isinstance(query, list) else [query])]
    queries = [q for q in queries if q]
    results, seen, failures = [], set(), []
    for q in queries:
        try:
            hits = await search_one(q, max_results, chain=chain, orig=orig, ddgs=ddgs, kwargs=kwargs)
        except WebSearchUnavailable as e:
            failures.append(e)
            continue
        for h in hits:
            if h["url"] not in seen:
                seen.add(h["url"])
                results.append(SearchResult(title=h["title"], url=h["url"], snippet=h["snippet"],
                                            date=None, last_updated=None))
    if not results and failures:
        raise failures[0]
    return SearchResponse(results=results, object="search")


# --- Native blocks for Claude Code's search-only request (issue #77) ---

# Set by LiteLLM's websearch_interception pre-request hook when the client sent
# an Anthropic-native web_search_* tool.
EMIT_NATIVE_FLAG = "_websearch_interception_emit_native_blocks"
NATIVE_SEARCH_TOOL = {"type": "web_search_20250305", "name": "web_search"}


def add_search_usage(resp):
    """Set usage.server_tool_use.web_search_requests to the number of
    web_search_tool_result blocks that hold results (error blocks count 0)."""
    n = sum(1 for b in resp.get("content") or []
            if isinstance(b, dict) and b.get("type") == "web_search_tool_result" and isinstance(b.get("content"), list))
    usage = dict(resp.get("usage") or {})
    stu = dict(usage.get("server_tool_use") or {})
    stu["web_search_requests"] = n
    usage["server_tool_use"] = stu
    resp["usage"] = usage
    return resp


def _clean_server_tool_queries(resp):
    for b in resp.get("content") or []:
        if isinstance(b, dict) and b.get("type") == "server_tool_use" and isinstance(b.get("input"), dict):
            q = b["input"].get("query")
            if isinstance(q, str):
                b["input"] = {**b["input"], "query": clean_query(q)}
    return resp


def _sse(event):
    return f"event: {event['type']}\ndata: {json.dumps(event)}\n\n".encode()


def sse_chunks(resp):
    """The whole answer as Anthropic SSE events. server_tool_use starts with an
    empty input and gets it as one input_json_delta (as Anthropic streams it);
    web_search_tool_result arrives whole in its content_block_start; usage,
    with server_tool_use, rides on message_delta as well as message_start."""
    usage = resp.get("usage") or {}
    out = [_sse({"type": "message_start", "message": {
        "id": resp.get("id"), "type": "message", "role": resp.get("role", "assistant"), "model": resp.get("model"),
        "content": [], "stop_reason": None, "stop_sequence": None,
        "usage": {**usage, "output_tokens": 0}}})]
    for i, b in enumerate(resp.get("content") or []):
        kind = b.get("type")
        if kind == "text":
            out.append(_sse({"type": "content_block_start", "index": i, "content_block": {"type": "text", "text": ""}}))
            out.append(_sse({"type": "content_block_delta", "index": i,
                             "delta": {"type": "text_delta", "text": b.get("text", "")}}))
        elif kind in ("server_tool_use", "tool_use"):
            out.append(_sse({"type": "content_block_start", "index": i,
                             "content_block": {"type": kind, "id": b.get("id"), "name": b.get("name"), "input": {}}}))
            out.append(_sse({"type": "content_block_delta", "index": i,
                             "delta": {"type": "input_json_delta", "partial_json": json.dumps(b.get("input") or {})}}))
        else:
            out.append(_sse({"type": "content_block_start", "index": i, "content_block": b}))
        out.append(_sse({"type": "content_block_stop", "index": i}))
    out.append(_sse({"type": "message_delta",
                     "delta": {"stop_reason": resp.get("stop_reason"), "stop_sequence": resp.get("stop_sequence")},
                     "usage": usage}))
    out.append(_sse({"type": "message_stop"}))
    return out


def wrap_short_circuit(orig, *, is_native, is_search, flag=EMIT_NATIVE_FLAG, stream_cls):
    """Wrap LiteLLM's _try_websearch_short_circuit(model, messages, tools,
    custom_llm_provider, stream, kwargs). When the client sent a native tool
    (flag set) but the hook already swapped it, hand the native tool back so
    LiteLLM emits server_tool_use + web_search_tool_result; then add the usage
    count and build the stream ourselves (LiteLLM's drops the usage)."""

    async def short_circuit(model, messages, tools, custom_llm_provider, stream, kwargs=None):
        flagged = bool((kwargs or {}).get(flag))
        if flagged and tools and not any(is_native(t) for t in tools):
            restored, done = [], False
            for t in tools:
                if is_search(t):
                    if not done:
                        restored.append(dict(NATIVE_SEARCH_TOOL))
                        done = True
                else:
                    restored.append(t)
            tools = restored
        resp = await orig(model=model, messages=messages, tools=tools, custom_llm_provider=custom_llm_provider,
                          stream=False, kwargs=kwargs)
        if resp is None:
            return None
        if flagged or any(isinstance(b, dict) and b.get("type") == "web_search_tool_result"
                          for b in resp.get("content") or []):
            resp = add_search_usage(_clean_server_tool_queries(resp))
            _log(f"search answer: {resp['usage']['server_tool_use']['web_search_requests']} native result block(s)")
        return stream_cls(resp) if stream else resp

    short_circuit._ccl_native_blocks = True
    return short_circuit


def install_native_blocks(handler_mod, *, is_native, is_search, flag=EMIT_NATIVE_FLAG, stream_cls):
    """Patch handler_mod._try_websearch_short_circuit once. Returns True if patched."""
    orig = getattr(handler_mod, "_try_websearch_short_circuit", None)
    if orig is None or getattr(orig, "_ccl_native_blocks", False):
        return False
    handler_mod._try_websearch_short_circuit = wrap_short_circuit(
        orig, is_native=is_native, is_search=is_search, flag=flag, stream_cls=stream_cls)
    return True


def _install_litellm_native_blocks():
    from litellm.integrations.websearch_interception import handler as wi_handler
    from litellm.integrations.websearch_interception.tools import (
        is_anthropic_native_web_search_tool,
        is_web_search_tool,
    )
    from litellm.llms.anthropic.experimental_pass_through.messages import handler as msg_handler
    from litellm.llms.anthropic.experimental_pass_through.messages.fake_stream_iterator import (
        FakeAnthropicMessagesStreamIterator,
    )

    class _NativeSearchStream(FakeAnthropicMessagesStreamIterator):
        def _create_streaming_chunks(self):
            return sse_chunks(dict(self.response))

    flag = getattr(wi_handler, "WEBSEARCH_EMIT_NATIVE_BLOCKS_KEY", EMIT_NATIVE_FLAG)
    return install_native_blocks(msg_handler, is_native=is_anthropic_native_web_search_tool,
                                 is_search=is_web_search_tool, flag=flag, stream_cls=_NativeSearchStream)


def install():
    import ddgs  # noqa: F401  fail here, not mid-request, if it's missing
    import litellm

    try:
        if _install_litellm_native_blocks():
            print("[sitecustomize] WebSearch answers carry native web_search_tool_result blocks", flush=True)
    except Exception as e:  # a LiteLLM without these pieces: keep the text-only answer
        print(f"[sitecustomize] native WebSearch blocks not installed: {type(e).__name__}: {e}", flush=True)

    orig = litellm.asearch
    if getattr(orig, "_ccl_ddgs", False):
        return
    chain = chain_from_env()

    async def asearch(*args, **kwargs):
        if kwargs.get("search_provider") != "duckduckgo":
            return await orig(*args, **kwargs)
        query = kwargs.get("query", args[0] if args else "")
        return await run_search(query, kwargs.get("max_results") or DEFAULT_MAX_RESULTS, chain=chain, orig=orig)

    asearch._ccl_ddgs = True
    litellm.asearch = asearch
    print(f"[sitecustomize] web search via {' -> '.join(chain)} installed (ddgs backends: "
          f"{', '.join(backends_from_env())})", flush=True)
