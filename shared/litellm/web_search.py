"""Real web results for Claude Code's WebSearch tool, no API key.

Claude Code's WebSearch asks for Anthropic's server-side web_search tool, which
the InferHub/CKFF models can't run, so searches came back empty. LiteLLM's
websearch_interception callback (switched on in runtime.yaml by
merge_litellm_config.py) swaps that tool for a normal one and runs the search
itself through the configured search_tools. Its stock "duckduckgo" provider
calls DuckDuckGo's Instant Answer API, which only knows encyclopedia topics and
returns nothing for normal queries, so this sends duckduckgo searches through
a chain of backends instead. Other search providers are left alone.

The chain (CCL_WEB_SEARCH_CHAIN, default "ddgs") is tried in order until one
returns results with a URL:
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
"""
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


def chain_from_env(env=None):
    env = os.environ if env is None else env
    raw = env.get("CCL_WEB_SEARCH_CHAIN") or "ddgs"
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


def install():
    import ddgs  # noqa: F401  fail here, not mid-request, if it's missing
    import litellm

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
