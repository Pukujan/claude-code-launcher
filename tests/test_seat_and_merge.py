"""Seat aliases and fallback chains, run through the copied scripts unchanged."""
import json
import os
import subprocess
import sys

import yaml

from conftest import LITELLM, SCRIPTS

import merge_litellm_config as merge


def run(script, *args, ckff=None):
    env = dict(os.environ)
    env.pop("LITELLM_ENABLE_CKFF", None)
    if ckff is not None:
        env["LITELLM_ENABLE_CKFF"] = "1" if ckff else "0"
    return subprocess.run([sys.executable, str(SCRIPTS / script), *args],
                          capture_output=True, text=True, check=False, env=env)


def aliases(path):
    doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    return {m["model_name"]: m["litellm_params"]["model"] for m in doc["model_list"]}


def seat_out(tmp_path, *args, seat=None):
    seat = seat or tmp_path / "seat.json"
    out = tmp_path / "aliases.yaml"
    r = run("apply_inferhub_seat.py", "--seat", str(seat), "--out", str(out), *args, "--no-merge", "--no-reload")
    assert r.returncode == 0, r.stderr
    return aliases(out), json.loads(seat.read_text())


def test_default_slots_are_alexs_chains(tmp_path):
    a, seat = seat_out(tmp_path)
    for name in ("sonnet", "claude-sonnet-5", "main"):
        assert a[name] == "openai/cb/deepseek-v4.1-flash"
    assert (a["ccl-sonnet-2"], a["ccl-sonnet-3"]) == ("openai/ali/qwen3.8-flash", "openai/cbcn/glm-5.3-flash")
    # opus = planning: Astra (InferHub cb/, not CKFF), Sol over Responses, Qwen Max
    for name in ("opus", "claude-opus-5-5", "claude-opus-5"):
        assert a[name] == "openai/cb/gpt-6-astra"
    assert (a["ccl-opus-2"], a["ccl-opus-3"]) == ("openai/responses/cx/gpt-6.1-sol", "openai/ali/qwen3.8-max-0902")
    # haiku: same chain as sonnet, but its own copies
    for name in ("haiku", "claude-haiku-4-5-20251001", "claude-haiku-5", "small-fast"):
        assert a[name] == "openai/cb/deepseek-v4.1-flash"
    assert (a["ccl-haiku-2"], a["ccl-haiku-3"]) == ("openai/ali/qwen3.8-flash", "openai/cbcn/glm-5.3-flash")
    # fable = advisor: a different order from sonnet
    for name in ("fable", "claude-fable-5", "claude-fable-5-1", "advisor"):
        assert a[name] == "openai/cbcn/glm-5.3-flash"
    assert (a["ccl-fable-2"], a["ccl-fable-3"]) == ("openai/ali/qwen3.8-flash", "openai/cb/deepseek-v4.1-flash")
    # CKFF is off, so claude-haiku-4-5 is a haiku name too
    assert a["claude-haiku-4-5"] == "openai/cb/deepseek-v4.1-flash"
    assert seat["version"] == 2 and seat["slots"]["fable"][0] == "cbcn/glm-5.3-flash"
    assert seat["main_inferhub_id"] == "cb/deepseek-v4.1-flash" and seat["advisor_inferhub_id"] == "cbcn/glm-5.3-flash"


def test_slot_flags_and_saved_slots_win_over_the_defaults(tmp_path):
    a, seat = seat_out(tmp_path, "--slot=opus=cx/gpt-6.1-sol,ali/qwen3.8-max-0902", "--slot", "haiku=cbcn/minimax-m3")
    assert a["opus"] == "openai/responses/cx/gpt-6.1-sol" and a["ccl-opus-2"] == "openai/ali/qwen3.8-max-0902"
    assert "ccl-opus-3" not in a
    assert a["haiku"] == "openai/cbcn/minimax-m3" and "ccl-haiku-2" not in a
    # the saved picks are reused by the next run without flags
    a2, _ = seat_out(tmp_path)
    assert a2["opus"] == a["opus"] and a2["haiku"] == a["haiku"]


def test_old_seat_files_mean_no_picks_yet(tmp_path):
    # A seat file from before issue #53 (main/advisor/fast only) is not a slot pick.
    seat = tmp_path / "seat.json"
    seat.write_bytes(b"\xef\xbb\xbf" + json.dumps({"main_inferhub_id": "cbcn/glm-5.3",
                                                      "advisor_inferhub_id": "ali/qwen3.8-max-0902"}).encode())
    a, _ = seat_out(tmp_path, seat=seat)
    assert a["sonnet"] == "openai/cb/deepseek-v4.1-flash" and a["fable"] == "openai/cbcn/glm-5.3-flash"


def test_older_launcher_flags_set_first_models(tmp_path):
    # The Mac launcher still passes --main/--advisor: first models of sonnet and fable.
    a, seat = seat_out(tmp_path, "--main", "cbcn/minimax-m3", "--advisor", "")
    assert a["sonnet"] == "openai/cbcn/minimax-m3"
    assert seat["slots"]["sonnet"] == ["cbcn/minimax-m3", "cb/deepseek-v4.1-flash", "ali/qwen3.8-flash",
                                       "cbcn/glm-5.3-flash"]
    assert a["fable"] == "openai/cbcn/glm-5.3-flash"   # empty advisor keeps the fable chain


def test_ckff_routes_never_reach_a_slot(tmp_path):
    a, seat = seat_out(tmp_path, "--slot=sonnet=ckff/gpt-6-astra,cb/deepseek-v4.1-flash")
    assert a["sonnet"] == "openai/cb/deepseek-v4.1-flash"
    assert not [v for v in a.values() if "ckff" in v]


def test_bad_slot_name_is_rejected(tmp_path):
    r = run("apply_inferhub_seat.py", "--seat", str(tmp_path / "s.json"), "--out", str(tmp_path / "a.yaml"),
            "--slot=main=cb/x", "--no-merge", "--no-reload")
    assert r.returncode == 2 and "unknown slot" in r.stderr


def test_direct_ih_chains_still_skip_their_own_model():
    ih = [{"model_name": f"ih/{m}", "litellm_params": {"model": f"openai/{m}"}}
          for m in ("cb/deepseek-v4.1-flash", "ali/qwen3.8-flash", "cbcn/deepseek-v4-flash")]
    fb = {k: v for d in merge.build_inferhub_fallbacks(LITELLM / "config" / "inferhub_fallbacks.yaml", ih)
          for k, v in d.items()}
    assert fb["ih/ali/qwen3.8-flash"] == ["ih/cb/deepseek-v4.1-flash", "ih/cbcn/deepseek-v4-flash"]
    assert fb["ih/cb/deepseek-v4.1-flash"] == ["ih/cbcn/deepseek-v4-flash", "ih/ali/qwen3.8-flash"]


def _runtime(tmp_path, *seat_args, env=None):
    top = tmp_path / "top20.yaml"
    assert run("sync_inferhub_top20.py", "--out", str(top)).returncode == 0
    al = tmp_path / "aliases.yaml"
    assert run("apply_inferhub_seat.py", "--seat", str(tmp_path / "s.json"), "--out", str(al), *seat_args,
               "--no-merge", "--no-reload").returncode == 0
    out = tmp_path / "runtime.yaml"
    env = env or {k: v for k, v in os.environ.items() if k not in ("LITELLM_MASTER_KEY", "CCL_RETRIES", "CCL_COOLDOWN_S")}
    r = subprocess.run([sys.executable, str(SCRIPTS / "merge_litellm_config.py"), "--inferhub-top20", str(top),
                        "--inferhub-aliases", str(al), "--out", str(out), "--no-reload"],
                       capture_output=True, text=True, check=False, env=env)
    assert r.returncode == 0, r.stderr
    return yaml.safe_load(out.read_text(encoding="utf-8")), r.stdout


def test_each_slot_falls_back_to_its_own_copies(tmp_path):
    doc, _ = _runtime(tmp_path)
    rs = doc["router_settings"]
    fb = {k: v for d in rs["fallbacks"] for k, v in d.items()}
    for slot in ("sonnet", "opus", "haiku", "fable"):
        names = {"sonnet": ["sonnet", "claude-sonnet-5", "main"], "opus": ["opus", "claude-opus-5-5"],
                 "haiku": ["haiku", "claude-haiku-4-5-20251001", "small-fast"],
                 "fable": ["fable", "claude-fable-5", "advisor"]}[slot]
        for n in names:
            assert fb[n] == [f"ccl-{slot}-2", f"ccl-{slot}-3"], n
    # no fallback target is shared between two slots
    owners = {}
    for src, targets in fb.items():
        for t in targets:
            if t.startswith("ccl-"):
                owners.setdefault(t, set()).add(t.split("-")[1])
    assert all(len(v) == 1 for v in owners.values())
    cw = {k: v for d in rs["context_window_fallbacks"] for k, v in d.items()}
    assert cw["claude-opus-5-5"] == ["ccl-opus-2", "ccl-opus-3"]
    info = {m["model_name"]: m.get("model_info") or {} for m in doc["model_list"]}
    for slot in ("sonnet", "opus", "haiku", "fable"):
        assert info[f"ccl-{slot}-3"]["cooldown_time"] == 0.0          # last model: never benched
        assert "allowed_fails_policy" not in info[f"ccl-{slot}-3"]
        assert info[f"ccl-{slot}-2"]["cooldown_time"] == 180.0
    assert info["claude-opus-5-5"]["cooldown_time"] == 180.0


def test_single_model_slot_is_never_benched(tmp_path):
    doc, _ = _runtime(tmp_path, "--slot=haiku=cb/deepseek-v4.1-flash")
    info = {m["model_name"]: m.get("model_info") or {} for m in doc["model_list"]}
    assert info["haiku"]["cooldown_time"] == 0.0 and "ccl-haiku-2" not in info


def test_ckff_switch_off_drops_every_ckff_model_and_fallback(tmp_path):
    doc, out = _runtime(tmp_path)
    assert "CKFF is disabled" in out
    names = {m["model_name"] for m in doc["model_list"]}
    assert "kimi-k2.7-code" not in names and "claude-sonnet-4-5" not in names
    assert not [m for m in doc["model_list"] if "ckff" in str((m.get("litellm_params") or {}).get("api_base", ""))]
    for key in ("fallbacks", "context_window_fallbacks", "content_policy_fallbacks"):
        for d in doc["router_settings"].get(key) or []:
            for src, targets in d.items():
                assert src in names and set(targets) <= names, (key, src)


def test_ckff_switch_on_brings_ckff_back(tmp_path):
    env = {k: v for k, v in os.environ.items() if k not in ("LITELLM_MASTER_KEY",)}
    env["LITELLM_ENABLE_CKFF"] = "1"
    top = tmp_path / "top20.yaml"
    assert run("sync_inferhub_top20.py", "--out", str(top)).returncode == 0
    al = tmp_path / "aliases.yaml"
    r = subprocess.run([sys.executable, str(SCRIPTS / "apply_inferhub_seat.py"), "--seat", str(tmp_path / "s.json"),
                        "--out", str(al), "--no-merge", "--no-reload"], capture_output=True, text=True, env=env)
    assert r.returncode == 0, r.stderr
    assert "claude-haiku-4-5" not in aliases(al)   # CKFF serves that name while it is on
    out = tmp_path / "runtime.yaml"
    r = subprocess.run([sys.executable, str(SCRIPTS / "merge_litellm_config.py"), "--inferhub-top20", str(top),
                        "--inferhub-aliases", str(al), "--out", str(out), "--no-reload"],
                       capture_output=True, text=True, env=env)
    assert r.returncode == 0, r.stderr
    assert "kimi-k2.7-code" in {m["model_name"] for m in yaml.safe_load(out.read_text())["model_list"]}


def test_full_merge_from_builtin_top20(tmp_path):
    top = tmp_path / "top20.yaml"
    r = run("sync_inferhub_top20.py", "--out", str(top))
    assert r.returncode == 0, r.stderr
    al = tmp_path / "aliases.yaml"
    assert run("apply_inferhub_seat.py", "--seat", str(tmp_path / "s.json"), "--out", str(al),
               "--no-merge", "--no-reload").returncode == 0
    out = tmp_path / "runtime.yaml"
    env = {k: v for k, v in os.environ.items() if k != "LITELLM_MASTER_KEY"}
    r = subprocess.run([sys.executable, str(SCRIPTS / "merge_litellm_config.py"), "--inferhub-top20", str(top),
                        "--inferhub-aliases", str(al), "--out", str(out), "--no-reload"],
                       capture_output=True, text=True, check=False, env=env)
    assert r.returncode == 0, r.stderr
    doc = yaml.safe_load(out.read_text(encoding="utf-8"))
    names = {m["model_name"] for m in doc["model_list"]}
    assert "ih/cb/deepseek-v4.1-flash" in names and "sonnet" in names
    # Keyless: with no LITELLM_MASTER_KEY, runtime.yaml has no master_key at all.
    assert "master_key" not in (doc.get("general_settings") or {})
    assert {"haiku", "small-fast"} <= names
    assert any("sonnet" in d for d in doc["router_settings"]["fallbacks"])
    assert any("small-fast" in d for d in doc["router_settings"]["fallbacks"])
    # failure policy: 3 retries per model (seats and chain targets), benched 180 s after the last one
    pol = doc["router_settings"]["model_group_retry_policy"]
    assert pol["sonnet"]["ServiceUnavailableErrorRetries"] == 3
    assert pol["ih/ali/qwen3.8-flash"]["RateLimitErrorRetries"] == 3
    assert pol["ccl-opus-3"]["RateLimitErrorRetries"] == 3
    info = {m["model_name"]: m.get("model_info") or {} for m in doc["model_list"]}
    assert info["sonnet"]["cooldown_time"] == 180.0
    assert info["sonnet"]["allowed_fails_policy"]["ServiceUnavailableErrorAllowedFails"] == 3


def test_merge_honors_ccl_retries_and_cooldown(tmp_path, monkeypatch):
    top = tmp_path / "top20.yaml"
    assert run("sync_inferhub_top20.py", "--out", str(top)).returncode == 0
    al = tmp_path / "aliases.yaml"
    assert run("apply_inferhub_seat.py", "--seat", str(tmp_path / "s.json"), "--out", str(al),
               "--main", "cb/deepseek-v4.1-flash", "--advisor", "", "--no-merge", "--no-reload").returncode == 0
    out = tmp_path / "runtime.yaml"
    monkeypatch.setenv("CCL_RETRIES", "2")
    monkeypatch.setenv("CCL_COOLDOWN_S", "20")
    r = run("merge_litellm_config.py", "--inferhub-top20", str(top), "--inferhub-aliases", str(al),
            "--out", str(out), "--no-reload")
    assert r.returncode == 0, r.stderr
    doc = yaml.safe_load(out.read_text(encoding="utf-8"))
    pol = doc["router_settings"]["model_group_retry_policy"]["sonnet"]
    assert pol["ServiceUnavailableErrorRetries"] == 2 and pol["TimeoutErrorRetries"] == 0
    info = {m["model_name"]: m.get("model_info") or {} for m in doc["model_list"]}["sonnet"]
    assert info["cooldown_time"] == 20.0
    assert info["allowed_fails_policy"]["ServiceUnavailableErrorAllowedFails"] == 2


def test_web_search_is_intercepted_without_overriding_config():
    doc = merge.apply_web_search({"litellm_settings": {"drop_params": True}})
    assert doc["litellm_settings"]["callbacks"] == ["websearch_interception"]
    assert doc["litellm_settings"]["websearch_interception_params"] == {"enabled_providers": ["openai"]}
    assert doc["search_tools"][0]["litellm_params"]["search_provider"] == "duckduckgo"
    mine = [{"search_tool_name": "t", "litellm_params": {"search_provider": "tavily"}}]
    doc = merge.apply_web_search({"search_tools": mine, "litellm_settings": {"callbacks": ["websearch_interception"]}})
    assert doc["search_tools"] == mine and doc["litellm_settings"]["callbacks"] == ["websearch_interception"]


def test_master_key_is_only_an_env_reference_when_set():
    assert merge.apply_master_key_setting({}, {"LITELLM_MASTER_KEY": "sk-x"}) == {
        "master_key": "os.environ/LITELLM_MASTER_KEY"}
    assert merge.apply_master_key_setting({"master_key": "x"}, {}) == {}


# ---- cx/ routes use Responses mode; everything else is plain openai/ (#13) ----


def test_only_cx_routes_change_model_string():
    import csv as _csv
    import apply_inferhub_seat as seat
    ids = set()
    with open(LITELLM / "config" / "top20-builtin.csv", encoding="utf-8") as fh:
        for row in _csv.DictReader(fh):
            ids.update(x.strip() for x in (row.get("model_ids") or row.get("id") or "").split(";") if x.strip())
    ids.update({"cbcn/glm-5.3-flash", "cc/claude-fable-5-1", "ag/gemini-pro-agent", "cxx/not-cx", "acx/x"})
    for mid in ids:
        if mid.startswith("cx/"):
            continue
        assert seat.litellm_model(mid) == f"openai/{mid}", mid
    assert seat.litellm_model("cx/gpt-6.1-sol") == "openai/responses/cx/gpt-6.1-sol"
    assert seat.litellm_model("cx/gpt-5.6-luna") == "openai/responses/cx/gpt-5.6-luna"


def test_cx_first_model_is_seated_in_responses_mode(tmp_path):
    a, _ = seat_out(tmp_path, "--slot=sonnet=cx/gpt-6.1-sol,cbcn/minimax-m3")
    for name in ("main", "sonnet", "claude-sonnet-5"):
        assert a[name] == "openai/responses/cx/gpt-6.1-sol"
    assert a["ccl-sonnet-2"] == "openai/cbcn/minimax-m3"
