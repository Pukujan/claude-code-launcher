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
                 "mac/tests/dry_run.sh", "mac/lib/nav.sh", "mac/setup.sh", "mac/tests/unit_tests.sh",
                 "shared/litellm/sitecustomize.py",
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


def test_one_mac_launcher():
    assert not (REPO / "macos").exists()
    assert not (REPO / ".github" / "workflows" / "macos-shim.yml").exists()
    ci = (REPO / ".github" / "workflows" / "launcher-ci.yml").read_text(encoding="utf-8")
    assert "name: bash 3.2 compatibility" in ci
    assert "paths:" not in ci  # every PR must report every required check


def test_launchers_pin_every_claude_tier_to_a_seat_alias():
    # A tier Claude Code resolves on its own (e.g. haiku -> claude-haiku-4-5-20251001)
    # is not served by the proxy and 400s, so both launchers pin all four tiers.
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "seat", REPO / "shared" / "litellm" / "scripts" / "apply_inferhub_seat.py")
    seat = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(seat)
    served = {"SONNET": seat.MAIN_ALIASES, "OPUS": seat.ADVISOR_ALIASES,
              "FABLE": seat.ADVISOR_ALIASES, "HAIKU": seat.FAST_ALIASES}
    win = (REPO / "windows" / "launch-claude-inferhub.ps1").read_text(encoding="utf-8")
    mac = (REPO / "mac" / "Launch Claude InferHub.command").read_text(encoding="utf-8")
    for tier, names in served.items():
        w = re.search(rf'\$env:ANTHROPIC_DEFAULT_{tier}_MODEL = "([^"]+)"', win)
        m = re.search(rf'export ANTHROPIC_DEFAULT_{tier}_MODEL="([^"]+)"', mac)
        assert w and w.group(1) in names, tier
        assert m and m.group(1) == w.group(1), tier


def test_launchers_leave_the_claude_ai_login_in_charge_when_keyless():
    # Any ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN / apiKeyHelper outranks the
    # claude.ai login and blocks Artifacts (issue #41). With a keyless proxy and
    # a claude.ai login, both launchers must set no key at all.
    win = (REPO / "windows" / "launch-claude-inferhub.ps1").read_text(encoding="utf-8")
    mac = (REPO / "mac" / "Launch Claude InferHub.command").read_text(encoding="utf-8")
    for text in (win, mac):
        assert "claude auth status --json" in text
        assert "ANTHROPIC_AUTH_TOKEN =" not in text and "export ANTHROPIC_AUTH_TOKEN" not in text
    w = re.search(r'if \(\$master -eq "local" -and \(Test-ClaudeAiLogin\)\) \{(.*?)\} else \{(.*?)\n\}', win, re.S)
    assert w and "ANTHROPIC_API_KEY" not in w.group(1) and "$env:ANTHROPIC_API_KEY = $master" in w.group(2)
    assert len(re.findall(r'\$env:ANTHROPIC_API_KEY =', win)) == 1
    m = re.search(r'if \[ "\$master" = "local" \] && claude_ai_logged_in; then(.*?)else(.*?)\n  fi\n', mac, re.S)
    assert m and "ANTHROPIC_API_KEY" not in m.group(1) and 'export ANTHROPIC_API_KEY="$master"' in m.group(2)
    assert len(re.findall(r'export ANTHROPIC_API_KEY=', mac)) == 1
