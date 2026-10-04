"""IRE fetch without a token when the repo is public (spec: IRE)."""
import io
import json
import sys
import urllib.error
from urllib.parse import unquote, urlsplit

import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from conftest import REPO

sys.path.insert(0, str(REPO / "shared" / "ire"))
import ire_fetch as F  # noqa: E402

FIX = REPO / "tests" / "fixtures" / "ire"
SHA = "89abcdef0123456789abcdef0123456789abcdef"


class PublicGitHub:
    """GitHub contents API for a public repo: any (or no) Authorization works."""

    def __init__(self):
        self.files = {F.TOP20_PATH: (FIX / "top20.csv").read_bytes(), F.POLICY_PATH: (FIX / "policy.md").read_bytes()}
        self.auth = []

    def __call__(self, req, timeout=None):
        self.auth.append(req.get_header("Authorization"))
        parts = urlsplit(req.full_url)
        rest = parts.path[len(f"/repos/{F.IRE_REPO}/"):]
        if rest.startswith("commits/"):
            return io.BytesIO(SHA.encode())
        if rest.startswith("contents/"):
            body = self.files.get(unquote(rest[len("contents/"):]))
            if body is not None:
                return io.BytesIO(body)
        raise urllib.error.HTTPError(req.full_url, 404, "Not Found", {}, None)


@pytest.fixture
def clean(monkeypatch, tmp_path):
    for name in ("GITHUB_TOKEN", "GH_TOKEN", "CCL_IRE_OFFLINE", "CCL_IRE_API_BASE", "CCL_IRE_CACHE_DIR"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(F.shutil, "which", lambda name: None)
    return tmp_path / "cache"


@pytest.mark.spec
def test_no_token_reads_the_public_repo(monkeypatch, clean):
    gh = PublicGitHub()
    monkeypatch.setattr(F.urllib.request, "urlopen", gh)
    b = F.get_recommendations(directory=clean)
    assert b["source"] == "live"
    assert gh.auth and all(a is None for a in gh.auth)


@pytest.mark.spec
def test_no_token_and_no_network_uses_defaults(monkeypatch, clean):
    def down(req, timeout=None):
        raise urllib.error.URLError(OSError("unreachable"))
    monkeypatch.setattr(F.urllib.request, "urlopen", down)
    assert F.get_recommendations(directory=clean)["source"] == "defaults"


@pytest.mark.spec
def test_no_token_and_private_repo_falls_back(monkeypatch, clean):
    def private(req, timeout=None):
        raise urllib.error.HTTPError(req.full_url, 404, "Not Found", {}, None)
    monkeypatch.setattr(F.urllib.request, "urlopen", private)
    assert F.get_recommendations(directory=clean)["source"] in ("cache", "defaults")


@pytest.mark.spec
def test_token_is_still_sent_when_present(monkeypatch, clean):
    monkeypatch.setenv("GITHUB_TOKEN", "tok-not-real")
    gh = PublicGitHub()
    monkeypatch.setattr(F.urllib.request, "urlopen", gh)
    assert F.get_recommendations(directory=clean)["source"] == "live"
    assert all(a == "Bearer tok-not-real" for a in gh.auth)


@pytest.mark.property
@settings(max_examples=40, deadline=None, suppress_health_check=[HealthCheck.function_scoped_fixture])
# The "ghtok_" prefix keeps a random token from being a substring of real IRE data
# (Hypothesis once drew "cbcn/glm-5.2", a model id).
@given(st.text(alphabet=st.characters(min_codepoint=33, max_codepoint=126), min_size=12, max_size=40).map(lambda s: "ghtok_" + s))
def test_a_token_never_reaches_output_or_cache(monkeypatch, clean, capsys, token):
    monkeypatch.setenv("GITHUB_TOKEN", token)
    monkeypatch.setattr(F.urllib.request, "urlopen", PublicGitHub())
    b = F.get_recommendations(directory=clean)
    err = capsys.readouterr().err
    assert token not in json.dumps(b) and token not in err
    cache = clean / F.CACHE_NAME
    if cache.exists():
        assert token not in cache.read_text(encoding="utf-8")


@pytest.mark.metamorphic
def test_public_fetch_with_or_without_token_gives_the_same_bundle(monkeypatch, clean, tmp_path):
    monkeypatch.setattr(F.urllib.request, "urlopen", PublicGitHub())
    anon = F.get_recommendations(directory=tmp_path / "a")
    monkeypatch.setenv("GITHUB_TOKEN", "tok-not-real")
    authed = F.get_recommendations(directory=tmp_path / "b")
    assert anon == authed
