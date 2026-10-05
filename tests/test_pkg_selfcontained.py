"""The launcher in a self-contained install (spec: Self-contained install, Packaged mode; issue #63).

A v2 install.json names the folder's Claude config and tools. Launcher sessions then run the
recorded claude with CLAUDE_CONFIG_DIR inside the folder, and --print-env hands those over
to integrations. Runs windows/launch-claude-inferhub.ps1 under pwsh; never touches port 4000."""
import json
import os
import secrets
import shutil
import subprocess
import sys

import pytest
from conftest import REPO
from test_pkg_launcher_packaged import WIN, server

pytestmark = pytest.mark.skipif(not shutil.which("pwsh"), reason="needs pwsh")

FAKE_CLAUDE = r"""#!/usr/bin/env python3
import json, os, sys
print(json.dumps({"exe": os.path.abspath(sys.argv[0]), "argv": sys.argv[1:],
                  "claude_config_dir": os.environ.get("CLAUDE_CONFIG_DIR"),
                  "autoupdater": os.environ.get("DISABLE_AUTOUPDATER")}))
"""


@pytest.fixture
def v2(tmp_path):
    home = tmp_path / "home"
    (home / ".claude").mkdir(parents=True)
    root = tmp_path / "install"
    for d in ("secrets", "state", "logs", "bin", "tools/claude", "claude-config"):
        (root / d).mkdir(parents=True)
    (root / "secrets" / "inferhub.env").write_text("INFERHUB_API_KEY=ih-" + secrets.token_hex(8) + "\n", encoding="utf-8")
    claude = root / "tools" / "claude" / "claude.exe"
    claude.write_text(FAKE_CLAUDE.replace("/usr/bin/env python3", sys.executable, 1))
    claude.chmod(0o755)
    # A decoy claude on PATH: the launcher must not pick it.
    decoy_dir = tmp_path / "decoy"
    decoy_dir.mkdir()
    decoy = decoy_dir / "claude"
    decoy.write_text("#!/bin/sh\necho DECOY\n")
    decoy.chmod(0o755)
    return {"tmp": tmp_path, "home": home, "root": root, "claude": claude, "decoy": decoy_dir,
            "instance": secrets.token_hex(16)}


def write_v2(inst, port, legacy=False):
    root = inst["root"]
    doc = {"schema": "claude-code-launcher.install.v2", "version": "1.0.1-windows", "ref": "v1.0.1-windows",
           "port": port, "instance_id": inst["instance"], "task_name": "claude-code-launcher-proxy",
           "claude_settings_created": False, "claude_config_dir": str(root / "claude-config"),
           "tools": {"claude": {"source": "bundled", "path": str(inst["claude"]), "version": "2.1.285"},
                     "python": {"source": "reused", "path": sys.executable, "version": "3"}}}
    if legacy:
        doc = {k: doc[k] for k in ("schema", "version", "ref", "port", "instance_id", "task_name",
                                   "claude_settings_created")}
        doc["schema"] = "claude-code-launcher.install.v1"
    (root / "install.json").write_text(json.dumps(doc), encoding="utf-8")


def env_for(inst):
    return {"PATH": str(inst["decoy"]) + os.pathsep + os.environ["PATH"], "HOME": str(inst["home"]),
            "USERPROFILE": str(inst["home"]), "LOCALAPPDATA": str(inst["tmp"] / "lad"),
            "CCL_HOME": str(inst["root"]), "CLAUDE_CONFIG_DIR": str(inst["home"] / ".claude")}


def launch(args, env):
    return subprocess.run(["pwsh", "-NoProfile", "-File", str(WIN), *args], env=env, capture_output=True,
                          text=True, timeout=180, stdin=subprocess.DEVNULL)


@pytest.mark.spec
def test_print_env_hands_over_the_folder_config_and_claude(v2):
    srv = server(v2["instance"])
    try:
        write_v2(v2, srv.server_address[1])
        out = launch(["--non-interactive", "--print-env", "json"], env_for(v2))
        assert out.returncode == 0, out.stderr
        s = json.loads(out.stdout.strip().splitlines()[-1])["set"]
        assert s["CLAUDE_CONFIG_DIR"] == str(v2["root"] / "claude-config")
        assert s["DISABLE_AUTOUPDATER"] == "1"
        assert s["CCL_CLAUDE_BIN"] == str(v2["claude"])
        path = s.get("PATH") or s.get("Path")
        assert path and path.split(os.pathsep)[0].startswith(str(v2["root"]))
        # Settings go to the folder's config, never to the profile's ~/.claude.
        assert (v2["root"] / "claude-config" / "settings.json").is_file()
        assert not (v2["home"] / ".claude" / "settings.json").exists()
    finally:
        srv.shutdown()


@pytest.mark.spec
def test_non_interactive_runs_the_recorded_claude_with_the_folder_config(v2):
    srv = server(v2["instance"])
    try:
        write_v2(v2, srv.server_address[1])
        out = launch(["--non-interactive", "--", "-p", "hi"], env_for(v2))
        assert out.returncode == 0, out.stdout + out.stderr
        assert "DECOY" not in out.stdout
        doc = json.loads(out.stdout.strip().splitlines()[-1])
        assert doc["exe"] == str(v2["claude"])
        assert doc["argv"] == ["-p", "hi"]
        assert doc["claude_config_dir"] == str(v2["root"] / "claude-config")
        assert doc["autoupdater"] == "1"
    finally:
        srv.shutdown()


@pytest.mark.spec
def test_launch_config_reports_the_folder_tools(v2):
    write_v2(v2, 4997)
    script = (f"$env:CCL_LAUNCHER_LIBRARY_ONLY='1'; . '{WIN}'; "
              "Get-CclLaunchConfig | ConvertTo-Json -Depth 5 -Compress")
    out = subprocess.run(["pwsh", "-NoProfile", "-Command", script], env=env_for(v2), capture_output=True,
                         text=True, timeout=120)
    assert out.returncode == 0, out.stderr
    cfg = json.loads(out.stdout.strip().splitlines()[-1])
    assert cfg["ClaudeConfigDir"] == str(v2["root"] / "claude-config")
    assert cfg["ClaudeBin"] == str(v2["claude"])


@pytest.mark.metamorphic
def test_v1_and_v2_state_give_the_same_anthropic_variables(v2):
    srv = server(v2["instance"])
    try:
        docs = []
        for legacy in (True, False):
            write_v2(v2, srv.server_address[1], legacy=legacy)
            out = launch(["--non-interactive", "--print-env", "json"], env_for(v2))
            assert out.returncode == 0, out.stderr
            s = json.loads(out.stdout.strip().splitlines()[-1])["set"]
            docs.append({k: v for k, v in s.items() if k.startswith("ANTHROPIC_")})
        assert docs[0] == docs[1]
    finally:
        srv.shutdown()


@pytest.mark.spec
def test_a_v1_state_keeps_the_old_claude_config_behaviour(v2):
    srv = server(v2["instance"])
    try:
        write_v2(v2, srv.server_address[1], legacy=True)
        out = launch(["--non-interactive", "--print-env", "json"], env_for(v2))
        assert out.returncode == 0, out.stderr
        assert (v2["home"] / ".claude" / "settings.json").is_file()
    finally:
        srv.shutdown()


@pytest.mark.spec
def test_claude_env_exec_runs_ccl_claude_bin_from_the_plan():
    script = REPO / "shared" / "integrations" / "claude-env-exec.mjs"
    if not shutil.which("node"):
        pytest.skip("needs node")
    code = ("import { applyPlan, resolveClaude } from " + json.dumps(script.as_uri()) + ";"
            "const env = applyPlan({PATH: '/usr/bin'}, {set: {CCL_CLAUDE_BIN: '/x/tools/claude/claude.exe',"
            " CLAUDE_CONFIG_DIR: '/x/claude-config'}, unset: [], unset_prefixes: []});"
            "console.log(JSON.stringify({bin: resolveClaude(env), cfg: env.CLAUDE_CONFIG_DIR}));")
    out = subprocess.run(["node", "--input-type=module", "-e", code], capture_output=True, text=True, timeout=60)
    assert out.returncode == 0, out.stderr
    assert json.loads(out.stdout) == {"bin": "/x/tools/claude/claude.exe", "cfg": "/x/claude-config"}
