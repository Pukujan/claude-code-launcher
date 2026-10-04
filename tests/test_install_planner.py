"""The planner sub-agent installer (issue #53): idempotent, reversible, polite."""
import subprocess
import sys

from conftest import REPO

sys.path.insert(0, str(REPO / "shared" / "claude"))
import install_planner as ip  # noqa: E402

SCRIPT = REPO / "shared" / "claude" / "install_planner.py"


def run(*args):
    return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, check=False)


def test_planner_agent_is_read_only_and_on_opus():
    text = (REPO / "shared" / "claude" / "agents" / "planner.md").read_text(encoding="utf-8")
    front = text.split("---")[1]
    assert "name: planner" in front and "model: opus" in front
    tools = next(line for line in front.splitlines() if line.startswith("tools:"))
    for bad in ("Edit", "Write", "Bash", "NotebookEdit"):
        assert bad not in tools
    assert "plan mode" not in front.lower()


def test_install_is_idempotent_and_uninstall_restores(tmp_path):
    md = tmp_path / "CLAUDE.md"
    original = "# Mine\r\n\r\nKeep this.\r\n"
    md.write_bytes(original.encode())
    assert run("install", "--claude-dir", str(tmp_path)).returncode == 0
    agent = tmp_path / "agents" / "planner.md"
    assert ip.OWNER in agent.read_text(encoding="utf-8")
    after = md.read_bytes()
    assert after.startswith(b"# Mine\r\n") and ip.START.encode() in after and b"\r\n" in after
    r = run("install", "--claude-dir", str(tmp_path))
    assert md.read_bytes() == after and "unchanged" in r.stdout
    assert "current" in run("status", "--claude-dir", str(tmp_path)).stdout
    assert run("uninstall", "--claude-dir", str(tmp_path)).returncode == 0
    assert md.read_bytes() == original.encode() and not agent.exists()


def test_fresh_install_and_uninstall_leave_nothing(tmp_path):
    run("install", "--claude-dir", str(tmp_path))
    assert (tmp_path / "CLAUDE.md").exists()
    run("uninstall", "--claude-dir", str(tmp_path))
    assert not (tmp_path / "CLAUDE.md").exists() and not (tmp_path / "agents" / "planner.md").exists()


def test_someone_elses_planner_is_left_alone(tmp_path):
    agent = tmp_path / "agents" / "planner.md"
    agent.parent.mkdir()
    agent.write_text("---\nname: planner\n---\nmine\n")
    r = run("install", "--claude-dir", str(tmp_path))
    assert r.returncode == 0 and "kept" in r.stdout and agent.read_text() == "---\nname: planner\n---\nmine\n"
    run("uninstall", "--claude-dir", str(tmp_path))
    assert agent.exists()


def test_claude_config_dir_is_honoured(tmp_path):
    assert ip.claude_dir(None, {"CLAUDE_CONFIG_DIR": str(tmp_path)}) == tmp_path
    assert ip.claude_dir("x", {"CLAUDE_CONFIG_DIR": str(tmp_path)}).name == "x"
