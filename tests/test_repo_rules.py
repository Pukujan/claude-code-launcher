"""Repository rules that are cheap to check on every pull request."""
import re
import subprocess

from conftest import REPO

SOURCES = (REPO / "SOURCES.md").read_text(encoding="utf-8")


def tracked():
    out = subprocess.run(["git", "ls-files"], cwd=REPO, capture_output=True, text=True, check=True).stdout
    return [p for p in out.splitlines() if p]


def test_only_env_example_is_tracked():
    envs = [p for p in tracked() if re.search(r"(^|/)\.env(\.|$)", p)]
    assert envs == [".env.example"]


def test_every_copied_file_has_a_commit_in_sources():
    for path in ("windows/launch-claude-inferhub.ps1", "windows/litellm/start-litellm.ps1",
                 "windows/litellm/stop-litellm.ps1", "mac/Launch Claude InferHub.command",
                 "mac/tests/dry_run.sh", "shared/litellm/sitecustomize.py",
                 "shared/litellm/config/config.yaml", "shared/litellm/config/inferhub_fallbacks.yaml",
                 "shared/litellm/scripts/apply_inferhub_seat.py",
                 "shared/litellm/scripts/merge_litellm_config.py",
                 "shared/litellm/scripts/reload_runtime.py",
                 "shared/litellm/scripts/sync_inferhub_top20.py",
                 "history/acs-inferhub-litellm-v0.2.0/launch-claude-inferhub.ps1"):
        assert (REPO / path).is_file(), path
        row = next((line for line in SOURCES.splitlines() if f"`{path}`" in line), None)
        assert row, f"{path} missing from SOURCES.md"
        assert re.search(r"`[0-9a-f]{7,40}`", row), f"{path} has no commit SHA in SOURCES.md"


def test_launchers_need_no_litellm_ckff_ops_checkout():
    for path in ("windows/launch-claude-inferhub.ps1", "windows/litellm/start-litellm.ps1",
                 "mac/Launch Claude InferHub.command"):
        text = (REPO / path).read_text(encoding="utf-8-sig")
        assert "git clone" not in text and "gh repo clone" not in text, path
        assert "D:\\development\\litellm-ckff-ops" not in text, path


def test_proxy_binds_loopback_only():
    win = (REPO / "windows/litellm/start-litellm.ps1").read_text(encoding="utf-8-sig")
    mac = (REPO / "mac/Launch Claude InferHub.command").read_text(encoding="utf-8")
    assert "'--host', '127.0.0.1'" in win
    assert "--host 127.0.0.1" in mac
    for text in (win, mac):
        assert "--host 0.0.0.0" not in text and "'0.0.0.0'" not in text


def test_stop_script_never_kills_by_port():
    stop = (REPO / "windows/litellm/stop-litellm.ps1").read_text(encoding="utf-8-sig")
    assert "Get-NetTCPConnection" not in stop
    assert "litellm.pid" in stop


def test_no_master_key_is_required_or_generated():
    mac = (REPO / "mac/Launch Claude InferHub.command").read_text(encoding="utf-8")
    win = (REPO / "windows/launch-claude-inferhub.ps1").read_text(encoding="utf-8-sig")
    start = (REPO / "windows/litellm/start-litellm.ps1").read_text(encoding="utf-8-sig")
    assert "openssl rand" not in mac
    assert 'master="local"' in mac
    assert 'return "local"' in win
    assert "'LITELLM_MASTER_KEY'    = 'LITELLM_MASTER_KEY'" not in start


def test_tests_never_use_port_4000():
    for p in (REPO / "tests").glob("*.py"):
        assert "127.0.0.1:4000" not in p.read_text(encoding="utf-8") or p.name == "test_repo_rules.py"
    assert 'PORT" = "4000" ] && { echo "refusing' in (REPO / "mac/tests/dry_run.sh").read_text()
