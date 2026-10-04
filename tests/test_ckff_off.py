"""CKFF is off everywhere (Alex, 2026-10-04): no CKFF models, keys or routes,
Astra / ckff_astra included. Port of litellm-ckff-ops PR #44 plus the launcher side."""
import json
import os
import shutil
import subprocess
import sys

import pytest
import yaml

from conftest import LITELLM, REPO, SCRIPTS

import provider_switch

sys.path.insert(0, str(REPO / "shared" / "ladder"))
import inputs as I  # noqa: E402

WIN = REPO / "windows" / "launch-claude-inferhub.ps1"
START = REPO / "windows" / "litellm" / "start-litellm.ps1"
MAC = REPO / "mac" / "Launch Claude InferHub.command"


def _env(ckff=None):
    env = {k: v for k, v in os.environ.items() if k not in ("LITELLM_ENABLE_CKFF", "LITELLM_MASTER_KEY")}
    if ckff is not None:
        env["LITELLM_ENABLE_CKFF"] = ckff
    return env


def _runtime(tmp_path, ckff=None):
    def run(script, *args):
        r = subprocess.run([sys.executable, str(SCRIPTS / script), *args], capture_output=True,
                           text=True, check=False, env=_env(ckff))
        assert r.returncode == 0, r.stderr + r.stdout
        return r
    top, al, out = tmp_path / "top20.yaml", tmp_path / "aliases.yaml", tmp_path / "runtime.yaml"
    run("sync_inferhub_top20.py", "--out", str(top))
    run("apply_inferhub_seat.py", "--seat", str(tmp_path / "s.json"), "--out", str(al),
        "--main", "cb/deepseek-v4.1-flash", "--advisor", "", "--no-merge", "--no-reload")
    r = run("merge_litellm_config.py", "--inferhub-top20", str(top), "--inferhub-aliases", str(al),
            "--out", str(out), "--no-reload")
    return yaml.safe_load(out.read_text(encoding="utf-8")), r.stdout


def test_switch_is_off_in_the_repo():
    assert provider_switch.file_setting(LITELLM / "config" / "providers.yaml") is False
    assert provider_switch.ckff_enabled({}) is False
    assert provider_switch.ckff_enabled({"LITELLM_ENABLE_CKFF": "1"}) is True
    assert provider_switch.ckff_enabled({"LITELLM_ENABLE_CKFF": "0"}) is False


def test_runtime_has_no_ckff_when_off(tmp_path):
    doc, out = _runtime(tmp_path)
    assert "ckff=off:0" in out
    assert not [m for m in doc["model_list"] if provider_switch.is_ckff_deployment(m)]
    flat = json.dumps(doc).lower()
    assert "ckff" not in flat and "astra" not in flat
    served = {m["model_name"] for m in doc["model_list"]}
    for key in ("fallbacks", "context_window_fallbacks", "content_policy_fallbacks"):
        for d in doc.get("router_settings", {}).get(key) or []:
            for src, targets in d.items():
                assert src in served and set(targets) <= served
    names = {m["model_name"]: m["litellm_params"]["model"] for m in doc["model_list"]}
    # our pins stay: haiku and claude-haiku-4-5 both go to the fast seat
    assert names["claude-haiku-4-5"] == names["haiku"] == names["claude-haiku-4-5-20251001"] == "openai/cb/deepseek-v4.1-flash"
    fb = {k: v for d in doc["router_settings"]["fallbacks"] for k, v in d.items()}
    assert fb["claude-haiku-4-5"] == ["ih/cbcn/deepseek-v4-flash", "ih/ali/qwen3.8-flash"]


def test_runtime_has_ckff_again_only_when_switched_on(tmp_path):
    doc, out = _runtime(tmp_path, ckff="1")
    assert "ckff=on:" in out
    assert [m for m in doc["model_list"] if provider_switch.is_ckff_deployment(m)]


def test_ckff_astra_key_counts_as_ckff():
    assert provider_switch.is_ckff_deployment({"litellm_params": {"api_key": "os.environ/ckff_astra"}})
    assert not provider_switch.is_ckff_deployment({"litellm_params": {"api_key": "os.environ/INFERHUB_API_KEY"}})


def test_ladder_inputs_drop_astra_from_an_old_ire_json(tmp_path):
    raw = json.loads((REPO / "shared" / "ire" / "defaults.json").read_text(encoding="utf-8"))
    raw["source"] = "cache"
    raw["frontier"] = [{"rank": 1, "route": "cb/gpt-6-astra", "name": "GPT 6 Astra", "eligible": True}]
    raw["ladders"] = {"main": ["cx/gpt-6-astra"], "advisor": ["cbcn/glm-5.3-flash", "ckff_astra"]}
    p = tmp_path / "ire.json"
    p.write_text(json.dumps(raw), encoding="utf-8")
    b = I.load_inputs(p)
    assert b["frontier"] == []
    assert b["ladders"]["main"] == I.FIXED_LADDERS["main"]
    assert b["ladders"]["advisor"] == {"primary": "cbcn/glm-5.3-flash", "fallbacks": []}
    assert "astra" not in json.dumps(b).lower() and "ckff" not in json.dumps(b).lower()


def test_launchers_pass_and_load_no_ckff_keys():
    win = WIN.read_text(encoding="utf-8-sig")
    assert "-CkffEnvFile" not in win and "$CkffEnvFile" not in win
    assert "-DesktopEnvFile" in win
    start = START.read_text(encoding="utf-8-sig")
    assert "-SkipCkff:$skip" in start and "if ($CkffEnabled) {" in start
    mac = MAC.read_text(encoding="utf-8")
    line = next(ln for ln in mac.splitlines() if ln.startswith("PROXY_ENV_NAMES="))
    assert "CKFF" not in line.upper()


LAST_PICKS_DRIVER = r"""
$ErrorActionPreference = "Stop"
$env:CCL_LAUNCHER_LIBRARY_ONLY = "1"
foreach ($d in "C", "D") { if (-not (Get-PSDrive $d -ErrorAction SilentlyContinue)) { $null = New-PSDrive -Name $d -PSProvider FileSystem -Root $env:HOME -Scope Global } }
. (Join-Path $env:CCL_REPO "windows/launch-claude-inferhub.ps1")
$last = Read-LastPicks
$pick = Get-StartPick -S @{} -Last $last -Slot "main" -Choices $Models -Default $DefaultModelId
@{ pick = $pick; keys = @($last.Keys | Sort-Object); adv = $last["adv"] } | ConvertTo-Json -Compress
"""


@pytest.mark.skipif(not shutil.which("pwsh"), reason="needs pwsh")
def test_windows_saved_ckff_pick_falls_back_to_default(tmp_path):
    picks = tmp_path / "last-picks.json"
    picks.write_text(json.dumps({"main": "ckff_astra", "main1": "cx/gpt-6-astra", "adv": "cbcn/glm-5.3-flash",
                                 "uc_orch": "claude-ckff-luna", "launch": "claude"}))
    drv = tmp_path / "d.ps1"
    drv.write_text(LAST_PICKS_DRIVER)
    env = {"PATH": os.environ["PATH"], "HOME": str(tmp_path), "USERPROFILE": str(tmp_path),
           "CCL_REPO": str(REPO), "CCL_LAST_PICKS": str(picks)}
    r = subprocess.run(["pwsh", "-NoProfile", "-File", str(drv)], env=env, capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stderr + r.stdout
    out = json.loads(r.stdout.strip().splitlines()[-1])
    assert out["pick"] == "cb/deepseek-v4.1-flash"
    assert out["keys"] == ["adv", "launch"] and out["adv"] == "cbcn/glm-5.3-flash"


def test_mac_saved_ckff_pick_reads_as_empty(tmp_path):
    picks = tmp_path / "last-picks.json"
    picks.write_text('{\n  "launch": "ultracode",\n  "uc_orch": "claude-ckff-astra",\n  "uc_worker": "claude-ih-fast"\n}\n')
    src = MAC.read_text(encoding="utf-8")
    start = src.index("last_pick() {")
    fn = src[start:src.index("\n}\n", start) + 3]
    script = f'LAST_PICKS="{picks}"\n{fn}\nprintf "[%s][%s]" "$(last_pick uc_orch)" "$(last_pick uc_worker)"'
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=False)
    assert r.stdout == "[][claude-ih-fast]", r.stderr
