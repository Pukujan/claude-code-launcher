"""One env file in the launcher folder (issue #64).

Outside packaged mode, the Windows launcher and start-litellm.ps1 read every key
from <repo>\\.env when that file exists, and look at the old places (the IRE
.env next to the repository, configs\\.env on the Desktop) only when it is
missing. No key value may appear in anything they print. The repository is
copied into a temp folder so the sibling IRE folder and the Desktop are fakes.
"""
import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest
from conftest import REPO

needs_pwsh = pytest.mark.skipif(not shutil.which("pwsh"), reason="needs pwsh")

SECRETS = {
    "launcher": "launcher-secret-4f1c9e",
    "ire": "ire-secret-7a2b3d",
    "desktop": "desktop-secret-9c8e1f",
    "tinyfish": "tinyfish-secret-5d6e7f",
}

DRIVES = r"""
foreach ($d in "C", "D") { if (-not (Get-PSDrive $d -ErrorAction SilentlyContinue)) { $null = New-PSDrive -Name $d -PSProvider FileSystem -Root $env:HOME -Scope Global } }
"""

LAUNCHER_DRIVER = DRIVES + r"""
$ErrorActionPreference = "Stop"
$env:CCL_LAUNCHER_LIBRARY_ONLY = "1"
. (Join-Path $env:CCL_REPO "windows/launch-claude-inferhub.ps1")
$cfg = Get-CclLaunchConfig
@{ inferhub = $InferHubEnvFile; desktop = $DesktopEnvFile; files = @($cfg.EnvFiles);
   master = (Read-LiteLLMMasterKey) } | ConvertTo-Json -Compress
"""


@pytest.fixture
def sandbox(tmp_path):
    """A copy of the repository at <tmp>/dev/claude-code-launcher with fake old sources."""
    dev = tmp_path / "dev"
    repo = dev / "claude-code-launcher"
    shutil.copytree(REPO, repo, ignore=shutil.ignore_patterns(
        ".git", "pcm", "__pycache__", ".pytest_cache", ".ruff_cache", ".litellm-venv", "logs", ".env", ".env.local"))
    ire = dev / "inference-recommendation-engine" / ".env"
    ire.parent.mkdir(parents=True)
    ire.write_text(f"INFERHUB_API_KEY={SECRETS['ire']}\nINFERHUB_API_URL=https://api.inferhub.dev/v1\n")
    home = tmp_path / "home"
    desk = home / "Desktop" / "configs" / ".env"
    desk.parent.mkdir(parents=True)
    desk.write_text(f"INFERHUB_API_KEY={SECRETS['desktop']}\ntinyfish_api={SECRETS['tinyfish']}\n"
                    f"LITELLM_MASTER_KEY={SECRETS['desktop']}\n")
    env = {"PATH": os.environ["PATH"], "HOME": str(home), "USERPROFILE": str(home), "CCL_REPO": str(repo),
           "CCL_LAST_PICKS": str(tmp_path / "picks.json")}
    return {"repo": repo, "ire": ire, "desktop": desk, "home": home, "env": env, "tmp": tmp_path}


def write_launcher_env(sb, extra=""):
    p = sb["repo"] / ".env"
    p.write_text(f"INFERHUB_API_KEY={SECRETS['launcher']}\nTINYFISH_API_KEY={SECRETS['tinyfish']}\n{extra}")
    return p


def same(a, b):
    return Path(a).resolve() == Path(b).resolve()


def assert_no_secret(text):
    for name, value in SECRETS.items():
        assert value not in text, f"the {name} key value was printed"


def run_launcher(sb):
    drv = sb["tmp"] / "launcher-driver.ps1"
    drv.write_text(LAUNCHER_DRIVER)
    r = subprocess.run(["pwsh", "-NoProfile", "-File", str(drv)], env=sb["env"], capture_output=True, text=True,
                       timeout=180)
    assert r.returncode == 0, r.stderr + r.stdout
    return json.loads(r.stdout.strip().splitlines()[-1]), r


def run_start(sb, *args):
    start = sb["repo"] / "windows" / "litellm" / "start-litellm.ps1"
    r = subprocess.run(["pwsh", "-NoProfile", "-File", str(start), "-ShowEnvSources", "-Port", "4017", *args],
                       env=sb["env"], capture_output=True, text=True, timeout=180)
    return r, r.stdout + r.stderr


# ---- launcher ----

@needs_pwsh
def test_launcher_uses_only_the_launcher_env_when_it_exists(sandbox):
    env_file = write_launcher_env(sandbox)
    out, r = run_launcher(sandbox)
    assert same(out["inferhub"], env_file)
    assert same(out["desktop"], env_file)
    files = [Path(f).resolve() for f in out["files"]]
    assert sandbox["ire"].resolve() not in files and sandbox["desktop"].resolve() not in files
    # the Desktop file's LITELLM_MASTER_KEY is not picked up any more
    assert out["master"] == "local"
    # (the master key is the one value the launcher hands on by design; the driver prints it on purpose)
    assert_no_secret(r.stderr)


@needs_pwsh
def test_launcher_falls_back_to_the_old_files_when_the_launcher_env_is_missing(sandbox):
    out, _ = run_launcher(sandbox)
    assert same(out["inferhub"], sandbox["ire"])
    assert same(out["desktop"], sandbox["desktop"])


@needs_pwsh
def test_launcher_reads_the_master_key_from_the_launcher_env(sandbox):
    write_launcher_env(sandbox, "LITELLM_MASTER_KEY=lm-from-launcher-env\n")
    out, _ = run_launcher(sandbox)
    assert out["master"] == "lm-from-launcher-env"


# ---- start-litellm.ps1 ----

@needs_pwsh
def test_start_litellm_loads_only_the_launcher_env(sandbox):
    env_file = write_launcher_env(sandbox)
    r, text = run_start(sandbox)
    assert r.returncode == 0, text
    assert "loaded env names from launcher" in text and str(env_file) in text
    assert "desktop-configs" not in text and str(sandbox["desktop"]) not in text
    assert "INFERHUB_API_KEY: set" in text and "TINYFISH_API_KEY: set" in text
    assert_no_secret(text)


@needs_pwsh
def test_start_litellm_treats_the_launchers_arguments_as_launcher_only(sandbox):
    # The launcher passes the same file as both -DesktopEnvFile and -InferHubEnvFile.
    env_file = write_launcher_env(sandbox)
    r, text = run_start(sandbox, "-DesktopEnvFile", str(env_file), "-InferHubEnvFile", str(env_file))
    assert r.returncode == 0, text
    assert "loaded env names from launcher" in text
    assert text.count("loaded env names from") == 1
    assert_no_secret(text)


@needs_pwsh
def test_start_litellm_falls_back_to_the_desktop_env_when_the_launcher_env_is_missing(sandbox):
    r, text = run_start(sandbox)
    assert r.returncode == 0, text
    assert "loaded env names from desktop-configs" in text and str(sandbox["desktop"]) in text
    assert "loaded env names from launcher" not in text
    assert_no_secret(text)


@needs_pwsh
def test_start_litellm_aliases_never_print_values(sandbox):
    write_launcher_env(sandbox, f"talivy_x={SECRETS['desktop']}\n")
    local = sandbox["repo"] / "shared" / "litellm" / ".env.local"
    local.write_text("CCL_ENV_ALIASES=TAVILY_API_KEY=talivy_x,EXA_API_KEY=not_there\n")
    r, text = run_start(sandbox)
    assert r.returncode == 0, text
    assert "TAVILY_API_KEY: set" in text and "EXA_API_KEY: missing" in text
    assert_no_secret(text)


# ---- repository rules ----

def test_launcher_env_is_gitignored():
    r = subprocess.run(["git", "check-ignore", "-q", ".env"], cwd=REPO, check=False)
    assert r.returncode == 0, ".env in the repository root must be ignored"
    r = subprocess.run(["git", "check-ignore", "-q", "shared/litellm/.env.local"], cwd=REPO, check=False)
    assert r.returncode == 0


def test_mac_launcher_reads_the_repo_env_first(tmp_path):
    # The Mac launcher already reads <repo>/.env before ~/.config/inferhub/.env.
    src = (REPO / "mac" / "Launch Claude InferHub.command").read_text(encoding="utf-8")
    fns = ""
    for name in ("trim() {", "env_get() {", "secret() {"):
        start = src.index(name)
        fns += src[start:src.index("\n}\n", start) + 3]
    repo, ih = tmp_path / "repo", tmp_path / "ih.env"
    repo.mkdir()
    (repo / ".env").write_text("INFERHUB_API_KEY=from-repo\n")
    ih.write_text("INFERHUB_API_KEY=from-config\n")
    script = f'REPO_ROOT="{repo}"\nIH_ENV_FILE="{ih}"\n{fns}\nsecret INFERHUB_API_KEY'
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=False)
    assert r.stdout == "from-repo", r.stderr
