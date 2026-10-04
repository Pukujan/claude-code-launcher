"""Benching after retries: the hook logic and the config it relies on.

LiteLLM 1.103 on the proxy counts all retries of one request as a single
failure, so allowed_fails alone never benched a dead primary. The launcher
benches a model group from LiteLLM's fallback events instead (fired only once
the group's retries are used up). These tests pin that logic and check the
generated config carries what the hook needs: cooldown_time per seat and rung,
and cooldowns left on.
"""
import os
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "shared" / "litellm"))
import bench_after_retries as bar  # noqa: E402

SCRIPTS = ROOT / "shared" / "litellm" / "scripts"


class Err(Exception):
    def __init__(self, status, name="ServiceUnavailableError"):
        super().__init__(name)
        self.status_code = status


class FakeCooldown:
    def __init__(self):
        self.store = {}
        self.calls = []
        self.cooldown_store = self

    def get_cooldown_cache_key(self, model_id):
        return f"deployment:{model_id}:cooldown"

    def get_cache(self, key):
        return self.store.get(key)

    def add_deployment_to_cooldown(self, model_id, original_exception, exception_status, cooldown_time):
        self.calls.append((model_id, exception_status, cooldown_time))
        self.store[self.get_cooldown_cache_key(model_id)] = {"t": cooldown_time}


class FakeRouter:
    def __init__(self, disable=False):
        self.disable_cooldowns = disable
        self.cooldown_cache = FakeCooldown()
        self.model_list = [
            {"model_name": "sonnet", "model_info": {"id": "s1", "cooldown_time": 180.0}},
            {"model_name": "ih/ali/qwen3.8-flash", "model_info": {"id": "q1"},
             "litellm_params": {"cooldown_time": 20}},
            {"model_name": "plain", "model_info": {"id": "p1"}},
        ]


def test_should_bench_follows_litellm_cooldown_rule():
    for s in (429, 401, 404, 408, 500, 503):
        assert bar.should_bench(Err(s))
    for s in (400, 413, 422):
        assert not bar.should_bench(Err(s))
    assert not bar.should_bench(None)

    class APIConnectionError(Exception):
        pass

    assert not bar.should_bench(APIConnectionError("down"))


def test_bench_group_benches_managed_deployment_for_its_cooldown():
    r = FakeRouter()
    assert bar.bench_group(r, "sonnet", Err(503)) == ["s1"]
    assert r.cooldown_cache.calls == [("s1", 503, 180.0)]
    assert bar.bench_group(r, "ih/ali/qwen3.8-flash", Err(429)) == ["q1"]
    assert r.cooldown_cache.calls[-1] == ("q1", 429, 20.0)


def test_bench_group_skips_unmanaged_bad_request_and_disabled():
    r = FakeRouter()
    assert bar.bench_group(r, "plain", Err(503)) == []
    assert bar.bench_group(r, "sonnet", Err(400)) == []
    assert bar.bench_group(r, None, Err(503)) == []
    assert bar.bench_group(None, "sonnet", Err(503)) == []
    off = FakeRouter(disable=True)
    assert bar.bench_group(off, "sonnet", Err(503)) == []
    assert r.cooldown_cache.calls == [] and off.cooldown_cache.calls == []


def test_already_benched_group_is_not_extended():
    r = FakeRouter()
    bar.bench_group(r, "sonnet", Err(503))
    assert bar.bench_group(r, "sonnet", Err(503)) == []
    assert len(r.cooldown_cache.calls) == 1


def test_sitecustomize_installs_the_hook():
    src = (ROOT / "shared" / "litellm" / "sitecustomize.py").read_text(encoding="utf-8")
    assert "import bench_after_retries" in src and "_install_bench_hook()" in src


def _run(script, *args, env=None):
    return subprocess.run([sys.executable, str(SCRIPTS / script), *args],
                          capture_output=True, text=True, check=False, env=env)


def test_generated_config_gives_seats_and_rungs_a_cooldown(tmp_path):
    env = {k: v for k, v in os.environ.items()
           if k not in ("LITELLM_MASTER_KEY", "CCL_RETRIES", "CCL_COOLDOWN_S")}
    top = tmp_path / "top20.yaml"
    assert _run("sync_inferhub_top20.py", "--out", str(top), env=env).returncode == 0
    al = tmp_path / "aliases.yaml"
    assert _run("apply_inferhub_seat.py", "--seat", str(tmp_path / "s.json"), "--out", str(al),
                "--main", "cb/deepseek-v4.1-flash", "--advisor", "", "--no-merge", "--no-reload",
                env=env).returncode == 0
    out = tmp_path / "runtime.yaml"
    r = _run("merge_litellm_config.py", "--inferhub-top20", str(top), "--inferhub-aliases", str(al),
             "--out", str(out), "--no-reload", env=env)
    assert r.returncode == 0, r.stderr
    doc = yaml.safe_load(out.read_text(encoding="utf-8"))
    rs = doc.get("router_settings") or {}
    assert not rs.get("disable_cooldowns") and not (doc.get("litellm_settings") or {}).get("disable_cooldowns")
    cd = {m["model_name"]: (m.get("model_info") or {}).get("cooldown_time") for m in doc["model_list"]}
    assert cd["sonnet"] == 180.0
    # every fallback target of the seat is benched the same way once its retries are spent
    targets = [t for d in rs["fallbacks"] for k, v in d.items() if k == "sonnet" for t in v]
    assert targets and all(cd.get(t) == 180.0 for t in targets)
    # and the hook would bench the seat from this exact model_list entry
    seat = next(m for m in doc["model_list"] if m["model_name"] == "sonnet")
    seat.setdefault("model_info", {}).setdefault("id", "seat-id")
    fake = FakeRouter()
    fake.model_list = [seat]
    assert bar.bench_group(fake, "sonnet", Err(503)) == [seat["model_info"]["id"]]
    assert fake.cooldown_cache.calls[0][2] == 180.0


def test_real_router_benches_after_fallback_event():
    pytest.importorskip("litellm")
    from litellm import Router

    router = Router(model_list=[{"model_name": "sonnet", "litellm_params": {"model": "openai/x",
                                 "api_key": "k"}, "model_info": {"id": "s1", "cooldown_time": 30}}])
    assert bar.bench_group(router, "sonnet", Err(503)) == ["s1"]
    assert bar._is_benched(router, "s1")
