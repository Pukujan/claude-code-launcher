"""shared/ire/ire_fetch.py with the network mocked out.

Cases: online, offline with a cache, offline with no cache, bad auth, plus the
JSON contract the ladder picker (#5) relies on. No test opens a socket.
"""
import csv
import io
import json
import subprocess
import sys
import urllib.error
from pathlib import Path
from urllib.parse import unquote, urlsplit

import pytest

from conftest import REPO

sys.path.insert(0, str(REPO / "shared" / "ire"))
import ire_fetch as F  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures" / "ire"
SHA = "0123456789abcdef0123456789abcdef01234567"
TOKEN = "test-token-not-real"
KEYS = {"source", "top20", "price_policy", "ladders", "retries", "cooldown_s"}


class FakeGitHub:
    """Stands in for urllib.request.urlopen against the GitHub contents API."""

    def __init__(self, files=None, token=TOKEN):
        self.files = {
            F.TOP20_PATH: (FIX / "top20.csv").read_bytes(),
            F.POLICY_PATH: (FIX / "policy.md").read_bytes(),
        }
        self.files.update(files or {})
        self.token = token
        self.calls = []

    def __call__(self, req, timeout=None):
        assert timeout is not None and timeout <= F.DEFAULT_TIMEOUT
        auth = req.get_header("Authorization")
        self.calls.append((req.full_url, auth))
        if auth != f"Bearer {self.token}":
            raise urllib.error.HTTPError(req.full_url, 401, "Bad credentials", {}, None)
        parts = urlsplit(req.full_url)
        prefix = f"/repos/{F.IRE_REPO}/"
        rest = parts.path[len(prefix):]
        if rest.startswith("commits/"):
            return io.BytesIO(SHA.encode())
        if rest.startswith("contents/"):
            assert parts.query == f"ref={SHA}"  # files are read at the resolved commit
            body = self.files.get(unquote(rest[len("contents/"):]))
            if body is not None:
                return io.BytesIO(body)
        raise urllib.error.HTTPError(req.full_url, 404, "Not Found", {}, None)


def no_network(req, timeout=None):
    raise urllib.error.URLError(OSError("network is unreachable"))


@pytest.fixture
def env(monkeypatch, tmp_path):
    for name in ("GITHUB_TOKEN", "GH_TOKEN", "CCL_IRE_OFFLINE", "CCL_IRE_API_BASE", "CCL_IRE_CACHE_DIR"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(F.shutil, "which", lambda name: None)  # no gh unless a test adds it
    return tmp_path / "cache"


def online(monkeypatch, fake=None):
    fake = fake or FakeGitHub()
    monkeypatch.setattr(F.urllib.request, "urlopen", fake)
    return fake


def check_contract(b):
    assert set(b) == KEYS
    assert b["source"] in ("live", "cache", "defaults")
    assert isinstance(b["top20"], list) and b["top20"]
    for row in b["top20"]:
        assert set(row) == {"rank", "name", "vendor", "eligible", "gate_reasons", "cost_per_mtok", "ids"}
    assert set(b["price_policy"]) == {"free_below_per_mtok", "unit", "source"}
    assert set(b["ladders"]) == {"main", "advisor"}
    assert all(isinstance(x, str) for chain in b["ladders"].values() for x in chain)
    assert isinstance(b["retries"], int) and isinstance(b["cooldown_s"], int)
    json.dumps(b)


# ------------------------------------------------------------------ online


def test_online_fetches_and_caches(monkeypatch, env, capsys):
    monkeypatch.setenv("GH_TOKEN", TOKEN)
    fake = online(monkeypatch)
    b = F.get_recommendations(directory=env)
    check_contract(b)
    assert b["source"] == "live"
    assert len(b["top20"]) == 20
    assert b["top20"][0]["ids"][0] == "cb/deepseek-v4.1-flash"
    assert b["top20"][2]["eligible"] is False and b["top20"][2]["gate_reasons"]
    assert b["price_policy"]["free_below_per_mtok"] == 0.10
    assert b["ladders"] == {"main": ["cb/deepseek-v4.1-flash", "ali/qwen3.8-flash", "cbcn/deepseek-v4-flash"],
                            "advisor": ["cbcn/glm-5.3-flash", "cbcn/minimax-m3"]}
    assert (b["retries"], b["cooldown_s"]) == (1, 180)
    record = json.loads((env / F.CACHE_NAME).read_text())
    assert record["source_sha"] == SHA
    assert record["fetched_at"].endswith("Z")
    assert record["bundle"]["top20"] == b["top20"]
    assert all(auth == f"Bearer {TOKEN}" for _, auth in fake.calls)
    out = capsys.readouterr()
    assert TOKEN not in out.out + out.err
    assert TOKEN not in (env / F.CACHE_NAME).read_text()


def test_online_uses_gh_auth_token(monkeypatch, env):
    monkeypatch.setattr(F.shutil, "which", lambda name: "/usr/bin/gh" if name == "gh" else None)
    seen = []

    def fake_run(cmd, **kw):
        seen.append(cmd)
        return subprocess.CompletedProcess(cmd, 0, stdout=TOKEN + "\n", stderr="")

    monkeypatch.setattr(F.subprocess, "run", fake_run)
    online(monkeypatch)
    assert F.get_recommendations(directory=env)["source"] == "live"
    assert seen[0][1:3] == ["auth", "token"]


def test_env_token_beats_gh(monkeypatch, env):
    monkeypatch.setenv("GITHUB_TOKEN", TOKEN)
    monkeypatch.setattr(F.shutil, "which", lambda name: pytest.fail("gh should not be asked"))
    online(monkeypatch)
    assert F.get_recommendations(directory=env)["source"] == "live"


def test_price_cap_follows_ire_doc(monkeypatch, env):
    monkeypatch.setenv("GH_TOKEN", TOKEN)
    online(monkeypatch, FakeGitHub({F.POLICY_PATH: b"cost below **$0.05 USDC per 1 million tokens** counts"}))
    assert F.get_recommendations(directory=env)["price_policy"]["free_below_per_mtok"] == 0.05


def test_ire_fallback_picks_replace_ladders(monkeypatch, env):
    monkeypatch.setenv("GH_TOKEN", TOKEN)
    picks = {"main": ["cbcn/deepseek-v4-flash", "ali/qwen3.8-flash"], "advisor": ["cbcn/minimax-m3"],
             "retries": 2, "cooldown_s": 60}
    online(monkeypatch, FakeGitHub({F.PICKS_PATH: json.dumps(picks).encode()}))
    b = F.get_recommendations(directory=env)
    check_contract(b)
    assert b["ladders"] == {"main": picks["main"], "advisor": picks["advisor"]}
    assert (b["retries"], b["cooldown_s"]) == (2, 60)


def test_malformed_picks_are_ignored(monkeypatch, env):
    monkeypatch.setenv("GH_TOKEN", TOKEN)
    online(monkeypatch, FakeGitHub({F.PICKS_PATH: b'{"main": "not-a-list"}'}))
    b = F.get_recommendations(directory=env)
    assert b["source"] == "live"
    assert b["ladders"]["main"][0] == "cb/deepseek-v4.1-flash"


# ------------------------------------------------------------------ offline with cache


def test_offline_uses_last_good_copy(monkeypatch, env):
    monkeypatch.setenv("GH_TOKEN", TOKEN)
    online(monkeypatch)
    live = F.get_recommendations(directory=env)
    monkeypatch.setattr(F.urllib.request, "urlopen", no_network)
    b = F.get_recommendations(directory=env)
    check_contract(b)
    assert b["source"] == "cache"
    assert b["top20"] == live["top20"]
    assert json.loads((env / F.CACHE_NAME).read_text())["source_sha"] == SHA


def test_offline_flag_never_touches_network(monkeypatch, env):
    monkeypatch.setenv("GH_TOKEN", TOKEN)
    online(monkeypatch)
    F.get_recommendations(directory=env)
    monkeypatch.setattr(F.urllib.request, "urlopen", lambda *a, **k: pytest.fail("network used"))
    assert F.get_recommendations(offline=True, directory=env)["source"] == "cache"


def test_no_auth_goes_straight_to_cache(monkeypatch, env):
    monkeypatch.setenv("GH_TOKEN", TOKEN)
    online(monkeypatch)
    F.get_recommendations(directory=env)
    monkeypatch.delenv("GH_TOKEN")
    monkeypatch.setattr(F.urllib.request, "urlopen", lambda *a, **k: pytest.fail("network used"))
    assert F.get_recommendations(directory=env)["source"] == "cache"


def test_corrupt_cache_falls_to_defaults(env):
    env.mkdir(parents=True)
    (env / F.CACHE_NAME).write_text("{not json", encoding="utf-8")
    assert F.get_recommendations(offline=True, directory=env)["source"] == "defaults"


# ------------------------------------------------------------------ offline, no cache


def test_offline_no_cache_uses_defaults(monkeypatch, env):
    monkeypatch.setenv("GH_TOKEN", TOKEN)
    monkeypatch.setattr(F.urllib.request, "urlopen", no_network)
    b = F.get_recommendations(directory=env)
    check_contract(b)
    assert b["source"] == "defaults"
    assert b["ladders"]["main"] == ["cb/deepseek-v4.1-flash", "ali/qwen3.8-flash", "cbcn/deepseek-v4-flash"]
    assert b["ladders"]["advisor"] == ["cbcn/glm-5.3-flash", "cbcn/minimax-m3"]
    assert (b["retries"], b["cooldown_s"]) == (1, 180)
    assert b["price_policy"]["free_below_per_mtok"] == 0.10
    assert not (env / F.CACHE_NAME).exists()  # defaults are never cached


def test_gh_not_logged_in_uses_defaults(monkeypatch, env):
    monkeypatch.setattr(F.shutil, "which", lambda name: "/usr/bin/gh")
    monkeypatch.setattr(F.subprocess, "run", lambda cmd, **kw: subprocess.CompletedProcess(cmd, 1, "", "not logged in"))
    monkeypatch.setattr(F.urllib.request, "urlopen", lambda *a, **k: pytest.fail("network used"))
    assert F.get_recommendations(directory=env)["source"] == "defaults"


def test_slow_github_respects_the_deadline(monkeypatch, env):
    monkeypatch.setenv("GH_TOKEN", TOKEN)

    def slow(req, timeout=None):
        raise urllib.error.URLError(TimeoutError("timed out"))

    monkeypatch.setattr(F.urllib.request, "urlopen", slow)
    assert F.get_recommendations(directory=env, timeout=0.5)["source"] == "defaults"


# ------------------------------------------------------------------ bad auth


def test_bad_token_falls_back_to_cache(monkeypatch, env, capsys):
    monkeypatch.setenv("GH_TOKEN", TOKEN)
    online(monkeypatch)
    F.get_recommendations(directory=env)
    monkeypatch.setenv("GH_TOKEN", "expired-token-value")
    b = F.get_recommendations(directory=env)
    assert b["source"] == "cache"
    err = capsys.readouterr().err
    assert "401" in err
    assert "expired-token-value" not in err


def test_bad_token_no_cache_uses_defaults(monkeypatch, env, capsys):
    monkeypatch.setenv("GITHUB_TOKEN", "expired-token-value")
    online(monkeypatch)
    assert F.get_recommendations(directory=env)["source"] == "defaults"
    assert "expired-token-value" not in capsys.readouterr().err


def test_token_without_repo_access(monkeypatch, env):
    # GitHub answers 404 for a private repo the token cannot see.
    monkeypatch.setenv("GH_TOKEN", TOKEN)
    monkeypatch.setattr(F.urllib.request, "urlopen",
                        lambda req, timeout=None: (_ for _ in ()).throw(
                            urllib.error.HTTPError(req.full_url, 404, "Not Found", {}, None)))
    assert F.get_recommendations(directory=env)["source"] == "defaults"


# ------------------------------------------------------------------ contract and CLI


def test_defaults_match_the_builtin_top20_table():
    b = F.load_defaults()
    check_contract(b)
    with open(REPO / "shared/litellm/config/top20-builtin.csv", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    assert [r["ids"][0] for r in b["top20"]] == [r["model_ids"].strip() for r in rows]


def test_cache_dir_per_platform(monkeypatch, tmp_path):
    monkeypatch.delenv("CCL_IRE_CACHE_DIR", raising=False)
    monkeypatch.setattr(F.os, "name", "posix")
    monkeypatch.setattr(F.sys, "platform", "linux")
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path))
    assert F.cache_dir() == tmp_path / "claude-code-launcher" / "ire"
    monkeypatch.setattr(F.sys, "platform", "darwin")
    assert F.cache_dir() == Path.home() / "Library" / "Caches" / "claude-code-launcher" / "ire"


def test_cli_writes_json(env, tmp_path):
    out = tmp_path / "ire.json"
    assert F.main(["--offline", "--cache-dir", str(env), "--out", str(out)]) == 0
    check_contract(json.loads(out.read_text()))


# ------------------------------------------------------------------ frontier list (optional)

FRONTIER_FILES = {
    F.FRONTIER_PATHS["recommendations_csv"]: (FIX / "frontier_recommendations.csv").read_bytes(),
    F.FRONTIER_PATHS["routes_csv"]: (FIX / "frontier_routes.csv").read_bytes(),
}


def test_frontier_missing_is_fine(monkeypatch, env):
    monkeypatch.setenv("GH_TOKEN", TOKEN)
    online(monkeypatch)
    b, fr = F.get_recommendations_and_frontier(directory=env)
    check_contract(b)
    assert b["source"] == "live"
    assert set(fr) == set(F.FRONTIER_KEYS)
    assert fr["available"] is False and fr["models"] == [] and fr["routes"] == []
    assert fr["files"] == {k: False for k in F.FRONTIER_PATHS}


def test_frontier_read_at_the_same_commit_and_cx_routes_keep_their_handling(monkeypatch, env):
    monkeypatch.setenv("GH_TOKEN", TOKEN)
    online(monkeypatch, FakeGitHub(files=FRONTIER_FILES))
    b, fr = F.get_recommendations_and_frontier(directory=env)
    check_contract(b)  # the frontier list never changes the six-key bundle
    assert fr["available"] and fr["source"] == "live" and fr["ire_sha"] == SHA
    assert fr["files"]["recommendations_csv"] and fr["files"]["routes_csv"]
    assert not fr["files"]["recommendations_json"]
    assert fr["models"][0]["rank"] == 1 and fr["models"][0]["name"] == "GPT 6 Astra"
    cx = [r for r in fr["routes"] if r["route"].startswith("cx/")]
    assert cx, "fixture has a cx route"
    for r in cx:
        assert r["system_prompt_handling"] == "developer_message"
        assert r["preferred_endpoint"] == "/v1/responses"


def test_frontier_json_fills_in_when_csvs_are_missing(monkeypatch, env):
    doc = {"schema": "ihub-frontier-recommendations/v1", "generated_at": "2026-10-04T00:02:28Z",
           "models": [{"frontier_rank": 1, "model_family": "GPT 6 Astra", "recommendation_eligible": True,
                       "model_ids": ["cb/gpt-6-astra", "cx/gpt-6-astra"]}],
           "routes": [{"frontier_rank": 1, "model_family": "GPT 6 Astra", "route": "cx/gpt-6-astra",
                       "health": {"status": "healthy"}, "system_prompt_handling": "developer_message",
                       "preferred_endpoint": "/v1/responses"}]}
    monkeypatch.setenv("GH_TOKEN", TOKEN)
    online(monkeypatch, FakeGitHub(files={F.FRONTIER_PATHS["recommendations_json"]: json.dumps(doc).encode()}))
    _, fr = F.get_recommendations_and_frontier(directory=env)
    assert fr["available"] and fr["schema"] == doc["schema"]
    assert fr["models"][0]["ids"] == ["cb/gpt-6-astra", "cx/gpt-6-astra"] and fr["models"][0]["eligible"]
    assert fr["routes"][0]["health"] == "healthy"
    assert fr["routes"][0]["preferred_endpoint"] == "/v1/responses"


def test_frontier_comes_back_from_the_cache(monkeypatch, env):
    monkeypatch.setenv("GH_TOKEN", TOKEN)
    online(monkeypatch, FakeGitHub(files=FRONTIER_FILES))
    F.get_recommendations_and_frontier(directory=env)
    monkeypatch.setattr(F.urllib.request, "urlopen", no_network)
    b, fr = F.get_recommendations_and_frontier(directory=env)
    assert b["source"] == "cache" and fr["source"] == "cache" and fr["available"]


def test_frontier_empty_with_defaults(monkeypatch, env):
    monkeypatch.setattr(F.urllib.request, "urlopen", lambda *a, **k: pytest.fail("network used"))
    b, fr = F.get_recommendations_and_frontier(directory=env)
    assert b["source"] == "defaults" and fr == F.empty_frontier()


def test_cli_writes_frontier_table_and_csv(env, tmp_path):
    out = tmp_path / "o"
    r = subprocess.run([sys.executable, str(REPO / "shared" / "ire" / "ire_fetch.py"), "--offline",
                        "--cache-dir", str(env), "--out", str(out / "ire.json"),
                        "--frontier-out", str(out / "frontier.json"), "--table-out", str(out / "table.txt"),
                        "--top20-csv", str(out / "top20.csv")],
                       capture_output=True, text=True, check=False)
    assert r.returncode == 0, r.stderr
    assert r.stdout == ""
    assert json.loads((out / "frontier.json").read_text())["available"] is False
    lines = (out / "table.txt").read_text().splitlines()
    assert len(lines) == 20 and lines[0] == "1|DeepSeek V4.1 Flash|cb/deepseek-v4.1-flash|true|0.022"
    rows = list(csv.DictReader(io.StringIO((out / "top20.csv").read_text())))
    assert rows[0]["model_ids"] == "cb/deepseek-v4.1-flash" and len(rows) == 20


def test_builtin_table_matches_the_mac_launcher_fallback(env, tmp_path):
    # The Mac launcher's built-in MODELS is what it shows when ire_fetch.py can't run at all.
    text = (REPO / "mac" / "Launch Claude InferHub.command").read_text(encoding="utf-8")
    block = text.split("MODELS='", 1)[1].split("'", 1)[0]
    table = F.shell_table(F.load_defaults())
    assert block.strip().splitlines() == table.strip().splitlines()
