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
KEYS = {"source", "top20", "price_policy", "ladders", "retries", "cooldown_s", "frontier"}
FRONTIER_ROW = {"rank", "name", "vendor", "route", "best_route", "eligible", "health", "cost_per_mtok",
                "price_in", "price_out", "preferred_endpoint", "system_prompt_handling", "context_window"}


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
    assert isinstance(b["frontier"], list)
    for row in b["frontier"]:
        assert set(row) == FRONTIER_ROW
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
    assert (b["retries"], b["cooldown_s"]) == (3, 180)
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


# ------------------------------------------------------------------ frontier list


def frontier_files(json_ok=True, csv_ok=False):
    f = {}
    if json_ok:
        f[F.FRONTIER_JSON_PATH] = (FIX / "frontier.json").read_bytes()
    if csv_ok:
        f[F.FRONTIER_ROUTES_PATH] = (FIX / "frontier_routes.csv").read_bytes()
    return f


def test_frontier_comes_from_the_json(monkeypatch, env):
    monkeypatch.setenv("GH_TOKEN", TOKEN)
    online(monkeypatch, FakeGitHub(frontier_files(csv_ok=True)))
    b = F.get_recommendations(directory=env)
    check_contract(b)
    routes = [r["route"] for r in b["frontier"]]
    assert "xx/disabled-route" not in routes  # disabled routes are left out
    # CKFF is off, but InferHub's Astra routes are not CKFF and stay (issue #53)
    assert "cb/gpt-6-astra" in routes and not [r for r in routes if "ckff" in r]
    raw = [r["route"] for r in F.parse_frontier_json((FIX / "frontier.json").read_text(encoding="utf-8"))]
    assert raw[0] == "cb/gpt-6-astra" and raw.index("cb/gpt-6-astra") < raw.index("cx/gpt-6-astra")
    sol = next(r for r in b["frontier"] if r["route"] == "cx/gpt-6.1-sol")
    assert (sol["price_in"], sol["price_out"], sol["cost_per_mtok"]) == (0.016, 0.08, 0.016)
    assert sol["preferred_endpoint"] == "/v1/responses" and sol["eligible"] is True
    fable = next(r for r in b["frontier"] if r["route"] == "cc/claude-fable-5-1")
    assert fable["cost_per_mtok"] == 1.0
    # cached with the rest, and still there offline
    monkeypatch.setattr(F.urllib.request, "urlopen", no_network)
    assert F.get_recommendations(directory=env)["frontier"] == b["frontier"]


def test_frontier_falls_back_to_the_routes_csv(monkeypatch, env):
    monkeypatch.setenv("GH_TOKEN", TOKEN)
    files = frontier_files(json_ok=False, csv_ok=True)
    online(monkeypatch, FakeGitHub(files))
    b = F.get_recommendations(directory=env)
    check_contract(b)
    assert [r["route"] for r in b["frontier"]] == ["cc/claude-fable-5-1", "cx/gpt-6.1-sol"]


def test_frontier_missing_or_malformed_is_empty(monkeypatch, env):
    monkeypatch.setenv("GH_TOKEN", TOKEN)
    online(monkeypatch, FakeGitHub({F.FRONTIER_JSON_PATH: b"{not json"}))
    b = F.get_recommendations(directory=env)
    check_contract(b)
    assert b["source"] == "live" and b["frontier"] == []
    online(monkeypatch, FakeGitHub())
    assert F.get_recommendations(directory=env)["frontier"] == []


def test_old_cache_without_frontier_still_loads(env):
    env.mkdir(parents=True)
    d = F.load_defaults()
    d.pop("frontier")
    F.write_cache(env, dict(d, source="live"), SHA, "2026-10-03T00:00:00Z")
    b = F.get_recommendations(offline=True, directory=env)
    check_contract(b)
    assert b["source"] == "cache" and b["frontier"] == []


# ------------------------------------------------------------------ offline, no cache


def test_offline_no_cache_uses_defaults(monkeypatch, env):
    monkeypatch.setenv("GH_TOKEN", TOKEN)
    monkeypatch.setattr(F.urllib.request, "urlopen", no_network)
    b = F.get_recommendations(directory=env)
    check_contract(b)
    assert b["source"] == "defaults"
    assert b["ladders"]["main"] == ["cb/deepseek-v4.1-flash", "ali/qwen3.8-flash", "cbcn/deepseek-v4-flash"]
    assert b["ladders"]["advisor"] == ["cbcn/glm-5.3-flash", "cbcn/minimax-m3"]
    assert (b["retries"], b["cooldown_s"]) == (3, 180)
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


# ------------------------------------------------------------------ frontier: the other optional files

def test_frontier_routes_csv_takes_eligibility_from_the_recommendations_csv(monkeypatch, env):
    # 9a8fba0 rows: GPT 6 Astra (rank 1) and Claude Fable 5.1 (rank 2) are both recommended.
    monkeypatch.setenv("GH_TOKEN", TOKEN)
    online(monkeypatch, FakeGitHub({
        F.FRONTIER_MODELS_CSV_PATH: (FIX / "frontier_recommendations.csv").read_bytes(),
        F.FRONTIER_ROUTES_PATH: (FIX / "frontier_routes.csv").read_bytes(),
    }))
    b = F.get_recommendations(directory=env)
    check_contract(b)
    by_name = {r["name"]: r["eligible"] for r in b["frontier"]}
    assert by_name.get("Claude Fable 5.1") is True
    sol = next(r for r in b["frontier"] if r["route"] == "cx/gpt-6.1-sol")
    assert sol["system_prompt_handling"] == "developer_message"
    assert sol["preferred_endpoint"] == "/v1/responses"


def test_frontier_recommendations_csv_alone_gives_best_routes(monkeypatch, env):
    monkeypatch.setenv("GH_TOKEN", TOKEN)
    online(monkeypatch, FakeGitHub({
        F.FRONTIER_MODELS_CSV_PATH: (FIX / "frontier_recommendations.csv").read_bytes()}))
    b = F.get_recommendations(directory=env)
    check_contract(b)
    assert [r["route"] for r in b["frontier"]] == ["cb/gpt-6-astra", "cc/claude-fable-5-1"]  # InferHub Astra is not CKFF
    assert all(r["best_route"] and r["eligible"] for r in b["frontier"])


def test_slow_frontier_file_keeps_the_live_top20(monkeypatch, env):
    # A frontier read that runs out of time must not turn a live answer into cache/defaults.
    monkeypatch.setenv("GH_TOKEN", TOKEN)
    fake = FakeGitHub()

    def slow_frontier(req, timeout=None):
        if "frontier" in req.full_url:
            raise urllib.error.URLError(OSError("timed out"))
        return fake(req, timeout)

    monkeypatch.setattr(F.urllib.request, "urlopen", slow_frontier)
    b = F.get_recommendations(directory=env)
    assert b["source"] == "live" and b["frontier"] == []


def test_cli_writes_the_picker_table_and_top20_csv(env, tmp_path):
    out = tmp_path / "o"
    r = subprocess.run([sys.executable, str(REPO / "shared" / "ire" / "ire_fetch.py"), "--offline",
                        "--cache-dir", str(env), "--out", str(out / "ire.json"),
                        "--table-out", str(out / "table.txt"), "--top20-csv", str(out / "top20.csv")],
                       capture_output=True, text=True, check=False)
    assert r.returncode == 0, r.stderr
    assert r.stdout == ""
    lines = (out / "table.txt").read_text().splitlines()
    assert len(lines) == 20 and lines[0] == "1|DeepSeek V4.1 Flash|cb/deepseek-v4.1-flash|true|0.022"
    rows = list(csv.DictReader(io.StringIO((out / "top20.csv").read_text())))
    assert rows[0]["model_ids"] == "cb/deepseek-v4.1-flash" and len(rows) == 20


def test_builtin_table_matches_the_mac_launcher_fallback():
    # The Mac launcher's built-in MODELS is what it shows when ire_fetch.py can't run at all.
    text = (REPO / "mac" / "Launch Claude InferHub.command").read_text(encoding="utf-8")
    block = text.split("MODELS='", 1)[1].split("'", 1)[0]
    assert block.strip().splitlines() == F.shell_table(F.load_defaults()).strip().splitlines()


# ---- CKFF is off (2026-10-04): no CKFF route in any list; InferHub Astra stays ----

def test_without_ckff_drops_ckff_everywhere_but_keeps_inferhub_astra():
    b = F.load_defaults()
    b["top20"] = [{"rank": 1, "name": "Mix", "eligible": True, "cost_per_mtok": 0.01,
                   "ids": ["ckff/x", "cb/deepseek-v4.1-flash"]},
                  {"rank": 2, "name": "GPT 6 Astra", "eligible": True, "cost_per_mtok": 0.01,
                   "ids": ["cb/gpt-6-astra"]}] + b["top20"]
    b["frontier"] = [{"rank": 1, "route": "cx/gpt-6-astra", "name": "GPT 6 Astra"},
                     {"rank": 2, "route": "ckff_astra", "name": "x"},
                     {"rank": 3, "route": "cc/claude-fable-5-1", "name": "Claude Fable 5.1"}]
    b["ladders"] = {"main": ["ckff_astra", "cb/deepseek-v4.1-flash"], "advisor": ["cx/gpt-6-astra"]}
    b["ladders"]["fast"] = ["ckff_astra"]
    out = F.validate(b)
    flat = json.dumps(out).lower()
    assert "ckff" not in flat
    assert out["top20"][0]["ids"] == ["cb/deepseek-v4.1-flash"]
    assert out["top20"][1]["ids"] == ["cb/gpt-6-astra"]
    assert [r["route"] for r in out["frontier"]] == ["cx/gpt-6-astra", "cc/claude-fable-5-1"]
    assert out["ladders"]["main"] == ["cb/deepseek-v4.1-flash"]
    assert out["ladders"]["advisor"] == ["cx/gpt-6-astra"]
    if F.load_defaults()["ladders"].get("fast"):
        assert out["ladders"]["fast"] == F.load_defaults()["ladders"]["fast"]  # emptied -> built-in


def test_cache_with_ckff_is_cleaned_and_inferhub_astra_kept(env):
    b = F.load_defaults()
    b["frontier"] = [{"rank": 1, "route": "cb/gpt-6-astra", "name": "GPT 6 Astra"},
                     {"rank": 2, "route": "ckff/gpt-6-astra", "name": "GPT 6 Astra (CKFF)"}]
    F.write_cache(env, b, "abc", "2026-10-04T00:00:00Z")
    rec = F.read_cache(env)
    assert rec and [r["route"] for r in rec["bundle"]["frontier"]] == ["cb/gpt-6-astra"]
