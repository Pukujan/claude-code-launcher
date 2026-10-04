"""Real web results for Claude Code's WebSearch tool, no API key.

Claude Code's WebSearch asks for Anthropic's server-side web_search tool, which
the InferHub/CKFF models can't run, so searches came back empty. LiteLLM's
websearch_interception callback (switched on in runtime.yaml by
merge_litellm_config.py) swaps that tool for a normal one and runs the search
itself through the configured search_tools. Its stock "duckduckgo" provider
calls DuckDuckGo's Instant Answer API, which only knows encyclopedia topics and
returns nothing for normal queries, so this sends duckduckgo searches through
the ddgs package instead. Other search providers are left alone.
"""
import asyncio
import re
import time

DEFAULT_MAX_RESULTS = 8
# Scraped engines come back empty now and then (rate limits). In testing Yahoo
# answered most often and ddgs's "auto" mix (DuckDuckGo, Brave, Google, ...)
# filled most of the gaps, so try those in turn, then Yahoo once more.
BACKENDS = ("yahoo", "auto", "yahoo")
# LiteLLM answers Claude Code's search-only request without calling the model and
# searches for the whole user message, which is this prompt around the query.
_CLAUDE_CODE_PROMPT = re.compile(r"^\s*perform a web search for the query:\s*", re.I)


def _search(query, max_results):
    from ddgs import DDGS
    from litellm.llms.base_llm.search.transformation import SearchResponse, SearchResult

    results, seen = [], set()
    for q in query if isinstance(query, list) else [query]:
        q = _CLAUDE_CODE_PROMPT.sub("", str(q)).strip()
        if not q:
            continue
        hits = []
        for i, backend in enumerate(BACKENDS):
            if i:
                time.sleep(1)
            try:
                hits = DDGS().text(q, max_results=max_results, backend=backend) or []
            except Exception as e:  # ddgs raises when it finds nothing
                print(f"[web_search] {backend}: no results for {q!r}: {e}", flush=True)
            if hits:
                break
        for h in hits:
            url = h.get("href")
            if url and url not in seen:
                seen.add(url)
                results.append(SearchResult(title=h.get("title") or url, url=url,
                                            snippet=h.get("body") or "", date=None, last_updated=None))
    return SearchResponse(results=results, object="search")


def install():
    import ddgs  # noqa: F401  fail here, not mid-request, if it's missing
    import litellm

    orig = litellm.asearch
    if getattr(orig, "_ccl_ddgs", False):
        return

    async def asearch(*args, **kwargs):
        if kwargs.get("search_provider") != "duckduckgo":
            return await orig(*args, **kwargs)
        query = kwargs.get("query", args[0] if args else "")
        return await asyncio.to_thread(_search, query, kwargs.get("max_results") or DEFAULT_MAX_RESULTS)

    asearch._ccl_ddgs = True
    litellm.asearch = asearch
    print("[sitecustomize] web search via ddgs installed", flush=True)
