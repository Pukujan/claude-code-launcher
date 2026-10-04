"""Windows launcher: Steps 9 and 10 (UltraCode orchestrator/worker), driven with
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
function Get-DefaultChain { param([string]$Role, [string]$PrimaryId) return @() }
$script:NavQuiet = $true
$script:NavKeys = [System.Collections.ArrayList]@($env:CCL_KEYS.Split(","))
$w = Invoke-LaunchWizard
@{ launch = $w.Launch; orch = $w.UcOrch; worker = $w.UcWorker; main = $w.Main.Id; trace = @($script:NavTrace) } | ConvertTo-Json -Compress
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


# main Enter, 2nd model Enter (none), advisor Enter (OFF), folder Enter, launch Down+Enter
TO_LAUNCH = "Enter,Enter,Enter,Enter,DownArrow,Enter"


def test_ultracode_picks_orchestrator_and_worker(tmp_path):
    result, picks, cfg = run(tmp_path, TO_LAUNCH + ",Enter,DownArrow,DownArrow,Enter")
    assert result["launch"] == "ultracode", result["trace"]
    assert result["orch"] == "claude-ih-main"        # default orchestrator
    assert result["worker"] == "claude-ih-fast"       # Same, main, fast
    assert picks["launch"] == "ultracode"
    assert picks["uc_orch"] == "claude-ih-main" and picks["uc_worker"] == "claude-ih-fast"
    assert cfg["proxy"]["listen_port"] == 4241 + 4017
    assert cfg["proxy"]["anthropic_upstream"] == "http://127.0.0.1:4017"
    assert not [m for m in cfg["models"] if "ckff" in m["id"]]
    # Next run highlights last time's picks: Enter, Enter keeps them.
    result2, _, _ = run(tmp_path, TO_LAUNCH.replace("DownArrow,", "") + ",Enter,Enter")
    assert (result2["orch"], result2["worker"]) == ("claude-ih-main", "claude-ih-fast")


def test_same_as_orchestrator_and_left_goes_back(tmp_path):
    # Left on Step 9 returns to "launch with"; Enter there keeps UltraCode.
    result, picks, _ = run(tmp_path, TO_LAUNCH + ",DownArrow,LeftArrow,Enter,DownArrow,Enter,Enter")
    assert result["launch"] == "ultracode"
    assert result["orch"] == "claude-ih-fast"
    assert result["worker"] in ("", None)
    assert picks["uc_worker"] == ""
    assert any("uc_orch" in t and "back" in t for t in result["trace"])


def test_claude_code_launch_skips_the_ultracode_steps(tmp_path):
    result, picks, _ = run(tmp_path, "Enter,Enter,Enter,Enter,Enter")
    assert result["launch"] == "claude" and not result["orch"]
    assert "uc_orch" not in picks
