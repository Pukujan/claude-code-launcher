"""The Windows launcher in packaged mode (spec: Packaged mode, Port choice, Claude Code settings).

Runs windows/launch-claude-inferhub.ps1 non-interactively under pwsh with CCL_HOME
pointing at a throwaway install folder, a fake claude, and tiny HTTP servers that play
"our proxy" and "somebody else's LiteLLM". Never touches port 4000."""
import http.server
import json
import os
import secrets
import shutil
import subprocess
import sys
import threading

import pytest
from conftest import REPO

WIN = REPO / "windows" / "launch-claude-inferhub.ps1"
pytestmark = pytest.mark.skipif(not shutil.which("pwsh"), reason="needs pwsh")

FAKE_CLAUDE = r"""#!/usr/bin/env python3
import json, os, sys
if sys.argv[1:3] == ["auth", "status"]:
    print(json.dumps({"loggedIn": False, "authMethod": "none"})); sys.exit(0)
print(json.dumps({"argv": sys.argv[1:], "env": {k: v for k, v in os.environ.items() if k.startswith("ANTHROPIC_")}}))
"""
ALEX_BITS = ("D:\\", "C:\\work", "Desktop", "inference-recommendation-engine", ".env.local", "pujan")


def server(instance):
    """A loopback server answering /health/* and /ccl/identity with the given instance (None = no identity)."""
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            if self.path.startswith("/health/"):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"ok")
                return
            if self.path == "/ccl/identity" and instance is not None:
                body = json.dumps({"app": "claude-code-launcher", "instance": instance}).encode()
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.end_headers()
                self.wfile.write(body)
                return
            self.send_response(404)
            self.end_headers()

        def log_message(self, *a):
            pass
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


@pytest.fixture
def inst(tmp_path):
    home = tmp_path / "home"
    (home / ".claude").mkdir(parents=True)
    root = tmp_path / "install"
    for d in ("secrets", "state", "logs", "bin"):
        (root / d).mkdir(parents=True)
    key = "ih-" + secrets.token_hex(16)
    (root / "secrets" / "inferhub.env").write_text(f"INFERHUB_API_KEY={key}\n", encoding="utf-8")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    fake = bin_dir / "claude"
    fake.write_text(FAKE_CLAUDE.replace("/usr/bin/env python3", sys.executable, 1))
    fake.chmod(0o755)
    instance = secrets.token_hex(16)
    return {"tmp": tmp_path, "home": home, "root": root, "key": key, "bin": bin_dir, "instance": instance}


def write_state(inst, port):
    doc = {"schema": "claude-code-launcher.install.v1", "version": "1.0.0-windows", "ref": "v1.0.0-windows",
           "port": port, "instance_id": inst["instance"], "task_name": "claude-code-launcher-proxy",
           "claude_settings_created": False}
    (inst["root"] / "install.json").write_text(json.dumps(doc), encoding="utf-8")


def env_for(inst, **extra):
    env = {"PATH": str(inst["bin"]) + os.pathsep + os.environ["PATH"], "HOME": str(inst["home"]),
           "USERPROFILE": str(inst["home"]), "LOCALAPPDATA": str(inst["tmp"] / "lad"),
           "CCL_HOME": str(inst["root"]), "CLAUDE_CONFIG_DIR": str(inst["home"] / ".claude")}
    env.update(extra)
    return env


def launch(inst, args, env):
    return subprocess.run(["pwsh", "-NoProfile", "-File", str(WIN), *args], env=env, capture_output=True,
                          text=True, timeout=180, stdin=subprocess.DEVNULL)


@pytest.mark.spec
def test_packaged_print_env_uses_the_saved_port_when_it_is_ours(inst):
    srv = server(inst["instance"])
    try:
        port = srv.server_address[1]
        write_state(inst, port)
        out = launch(inst, ["--non-interactive", "--print-env", "json"], env_for(inst))
        assert out.returncode == 0, out.stderr
        doc = json.loads(out.stdout.strip().splitlines()[-1])
        assert doc["set"]["ANTHROPIC_BASE_URL"] == f"http://127.0.0.1:{port}"
    finally:
        srv.shutdown()


@pytest.mark.spec
def test_packaged_never_points_claude_at_a_foreign_proxy(inst):
    foreign = server(None)            # answers /health like LiteLLM, but has no identity
    try:
        port = foreign.server_address[1]
        write_state(inst, port)
        out = launch(inst, ["--non-interactive", "--print-env", "json"], env_for(inst))
        assert out.returncode == 3, out.stdout + out.stderr
        assert f"127.0.0.1:{port}" not in out.stdout
    finally:
        foreign.shutdown()


@pytest.mark.spec
def test_packaged_rejects_another_installs_proxy(inst):
    other = server(secrets.token_hex(16))   # a claude-code-launcher proxy, but not this install's
    try:
        write_state(inst, other.server_address[1])
        out = launch(inst, ["--non-interactive", "--print-env", "json"], env_for(inst))
        assert out.returncode == 3
    finally:
        other.shutdown()


@pytest.mark.spec
def test_non_interactive_creates_settings_with_the_fable_advisor(inst):
    srv = server(inst["instance"])
    try:
        write_state(inst, srv.server_address[1])
        settings = inst["home"] / ".claude" / "settings.json"
        assert not settings.exists()
        out = launch(inst, ["--non-interactive", "--print-env", "json"], env_for(inst))
        assert out.returncode == 0, out.stderr
        doc = json.loads(settings.read_text(encoding="utf-8"))
        assert doc["advisorModel"] == "fable" and doc["model"] == "sonnet"
        json.loads(out.stdout.strip())          # stdout is exactly one JSON document
    finally:
        srv.shutdown()


@pytest.mark.spec
def test_non_interactive_keeps_unrelated_settings(inst):
    srv = server(inst["instance"])
    try:
        write_state(inst, srv.server_address[1])
        settings = inst["home"] / ".claude" / "settings.json"
        settings.write_text(json.dumps({"theme": "dark", "advisorModel": "opus"}), encoding="utf-8")
        assert launch(inst, ["--non-interactive", "--print-env", "json"], env_for(inst)).returncode == 0
        doc = json.loads(settings.read_text(encoding="utf-8"))
        assert doc["theme"] == "dark" and doc["advisorModel"] == "fable"
    finally:
        srv.shutdown()


@pytest.mark.spec
def test_the_key_never_reaches_stdout_or_stderr(inst):
    srv = server(inst["instance"])
    try:
        write_state(inst, srv.server_address[1])
        for args in (["--non-interactive", "--print-env", "json"], ["--non-interactive", "--print-env", "dotenv"],
                     ["--non-interactive", "--", "-p", "hi"]):
            out = launch(inst, args, env_for(inst))
            assert inst["key"] not in out.stdout and inst["key"] not in out.stderr, args
    finally:
        srv.shutdown()


@pytest.mark.spec
def test_packaged_config_has_no_alex_paths(inst):
    write_state(inst, 4999)
    script = (f"$env:CCL_LAUNCHER_LIBRARY_ONLY='1'; . '{WIN}'; "
              "Get-CclLaunchConfig | ConvertTo-Json -Depth 5 -Compress")
    out = subprocess.run(["pwsh", "-NoProfile", "-Command", script], env=env_for(inst), capture_output=True,
                         text=True, timeout=120)
    assert out.returncode == 0, out.stderr
    cfg = json.loads(out.stdout.strip().splitlines()[-1])
    assert cfg["Packaged"] is True
    assert cfg["Port"] == 4999 and cfg["InstanceId"] == inst["instance"]
    flat = json.dumps(cfg)
    for bit in ALEX_BITS:
        assert bit.replace("\\", "\\\\") not in flat and bit not in flat, bit
    assert any(str(inst["root"] / "secrets") in f for f in cfg["EnvFiles"])
    assert cfg["StartDir"] == str(inst["home"])


@pytest.mark.spec
def test_unpackaged_config_keeps_alex_setup(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    env = {"PATH": os.environ["PATH"], "HOME": str(home), "USERPROFILE": str(home)}
    # Alex's unpackaged paths (D:\, C:\) need drives on Linux pwsh, as in test_noninteractive.py.
    drives = ('foreach ($d in "C", "D") { if (-not (Get-PSDrive $d -ErrorAction SilentlyContinue)) '
              '{ $null = New-PSDrive -Name $d -PSProvider FileSystem -Root $env:HOME -Scope Global } }; ')
    script = (drives + f"$env:CCL_LAUNCHER_LIBRARY_ONLY='1'; . '{WIN}'; "
              "Get-CclLaunchConfig | ConvertTo-Json -Depth 5 -Compress")
    out = subprocess.run(["pwsh", "-NoProfile", "-Command", script], env=env, capture_output=True, text=True, timeout=120)
    assert out.returncode == 0, out.stderr
    cfg = json.loads(out.stdout.strip().splitlines()[-1])
    assert cfg["Packaged"] is False and cfg["Port"] == 4000
    assert "D:\\development" in cfg["ProjectRoots"] and "C:\\work" in cfg["ProjectRoots"]
    assert any(f.endswith(".env.local") for f in cfg["EnvFiles"])


@pytest.mark.metamorphic
def test_a_different_port_changes_only_the_base_url(inst):
    a, b = server(inst["instance"]), server(inst["instance"])
    try:
        docs = []
        for srv in (a, b):
            write_state(inst, srv.server_address[1])
            out = launch(inst, ["--non-interactive", "--print-env", "json"], env_for(inst))
            assert out.returncode == 0, out.stderr
            docs.append(json.loads(out.stdout.strip().splitlines()[-1])["set"])
        pa, pb = a.server_address[1], b.server_address[1]
        assert docs[0].pop("ANTHROPIC_BASE_URL") == f"http://127.0.0.1:{pa}"
        assert docs[1].pop("ANTHROPIC_BASE_URL") == f"http://127.0.0.1:{pb}"
        assert docs[0] == docs[1]
    finally:
        a.shutdown()
        b.shutdown()


@pytest.mark.spec
def test_packaged_env_files_read_the_tinyfish_secret_between_inferhub_and_local(inst):
    write_state(inst, 4998)
    script = (f"$env:CCL_LAUNCHER_LIBRARY_ONLY='1'; . '{WIN}'; "
              "Get-CclLaunchConfig | ConvertTo-Json -Depth 5 -Compress")
    out = subprocess.run(["pwsh", "-NoProfile", "-Command", script], env=env_for(inst), capture_output=True,
                         text=True, timeout=120)
    assert out.returncode == 0, out.stderr
    files = json.loads(out.stdout.strip().splitlines()[-1])["EnvFiles"]
    names = [f.replace("\\", "/").rsplit("/", 1)[-1] for f in files]
    assert names == ["inferhub.env", "tinyfish.env", "local.env"], files
