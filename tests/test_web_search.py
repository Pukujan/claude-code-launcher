"""Claude Code's WebSearch through web_search.py: retries, fallbacks, errors."""
import asyncio
import sys
import types
from dataclasses import dataclass, field

import pytest

import web_search as ws


@dataclass
class _Result:
    title: str
    url: str
    snippet: str
    date: object = None
    last_updated: object = None


@dataclass
class _Response:
    results: list = field(default_factory=list)
    object: str = "search"


@pytest.fixture(autouse=True)
def fake_litellm_types(monkeypatch):
    # CI has no LiteLLM; the hook only needs SearchResponse/SearchResult.
    mod = types.ModuleType("litellm.llms.base_llm.search.transformation")
    mod.SearchResponse, mod.SearchResult = _Response, _Result
    for name in ("litellm", "litellm.llms", "litellm.llms.base_llm", "litellm.llms.base_llm.search"):
        monkeypatch.setitem(sys.modules, name, sys.modules.get(name) or types.ModuleType(name))
    monkeypatch.setitem(sys.modules, "litellm.llms.base_llm.search.transformation", mod)
    ws._cache.clear()
    yield
    ws._cache.clear()


def hit(n):
    return {"title": f"t{n}", "href": f"https://example.com/{n}", "body": f"b{n}"}


class Script:
    """A fake ddgs text(): answers per call from a list, records the calls."""

    def __init__(self, answers):
        self.answers, self.calls = list(answers), []

    def __call__(self, q, backend):
        self.calls.append(backend)
        a = self.answers.pop(0)
        if isinstance(a, Exception):
            raise a
        return a


def run(script, **kw):
    return ws.ddgs_search("q", 8, text=script, sleep=lambda s: None, **kw)


def test_prompt_prefix_is_stripped():
    assert ws.clean_query("Perform a web search for the query: neo4j editions") == "neo4j editions"


def test_falls_through_backends_until_one_answers():
    s = Script([Exception("No results found."), Exception("ratelimit"), [hit(1), hit(2)]])
    hits, errors = run(s, backends=("yahoo", "duckduckgo", "auto"))
    assert [h["url"] for h in hits] == ["https://example.com/1", "https://example.com/2"]
    assert s.calls == ["yahoo", "duckduckgo", "auto"] and len(errors) == 2


def test_hits_without_url_do_not_count_as_success():
    # 2026-10-04 14:35 ET: one engine failure was logged, then Claude Code got
    # results=[]. A backend that "answers" with URL-less items must not stop the chain.
    s = Script([Exception("No results found."), [{"title": "", "href": "", "body": ""}], [hit(3)]])
    hits, errors = run(s, backends=("yahoo", "auto", "duckduckgo"))
    assert [h["url"] for h in hits] == ["https://example.com/3"]
    assert "without a URL" in errors[1]


def test_second_round_after_backoff():
    slept = []
    s = Script([Exception("a"), Exception("b"), [hit(4)]])
    hits, _ = ws.ddgs_search("q", 8, backends=("yahoo", "auto"), delays=(0.0, 2.0), text=s, sleep=slept.append)
    assert hits and s.calls == ["yahoo", "auto", "yahoo"] and slept == [2.0]


def test_deadline_stops_new_attempts():
    t = iter(range(0, 1000, 15))
    s = Script([Exception("slow")] * 10)
    hits, errors = ws.ddgs_search("q", 8, backends=("yahoo", "auto"), deadline=20, text=s,
                                  sleep=lambda s: None, clock=lambda: next(t))
    assert hits == [] and len(s.calls) < 4


def test_max_results_is_respected():
    s = Script([[hit(i) for i in range(20)]])
    hits, _ = ws.ddgs_search("q", 5, backends=("yahoo",), text=s, sleep=lambda s: None)
    assert len(hits) == 5


def test_every_backend_failing_raises_with_reasons_not_empty_results():
    def ddgs(q, n):
        return [], ["ddgs/yahoo: DDGSException: No results found.", "ddgs/auto: RatelimitException: 202"]

    with pytest.raises(ws.WebSearchUnavailable) as e:
        asyncio.run(ws.run_search("Perform a web search for the query: x", 8, chain=["ddgs"], ddgs=ddgs))
    assert "RatelimitException" in str(e.value) and "'x'" in str(e.value)


def test_success_is_a_search_response_and_is_cached():
    calls = []

    def ddgs(q, n):
        calls.append(q)
        return [{"title": "t", "url": "https://a.example/", "snippet": "s"}], []

    r1 = asyncio.run(ws.run_search("neo4j", 8, chain=["ddgs"], ddgs=ddgs))
    r2 = asyncio.run(ws.run_search("Neo4j", 8, chain=["ddgs"], ddgs=ddgs))
    assert isinstance(r1, _Response) and r1.results[0].url == "https://a.example/"
    assert r2.results[0].url == "https://a.example/" and calls == ["neo4j"]


def test_failures_are_not_cached():
    answers = [([], ["boom"]), ([{"title": "t", "url": "https://b.example/", "snippet": ""}], [])]

    def ddgs(q, n):
        return answers.pop(0)

    with pytest.raises(ws.WebSearchUnavailable):
        asyncio.run(ws.run_search("q", 8, chain=["ddgs"], ddgs=ddgs))
    assert asyncio.run(ws.run_search("q", 8, chain=["ddgs"], ddgs=ddgs)).results[0].url == "https://b.example/"


def test_chain_falls_back_to_a_litellm_provider():
    seen = []

    async def orig(**kw):
        seen.append(kw["search_provider"])
        if kw["search_provider"] == "searxng":
            raise RuntimeError("connection refused")
        return _Response(results=[_Result("Brave hit", "https://brave.example/", "s")])

    def ddgs(q, n):
        return [], ["ddgs/yahoo: No results found."]

    r = asyncio.run(ws.run_search("q", 8, chain=["searxng", "ddgs", "brave"], orig=orig, ddgs=ddgs))
    assert seen == ["searxng", "brave"] and r.results[0].url == "https://brave.example/"


def test_one_failed_query_of_several_keeps_the_others():
    def ddgs(q, n):
        return ([{"title": "t", "url": f"https://{q}.example/", "snippet": ""}], []) if q == "good" else ([], ["x"])

    r = asyncio.run(ws.run_search(["good", "bad"], 8, chain=["ddgs"], ddgs=ddgs))
    assert [x.url for x in r.results] == ["https://good.example/"]


def test_env_parsing():
    assert ws.chain_from_env({}) == ["ddgs"]
    assert ws.chain_from_env({"CCL_WEB_SEARCH_CHAIN": "searxng, ddgs ,brave"}) == ["searxng", "ddgs", "brave"]
    assert ws.chain_from_env({"CCL_WEB_SEARCH_CHAIN": "duckduckgo"}) == ["ddgs"]
    assert ws.chain_from_env({"CCL_WEB_SEARCH_CHAIN": "searxng,ddgs,tavily,exa"}) == ["searxng", "ddgs", "tavily", "exa_ai"]
    assert ws.backends_from_env({}) == ws.DEFAULT_BACKENDS
    assert ws.backends_from_env({"CCL_DDGS_BACKENDS": "yahoo,auto"}) == ("yahoo", "auto")
