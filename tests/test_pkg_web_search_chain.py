"""Default web search chain (spec: Web search): tinyfish only with a key, then ddgs, then you_com."""
import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

import web_search as ws

blank = st.sampled_from(["", " ", "\t", "  \n"])
key = st.text(min_size=1, max_size=40).filter(lambda s: s.strip() != "")
noise = st.dictionaries(st.text(min_size=1, max_size=10).filter(lambda k: k not in ("CCL_WEB_SEARCH_CHAIN", "TINYFISH_API_KEY")),
                        st.text(max_size=10), max_size=6)


@pytest.mark.spec
def test_default_without_keys():
    assert ws.chain_from_env({}) == ["ddgs", "you_com"]


@pytest.mark.spec
def test_default_with_tinyfish_key():
    assert ws.chain_from_env({"TINYFISH_API_KEY": "tf-x"}) == ["tinyfish", "ddgs", "you_com"]


@pytest.mark.spec
def test_blank_chain_means_default():
    assert ws.chain_from_env({"CCL_WEB_SEARCH_CHAIN": "  "}) == ["ddgs", "you_com"]


@pytest.mark.spec
def test_explicit_chain_is_used_as_given():
    env = {"CCL_WEB_SEARCH_CHAIN": "searxng,tinyfish,ddgs,you_com,tavily,exa", "TINYFISH_API_KEY": "k"}
    assert ws.chain_from_env(env) == ["searxng", "tinyfish", "ddgs", "you_com", "tavily", "exa_ai"]


@pytest.mark.property
@settings(max_examples=300)
@given(st.one_of(st.none(), blank, key), noise)
def test_default_chain_invariants(k, extra):
    env = dict(extra)
    if k is not None:
        env["TINYFISH_API_KEY"] = k
    chain = ws.chain_from_env(env)
    assert chain[-2:] == ["ddgs", "you_com"]
    assert ("tinyfish" in chain) == bool(k and k.strip())
    assert len(chain) == len(set(chain))
    assert "duckduckgo" not in chain


@pytest.mark.metamorphic
@settings(max_examples=200)
@given(st.one_of(st.none(), key), noise)
def test_unrelated_env_does_not_change_the_chain(k, extra):
    base = {} if k is None else {"TINYFISH_API_KEY": k}
    assert ws.chain_from_env({**extra, **base}) == ws.chain_from_env(base)


@pytest.mark.metamorphic
@settings(max_examples=100)
@given(blank)
def test_blank_key_equals_no_key(b):
    assert ws.chain_from_env({"TINYFISH_API_KEY": b}) == ws.chain_from_env({})
