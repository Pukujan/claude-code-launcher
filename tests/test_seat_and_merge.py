"""Seat aliases and fallback chains, run through the copied scripts unchanged."""
import json
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


def test_seat_file_with_bom_is_rejected_so_launchers_must_write_without_one(tmp_path):
    # Guards the PS 5.1 fix: Set-Content -Encoding UTF8 writes a BOM, json.loads refuses it.
    seat = tmp_path / "seat.json"
    seat.write_bytes(b"\xef\xbb\xbf" + json.dumps({"main_inferhub_id": "cb/deepseek-v4.1-flash"}).encode())
    r = run("apply_inferhub_seat.py", "--seat", str(seat), "--out", str(tmp_path / "a.yaml"),
            "--no-merge", "--no-reload")
    assert r.returncode != 0


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


def test_full_merge_from_builtin_top20(tmp_path):
    top = tmp_path / "top20.yaml"
    r = run("sync_inferhub_top20.py", "--out", str(top))
    assert r.returncode == 0, r.stderr
    al = tmp_path / "aliases.yaml"
    assert run("apply_inferhub_seat.py", "--seat", str(tmp_path / "s.json"), "--out", str(al),
               "--main", "cb/deepseek-v4.1-flash", "--advisor", "",
               "--no-merge", "--no-reload").returncode == 0
    out = tmp_path / "runtime.yaml"
    r = run("merge_litellm_config.py", "--inferhub-top20", str(top), "--inferhub-aliases", str(al),
            "--out", str(out), "--no-reload")
    assert r.returncode == 0, r.stderr
    doc = yaml.safe_load(out.read_text(encoding="utf-8"))
    names = {m["model_name"] for m in doc["model_list"]}
    assert "ih/cb/deepseek-v4.1-flash" in names and "sonnet" in names
    # Keyless unless the env sets one: the key is only an env reference.
    assert doc["general_settings"]["master_key"] == "os.environ/LITELLM_MASTER_KEY"
    assert any("sonnet" in d for d in doc["router_settings"]["fallbacks"])
