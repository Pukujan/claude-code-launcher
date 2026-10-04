"""Windows launcher: the slot steps and Steps 9 and 10 (UltraCode orchestrator/worker), driven with
scripted keys in library mode. Needs pwsh and uv; skipped when either is missing
(GitHub's ubuntu runners have both). Refs #40."""
import json
import shutil
import subprocess

import pytest
from conftest import REPO

pytestmark = pytest.mark.skipif(not (shutil.which("pwsh") and shutil.which("uv")), reason="needs pwsh and uv")

DRIVER = r"""
$ErrorActionPreference = "Stop"
$env:CCL_LAUNCHER_LIBRARY_ONLY = "1"
# The launcher names D:\ and C:\ roots at load time; give Linux runners both.
foreach ($d in "C", "D") { if (-not (Get-PSDrive $d -ErrorAction SilentlyContinue)) { $null = New-PSDrive -Name $d -PSProvider FileSystem -Root $env:HOME -Scope Global } }
. (Join-Path $env:CCL_REPO "windows/launch-claude-inferhub.ps1")
$ProxyPort = 4017
$ProxyBase = "http://127.0.0.1:4017"
function Get-UltraCodeShim { return $env:CCL_FAKE_SHIM }
$script:NavQuiet = $true
$script:NavKeys = [System.Collections.ArrayList]@($env:CCL_KEYS.Split(","))
$w = Invoke-LaunchWizard
@{ launch = $w.Launch; orch = $w.UcOrch; worker = $w.UcWorker; sonnet = @($w.Slots.sonnet); haiku_same = $w.Slots.haiku_same; trace = @($script:NavTrace) } | ConvertTo-Json -Compress
"""


def run(tmp_path, keys):
    shim = tmp_path / "shim"
    shim.mkdir(exist_ok=True)
    shutil.copy(REPO / "tests" / "fixtures" / "ultracode" / "config.example.json", shim / "config.example.json")
    proj = tmp_path / "proj"
    (proj / "app").mkdir(parents=True, exist_ok=True)
    picks = tmp_path / "last-picks.json"
    if not picks.exists():
        picks.write_text(json.dumps({"start_dir": str(proj)}))
    driver = tmp_path / "driver.ps1"
    driver.write_text(DRIVER)
    env = {"PATH": __import__("os").environ["PATH"], "HOME": str(tmp_path), "USERPROFILE": str(tmp_path), "LOCALAPPDATA": str(tmp_path / "lad"),
           "CCL_REPO": str(REPO), "CCL_FAKE_SHIM": str(shim), "CCL_LAST_PICKS": str(picks), "CCL_KEYS": keys}
    out = subprocess.run(["pwsh", "-NoProfile", "-File", str(driver)], env=env, capture_output=True, text=True,
                         timeout=180)
    assert out.returncode == 0, out.stderr + out.stdout
    result = json.loads(out.stdout.strip().splitlines()[-1])
    cfg = shim / "config.json"
    return result, json.loads(picks.read_text()), (json.loads(cfg.read_text()) if cfg.exists() else None)


# First run (no saved slots): sonnet, opus, fable 3 Enters each (default chains), haiku
# Enter ("same chain as sonnet"), folder Enter, launch Down+Enter (UltraCode).
SLOTS_DEFAULT = ",".join(["Enter"] * 10)
TO_LAUNCH = SLOTS_DEFAULT + ",Enter,DownArrow,Enter"


def test_ultracode_picks_orchestrator_and_worker(tmp_path):
    # the fable slot always has a model now, so the list is main, advisor, fast
    result, picks, cfg = run(tmp_path, TO_LAUNCH + ",Enter,DownArrow,DownArrow,DownArrow,Enter")
    assert result["launch"] == "ultracode", result["trace"]
    assert result["orch"] == "claude-ih-main"        # default orchestrator
    assert result["worker"] == "claude-ih-fast"       # Same, main, advisor, fast
    assert picks["launch"] == "ultracode"
    assert picks["uc_orch"] == "claude-ih-main" and picks["uc_worker"] == "claude-ih-fast"
    assert cfg["proxy"]["listen_port"] == 4241 + 4017
    assert cfg["proxy"]["anthropic_upstream"] == "http://127.0.0.1:4017"
    assert not [m for m in cfg["models"] if "ckff" in m["id"]]
    assert result["sonnet"] == ["cb/deepseek-v4.1-flash", "ali/qwen3.8-flash", "cbcn/glm-5.3-flash"]
    assert result["haiku_same"] is True and picks["version"] == 2 and picks["slots"]["opus"][0] == "cb/gpt-6-astra"
    # Next run: Step 1 Enter keeps the saved slots, then folder, launch, orch, worker Enter.
    result2, _, _ = run(tmp_path, "Enter,Enter,Enter,Enter,Enter")
    assert (result2["orch"], result2["worker"]) == ("claude-ih-main", "claude-ih-fast")


def test_same_as_orchestrator_and_left_goes_back(tmp_path):
    # Left on Step 9 returns to "launch with"; Enter there keeps UltraCode.
    result, picks, _ = run(tmp_path, TO_LAUNCH + ",DownArrow,LeftArrow,Enter,DownArrow,DownArrow,Enter,Enter")
    assert result["launch"] == "ultracode"
    assert result["orch"] == "claude-ih-fast"
    assert result["worker"] in ("", None)
    assert picks["uc_worker"] == ""
    assert any("uc_orch" in t and "back" in t for t in result["trace"])


def test_claude_code_launch_skips_the_ultracode_steps(tmp_path):
    result, picks, _ = run(tmp_path, SLOTS_DEFAULT + ",Enter,Enter")
    assert result["launch"] == "claude" and not result["orch"]
    assert "uc_orch" not in picks


def test_saved_slots_change_path_and_back_key(tmp_path):
    # Step 1 Down+Enter = change; sonnet first model Down picks the 2nd row; Left on the
    # next step goes back to it; then Enter through the rest.
    run(tmp_path, SLOTS_DEFAULT + ",Enter,Enter")
    result, picks, _ = run(tmp_path, "DownArrow,Enter,Enter,LeftArrow,Enter," + ",".join(["Enter"] * 9) + ",Enter,Enter")
    assert result["launch"] == "claude"
    assert any("back" in t for t in result["trace"]), result["trace"]
    assert picks["slots"]["sonnet"][0] == "cb/deepseek-v4.1-flash"
    assert len(picks["slots"]["fable"]) == 3
