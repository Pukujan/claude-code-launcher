"""Repository rules for the Windows installer (spec: Shape, Key handling, Success conditions 3 and 4)."""
import re

import pytest
from conftest import REPO

INSTALL = REPO / "windows" / "install.ps1"
README = REPO / "windows" / "README-friend.md"
CI = REPO / ".github" / "workflows" / "launcher-ci.yml"
SPEC = REPO / "docs" / "specs" / "windows-package.md"
ONE_LINER = "irm https://github.com/Pukujan/claude-code-launcher/releases/latest/download/install.ps1 | iex"
PINNED = "https://github.com/Pukujan/claude-code-launcher/releases/download/v1.0.1-windows/install.ps1"


def code_lines(text):
    return [line for line in text.splitlines() if not line.lstrip().startswith("#")]


@pytest.mark.spec
def test_installer_and_docs_exist():
    for p in (INSTALL, README, SPEC):
        assert p.is_file(), p


@pytest.mark.spec
@pytest.mark.parametrize("bit", ["pujan", "Teresa", "D:\\", "C:\\work", "C:\\Users", "Desktop\\configs",
                                 "inference-recommendation-engine\\.env", "CCL_ENV_ALIASES", "OneDrive"])
def test_installer_has_no_alex_specific_bits(bit):
    assert bit.lower() not in INSTALL.read_text(encoding="utf-8-sig").lower()


@pytest.mark.spec
def test_installer_never_pipes_downloads_into_iex():
    code = "\n".join(code_lines(INSTALL.read_text(encoding="utf-8-sig")))
    assert "Invoke-Expression" not in code
    assert not re.search(r"\|\s*iex\b", code, re.I)


@pytest.mark.spec
def test_installer_declares_the_spec_parameters():
    text = INSTALL.read_text(encoding="utf-8-sig")
    for p in ("InferHubKey", "InstallDir", "Ref", "Source", "StartPort", "Uninstall", "ChangeKey", "SkipPrereqs",
              "SkipVenv", "NoTask", "NoPath", "NoStart", "NonInteractive"):
        assert re.search(r"\$" + p + r"\b", text), p
    assert "v1.0.1-windows" in text and "v1.0.0-windows" not in text
    assert "--python" in text and "3.12" in text
    for p in ("PortableOnly", "UseSystemTools", "ClaudeConfigDir"):
        assert re.search(r"\$" + p + r"\b", text), p


@pytest.mark.spec
def test_installer_never_writes_the_key_to_install_json_or_the_task():
    text = INSTALL.read_text(encoding="utf-8-sig")
    assert "INFERHUB_API_KEY" in text
    task = re.search(r"function Get-CclTaskArguments.*?\n}", text, re.S)
    assert task and "Key" not in task.group(0).replace("InstallDir", "")


@pytest.mark.spec
def test_friend_readme_has_the_one_liner_and_uninstall():
    text = README.read_text(encoding="utf-8")
    assert ONE_LINER in text
    assert "-Uninstall" in text or "--uninstall" in text
    assert "claude-inferhub" in text and "--set-key" in text
    assert "gh release download" in text


@pytest.mark.spec
def test_ci_runs_the_windows_installer_job_and_publishes_install_ps1():
    ci = CI.read_text(encoding="utf-8")
    assert "windows-installer:" in ci and "windows-latest" in ci
    assert "Invoke-Pester" in ci
    assert "upload-artifact" in ci and "windows/install.ps1" in ci
    assert "hypothesis==" in ci


START = REPO / "windows" / "litellm" / "start-litellm.ps1"


@pytest.mark.spec
def test_installer_asks_for_a_tinyfish_key():
    text = INSTALL.read_text(encoding="utf-8-sig")
    for p in ("TinyFishKey", "SkipTinyFish", "ChangeTinyFishKey"):
        assert re.search(r"\$" + p + r"\b", text), p
    for name in ("CCL_TINYFISH_KEY", "TINYFISH_API_KEY", "tinyfish.env", "agent.tinyfish.ai", "--set-tinyfish-key"):
        assert name in text, name
    assert "Read-Host -AsSecureString" in text


@pytest.mark.spec
def test_packaged_proxy_loads_the_tinyfish_secret():
    text = START.read_text(encoding="utf-8-sig")
    assert "secrets\\tinyfish.env" in text


@pytest.mark.spec
def test_friend_readme_explains_the_free_tinyfish_key():
    text = README.read_text(encoding="utf-8")
    assert "TinyFish" in text and "free" in text.lower()
    assert "agent.tinyfish.ai" in text
    assert "--set-tinyfish-key" in text
    assert "-TinyFishKey" in text


@pytest.mark.spec
def test_docs_show_the_latest_one_liner_and_the_pinned_url():
    for doc in (README, REPO / "README.md", SPEC):
        text = doc.read_text(encoding="utf-8")
        assert ONE_LINER in text, doc
    assert PINNED in README.read_text(encoding="utf-8")


@pytest.mark.spec
def test_ci_runs_the_shim_through_a_real_cmd_exe():
    e2e = (REPO / "tests" / "pester" / "E2E.Tests.ps1").read_text(encoding="utf-8")
    assert "cmd.exe" in e2e and "claude-inferhub.cmd" in e2e


@pytest.mark.spec
def test_installer_uses_no_global_installers():
    # Self-contained install (v1.0.1 #7): no winget, no global uv/pnpm/Claude installers.
    code = "\n".join(code_lines(INSTALL.read_text(encoding="utf-8-sig")))
    for bit in ("winget", "claude.ai/install.ps1", "astral.sh/uv/install.ps1", "get.pnpm.io", "corepack enable",
                "npm install -g", "npm i -g"):
        assert bit not in code, bit


@pytest.mark.spec
def test_installer_pins_every_download_by_sha256():
    text = INSTALL.read_text(encoding="utf-8-sig")
    block = re.search(r"\$script:CclToolSpecs\s*=\s*@\{.*?\n\}", text, re.S)
    assert block, "CclToolSpecs table"
    for name in ("uv", "node", "pnpm", "git", "claude", "python"):
        assert re.search(r"\b" + name + r"\s*=\s*@\{", block.group(0)), name
    assert len(re.findall(r"sha256\s*=\s*'[0-9a-f]{64}'", block.group(0))) >= 4


@pytest.mark.spec
def test_docs_describe_the_one_folder_install():
    for doc in (README, REPO / "README.md", SPEC):
        text = doc.read_text(encoding="utf-8")
        assert "CLAUDE_CONFIG_DIR" in text, doc
        assert "-PortableOnly" in text, doc
    friend = README.read_text(encoding="utf-8")
    assert "Install folder" in friend
    assert "claude-env-exec.mjs" in (REPO / "README.md").read_text(encoding="utf-8")


@pytest.mark.spec
def test_ci_e2e_runs_real_installs_and_snapshots_the_profile():
    e2e = (REPO / "tests" / "pester" / "E2E.Tests.ps1").read_text(encoding="utf-8")
    assert "-PortableOnly" in e2e
    assert "Get-ProfileSnapshot" in e2e
    # The real installs go through one helper that never passes -SkipPrereqs.
    helper = re.search(r"function Invoke-RealInstall \{.*?\n    \}", e2e, re.S)
    assert helper and "SkipPrereqs" not in helper.group(0)
    assert e2e.count("Invoke-RealInstall") >= 3


@pytest.mark.spec
def test_uv_override_gets_a_bare_file_name_on_windows():
    # uv splits --override values on spaces (clap value_delimiter), so a full path under a
    # folder like "D:\a b\install" turns into two missing files. Found by the Windows E2E.
    for rel in ("windows/install.ps1", "windows/litellm/start-litellm.ps1"):
        text = (REPO / rel).read_text(encoding="utf-8-sig")
        for line in text.splitlines():
            if "--override" in line and "pip install" in line:
                arg = line.split("--override", 1)[1].split()[0]
                assert arg in ("$ovrName", "$OverridesName"), f"{rel}: {line.strip()}"


@pytest.mark.spec
def test_windows_scripts_read_text_files_as_utf8():
    # Windows PowerShell 5.1 reads BOM-less files as ANSI, so a non-ASCII install folder in
    # install.json came back garbled (found by the portable E2E under a "José" folder).
    bad = []
    for p in sorted((REPO / "windows").rglob("*.ps1")) + [REPO / "tests/pester/E2E.Tests.ps1"]:
        for n, line in enumerate(p.read_text(encoding="utf-8-sig").splitlines(), 1):
            if "Get-Content" in line and "-Raw" in line and "-Encoding" not in line:
                bad.append(f"{p.relative_to(REPO)}:{n}")
    assert bad == []
