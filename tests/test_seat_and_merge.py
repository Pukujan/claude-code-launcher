"""Seat aliases and fallback chains, run through the copied scripts unchanged."""
import json
import os
import subprocess
import sys

import yaml

from conftest import LITELLM, SCRIPTS

import merge_litellm_config as merge


def run(script, *args):
    return subprocess.run([sys.executable, str(SCRIPTS / script), *args],
                          capture_output=True, text=True, check=False)


def aliases(path):
    doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    return {m["model_name"]: m["litellm_params"]["model"] for m in doc["model_list"]}


def test_seat_routes_sonnet_main_and_opus_advisor(tmp_path):
    seat, out = tmp_path / "seat.json", tmp_path / "aliases.yaml"
    r = run("apply_inferhub_seat.py", "--seat", str(seat), "--out", str(out),
            "--main", "cbcn/glm-5.3-flash", "--advisor", "cbcn/minimax-m3",
            "--no-merge", "--no-reload")
    assert r.returncode == 0, r.stderr
    a = aliases(out)
    for name in ("main", "sonnet", "claude-sonnet-5"):
        assert a[name] == "openai/cbcn/glm-5.3-flash"
    for name in ("advisor", "opus", "claude-opus-5-5"):
        assert a[name] == "openai/cbcn/minimax-m3"
    assert json.loads(seat.read_text())["advisor_inferhub_id"] == "cbcn/minimax-m3"


def test_advisor_off_falls_back_to_main(tmp_path):
    out = tmp_path / "aliases.yaml"
    r = run("apply_inferhub_seat.py", "--seat", str(tmp_path / "s.json"), "--out", str(out),
            "--main", "cb/deepseek-v4.1-flash", "--advisor", "", "--no-merge", "--no-reload")
    assert r.returncode == 0, r.stderr
    a = aliases(out)
    assert a["opus"] == a["advisor"] == "openai/cb/deepseek-v4.1-flash"


def test_seat_file_with_bom_is_read(tmp_path):
    # Windows PowerShell 5.1 writes the seat file with a BOM; the script reads it as utf-8-sig.
    seat = tmp_path / "seat.json"
    seat.write_bytes(b"\xef\xbb\xbf" + json.dumps({"main_inferhub_id": "cb/deepseek-v4.1-flash"}).encode())
    r = run("apply_inferhub_seat.py", "--seat", str(seat), "--out", str(tmp_path / "a.yaml"),
            "--no-merge", "--no-reload")
    assert r.returncode == 0, r.stderr
    assert aliases(tmp_path / "a.yaml")["sonnet"] == "openai/cb/deepseek-v4.1-flash"


def test_fast_seat_aliases_default_to_deepseek_flash(tmp_path):
    seat, out = tmp_path / "seat.json", tmp_path / "aliases.yaml"
    r = run("apply_inferhub_seat.py", "--seat", str(seat), "--out", str(out),
            "--main", "cbcn/glm-5.3-flash", "--advisor", "", "--no-merge", "--no-reload")
    assert r.returncode == 0, r.stderr
    a = aliases(out)
    for name in ("haiku", "claude-haiku-5", "small-fast", "ih-haiku", "ih-small-fast", "inferhub-haiku"):
        assert a[name] == "openai/cb/deepseek-v4.1-flash"
    # CKFF serves claude-haiku-4-5, so the seat must not shadow it.
    assert "claude-haiku-4-5" not in a
    assert json.loads(seat.read_text())["fast_inferhub_id"] == "cb/deepseek-v4.1-flash"


def test_old_default_fast_seat_in_seat_file_moves_to_new_default(tmp_path):
    # Seat files written before the change all carry the old default; nobody picked it.
    seat, out = tmp_path / "seat.json", tmp_path / "aliases.yaml"
    seat.write_text(json.dumps({"main_inferhub_id": "cbcn/glm-5.3-flash", "fast_inferhub_id": "ali/qwen3.8-flash"}))
    assert run("apply_inferhub_seat.py", "--seat", str(seat), "--out", str(out),
               "--no-merge", "--no-reload").returncode == 0
    assert aliases(out)["small-fast"] == "openai/cb/deepseek-v4.1-flash"
    # a fast seat that was actually picked is kept
    seat.write_text(json.dumps({"main_inferhub_id": "cbcn/glm-5.3-flash", "fast_inferhub_id": "cbcn/minimax-m3"}))
    assert run("apply_inferhub_seat.py", "--seat", str(seat), "--out", str(out),
               "--no-merge", "--no-reload").returncode == 0
    assert aliases(out)["small-fast"] == "openai/cbcn/minimax-m3"


def test_fast_seat_empty_uses_main(tmp_path):
    out = tmp_path / "aliases.yaml"
    r = run("apply_inferhub_seat.py", "--seat", str(tmp_path / "s.json"), "--out", str(out),
            "--main", "cbcn/glm-5.3-flash", "--advisor", "", "--fast", "", "--no-merge", "--no-reload")
    assert r.returncode == 0, r.stderr
    assert aliases(out)["small-fast"] == "openai/cbcn/glm-5.3-flash"


def test_fallback_chains_skip_seat_and_other_seats_vendor(tmp_path):
    ih = [
        {"model_name": "sonnet", "litellm_params": {"model": "openai/cbcn/glm-5.3-flash"}},
        {"model_name": "opus", "litellm_params": {"model": "openai/cb/deepseek-v4.1-flash"}},
    ] + [
        {"model_name": f"ih/{m}", "litellm_params": {"model": f"openai/{m}"}}
        for m in ("cb/deepseek-v4.1-flash", "ali/qwen3.8-flash", "cbcn/deepseek-v4-flash",
                  "cbcn/glm-5.3-flash", "cbcn/minimax-m3")
    ]
    fb = {k: v for d in merge.build_inferhub_fallbacks(LITELLM / "config" / "inferhub_fallbacks.yaml", ih)
          for k, v in d.items()}
    # main seat is zhipu; advisor seat is deepseek, so main's chain drops deepseek.
    assert fb["sonnet"] == ["ih/ali/qwen3.8-flash"]
    # advisor seat is deepseek; its chain drops the main seat's vendor (zhipu).
    assert fb["opus"] == ["ih/cbcn/minimax-m3"]


def test_fast_seat_aliases_get_a_fallback_chain():
    # small-fast had no fallbacks, so one content-filter 400 (Alibaba DataInspectionFailed)
    # killed every WebFetch summary. The chain skips the seat itself and ends on qwen.
    fast = ("small-fast", "haiku", "claude-haiku-5", "ih-haiku", "ih-small-fast", "inferhub-haiku")
    rungs = ("cb/deepseek-v4.1-flash", "ali/qwen3.8-flash", "cbcn/deepseek-v4-flash")
    ih = [{"model_name": n, "litellm_params": {"model": "openai/cb/deepseek-v4.1-flash"}} for n in fast]
    ih += [{"model_name": f"ih/{m}", "litellm_params": {"model": f"openai/{m}"}} for m in rungs]
    fb = {k: v for d in merge.build_inferhub_fallbacks(LITELLM / "config" / "inferhub_fallbacks.yaml", ih)
          for k, v in d.items()}
    for n in fast:
        assert fb[n] == ["ih/cbcn/deepseek-v4-flash", "ih/ali/qwen3.8-flash"]
    # a qwen fast seat falls back to the deepseek rails
    ih[0] = {"model_name": "small-fast", "litellm_params": {"model": "openai/ali/qwen3.8-flash"}}
    fb = {k: v for d in merge.build_inferhub_fallbacks(LITELLM / "config" / "inferhub_fallbacks.yaml", ih)
          for k, v in d.items()}
    assert fb["small-fast"] == ["ih/cb/deepseek-v4.1-flash", "ih/cbcn/deepseek-v4-flash"]


def test_full_merge_from_builtin_top20(tmp_path):
    top = tmp_path / "top20.yaml"
    r = run("sync_inferhub_top20.py", "--out", str(top))
    assert r.returncode == 0, r.stderr
    al = tmp_path / "aliases.yaml"
    assert run("apply_inferhub_seat.py", "--seat", str(tmp_path / "s.json"), "--out", str(al),
               "--main", "cb/deepseek-v4.1-flash", "--advisor", "",
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


# ---- cx/ seats use Responses mode; everything else is byte-identical (#13) ----

GOLDEN = SCRIPTS.parents[2] / "tests" / "fixtures" / "seat"
# Written by the unmodified upstream apply_inferhub_seat.py at litellm-ckff-ops
# de69e68 (no cx change, includes the haiku/small-fast aliases); only the
# "# Generated:" timestamp line is dropped.
GOLDEN_CASES = [
    ("cb/deepseek-v4.1-flash", "ali/qwen3.8-flash", "cb-deepseek-v4.1-flash_ali-qwen3.8-flash.yaml"),
    ("ag/gemini-3.8-flash-high", "", "ag-gemini-3.8-flash-high_.yaml"),
    ("cmc/meta/muse-spark-1.3-contributor", "cb/hy4-preview", "cmc-meta-muse-spark-1.3-contributor_cb-hy4-preview.yaml"),
]


def _seat_yaml(tmp_path, main, advisor):
    out = tmp_path / "aliases.yaml"
    r = run("apply_inferhub_seat.py", "--seat", str(tmp_path / "s.json"), "--out", str(out),
            "--main", main, "--advisor", advisor, "--fast", "ali/qwen3.8-flash",  # goldens predate the deepseek fast default
            "--no-merge", "--no-reload")
    assert r.returncode == 0, r.stderr
    text = out.read_text(encoding="utf-8")
    return "".join(ln for ln in text.splitlines(keepends=True) if not ln.startswith("# Generated: "))


def test_non_cx_seat_output_is_byte_identical_to_before(tmp_path):
    for main, advisor, golden in GOLDEN_CASES:
        assert _seat_yaml(tmp_path, main, advisor).encode() == (GOLDEN / golden).read_bytes(), golden


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


def test_cx_primary_is_seated_in_responses_mode(tmp_path):
    out = tmp_path / "aliases.yaml"
    r = run("apply_inferhub_seat.py", "--seat", str(tmp_path / "s.json"), "--out", str(out),
            "--main", "cx/gpt-6.1-sol", "--advisor", "cbcn/minimax-m3", "--no-merge", "--no-reload")
    assert r.returncode == 0, r.stderr
    a = aliases(out)
    for name in ("main", "sonnet", "claude-sonnet-5"):
        assert a[name] == "openai/responses/cx/gpt-6.1-sol"
    assert a["opus"] == "openai/cbcn/minimax-m3"
