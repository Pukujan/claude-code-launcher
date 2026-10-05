"""Non-interactive mode of both launchers and the claude-env-exec.mjs wrapper.

The launchers run for real against a tiny health server on a free port (never
the live proxy) with a fake `claude` on PATH. Windows tests need pwsh, the
wrapper tests need node; each is skipped when missing (GitHub's ubuntu runners
have both)."""
import http.server
import json
import os
import shutil
import socket
import subprocess
import sys
import threading

import pytest
from conftest import REPO

WIN = REPO / "windows" / "launch-claude-inferhub.ps1"
MAC = REPO / "mac" / "Launch Claude InferHub.command"
WRAPPER = REPO / "shared" / "integrations" / "claude-env-exec.mjs"
needs_pwsh = pytest.mark.skipif(not shutil.which("pwsh"), reason="needs pwsh")
needs_node = pytest.mark.skipif(not shutil.which("node"), reason="needs node")

# A fake claude: `auth status --json` answers from FAKE_LOGIN; anything else
# prints its arguments and the Anthropic/CKFF/CLAUDE_CODE variables it got.
FAKE_CLAUDE = r"""#!/usr/bin/env python3
import json, os, sys
if sys.argv[1:3] == ["auth", "status"]:
    print(json.dumps({"loggedIn": os.environ.get("FAKE_LOGIN") == "1", "authMethod": "claude.ai"}))
    sys.exit(0)
keep = ("ANTHROPIC_", "CLAUDE_CODE_", "CKFF_", "ckff_")
print(json.dumps({"argv": sys.argv[1:], "cwd": os.getcwd(),
                  "env": {k: v for k, v in os.environ.items() if k.startswith(keep)}}))
sys.exit(int(os.environ.get("FAKE_EXIT", "0")))
"""

# The launcher's Windows paths (D:\, C:\) need drives on Linux pwsh.
WIN_DRIVER = r"""
foreach ($d in "C", "D") { if (-not (Get-PSDrive $d -ErrorAction SilentlyContinue)) { $null = New-PSDrive -Name $d -PSProvider FileSystem -Root $env:HOME -Scope Global } }
& $env:CCL_SCRIPT @args
exit $LASTEXITCODE
"""

POLLUTION = {"ANTHROPIC_AUTH_TOKEN": "ckff-token", "ANTHROPIC_BASE_URL": "https://ckff.example",
             "ckff_api_url": "https://ckff.example", "CLAUDE_CODE_OAUTH_TOKEN": "oauth",
             "ANTHROPIC_CUSTOM_HEADERS": "x: y"}
LEAKS = set(POLLUTION) - {"ANTHROPIC_BASE_URL"}   # BASE_URL is replaced, the rest must go


class Health(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        self.send_response(200 if self.path.startswith("/health/") else 404)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *a):
        pass


@pytest.fixture(scope="module")
def health_port():
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Health)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield srv.server_address[1]
    srv.shutdown()


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture
def box(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    fake = bin_dir / "claude"
    fake.write_text(FAKE_CLAUDE.replace("/usr/bin/env python3", sys.executable, 1))
    fake.chmod(0o755)
    seat = tmp_path / "inferhub_seat.json"
    seat.write_text(json.dumps({"main_inferhub_id": "cb/deepseek-v4.1-flash", "advisor_inferhub_id": "ali/qwen3.8-flash"}))
    picks = tmp_path / "last-picks.json"
    picks.write_text(json.dumps({"main": "cbcn/glm-5.3", "adv": "ali/qwen3.8-flash"}))
    home = tmp_path / "home"
    home.mkdir()
    (tmp_path / "work").mkdir()
    driver = tmp_path / "driver.ps1"
    driver.write_text(WIN_DRIVER)
    return {"tmp": tmp_path, "bin": bin_dir, "seat": seat, "picks": picks, "home": home, "driver": driver}


def base_env(box, port, **extra):
    env = {"PATH": str(box["bin"]) + os.pathsep + os.environ["PATH"], "HOME": str(box["home"]),
           "USERPROFILE": str(box["home"]), "LOCALAPPDATA": str(box["tmp"] / "lad"),
           "CCL_PROXY_PORT": str(port), "LITELLM_PORT": str(port), "CCL_SEAT_FILE": str(box["seat"]),
           "CCL_LAST_PICKS": str(box["picks"]), "CLAUDE_IH_STATE_DIR": str(box["tmp"] / "state"),
           "CLAUDE_IH_LOG_DIR": str(box["tmp"] / "logs"), "INFERHUB_ENV_FILE": str(box["tmp"] / "none.env")}
    env.update(POLLUTION)
    env.update(extra)
    return env


def run_launcher(kind, box, args, env):
    if kind == "windows":
        cmd = ["pwsh", "-NoProfile", "-File", str(box["driver"]), *args]
        env = {**env, "CCL_SCRIPT": str(WIN)}
    else:
        cmd = ["bash", str(MAC), *args]
    return subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)


KINDS = [pytest.param("windows", marks=needs_pwsh), "mac"]


@pytest.mark.parametrize("kind", KINDS)
def test_print_env_json_with_claude_ai_login(kind, box, health_port):
    out = run_launcher(kind, box, ["--non-interactive", "--print-env", "json"], base_env(box, health_port, FAKE_LOGIN="1"))
    assert out.returncode == 0, out.stderr
    doc = json.loads(out.stdout.strip().splitlines()[-1])
    s = doc["set"]
    assert s["ANTHROPIC_BASE_URL"] == f"http://127.0.0.1:{health_port}"
    assert s["ANTHROPIC_MODEL"] == "sonnet"
    assert "ANTHROPIC_SMALL_FAST_MODEL" not in s   # deprecated; the haiku pin covers it
    assert s["ANTHROPIC_DEFAULT_HAIKU_MODEL"] == "claude-haiku-4-5-20251001"
    assert s["ANTHROPIC_DEFAULT_OPUS_MODEL"] == "claude-opus-5-5"
    assert s["ANTHROPIC_DEFAULT_FABLE_MODEL"] == "claude-fable-5"
    assert s["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] == "272000"
    assert s["CLAUDE_CODE_WORKFLOWS"] == "1"
    assert s["CLAUDE_CODE_GLOB_TIMEOUT_SECONDS"] == "120"   # issue #69
    assert "ANTHROPIC_API_KEY" not in s          # the claude.ai login stays in charge
    assert not set(s) & LEAKS                     # nothing inherited leaks through
    assert "ANTHROPIC_AUTH_TOKEN" in doc["unset"] and "ckff_api_url" in doc["unset"]
    assert doc["unset_prefixes"] == ["ANTHROPIC_", "CLAUDE_CODE_", "CKFF_", "ckff_"]
    assert doc["info"]["main"] == "cb/deepseek-v4.1-flash" and doc["info"]["seat_source"] == "seat file"
    assert doc["info"]["proxy_healthy"] is True


@pytest.mark.parametrize("kind", KINDS)
def test_print_env_dotenv_without_login_uses_the_dummy_key(kind, box, health_port):
    out = run_launcher(kind, box, ["--print-env", "dotenv"], base_env(box, health_port, FAKE_LOGIN="0"))
    assert out.returncode == 0, out.stderr
    pairs = dict(line.split("=", 1) for line in out.stdout.splitlines() if line and not line.startswith("#"))
    assert pairs["ANTHROPIC_API_KEY"] == "local"
    assert pairs["ANTHROPIC_MODEL"] == "sonnet"
    assert "ANTHROPIC_AUTH_TOKEN" not in pairs


@pytest.mark.parametrize("kind", KINDS)
def test_env_switch_and_proxy_down_fails_without_starting_anything(kind, box):
    env = base_env(box, free_port(), CCL_PRINT_ENV="json")
    out = run_launcher(kind, box, [], env)
    assert out.returncode == 3, out.stdout + out.stderr
    assert out.stdout.strip() == ""
    assert "never starts it" in out.stderr
    assert not (box["tmp"] / "logs" / "litellm.pid").exists()


@pytest.mark.parametrize("kind", KINDS)
def test_exec_passes_arguments_through(kind, box, health_port):
    args = ["--non-interactive", "--folder", str(box["tmp"] / "work"), "--", "-p", "say hi", "--model", "opus"]
    out = run_launcher(kind, box, args, base_env(box, health_port, FAKE_LOGIN="1"))
    assert out.returncode == 0, out.stderr
    got = json.loads(out.stdout.strip().splitlines()[-1])
    assert got["argv"] == ["-p", "say hi", "--model", "opus"]
    assert os.path.realpath(got["cwd"]) == os.path.realpath(box["tmp"] / "work")
    assert got["env"]["ANTHROPIC_BASE_URL"] == f"http://127.0.0.1:{health_port}"
    assert not set(got["env"]) & LEAKS


@pytest.mark.parametrize("kind", KINDS)
def test_bad_print_format_is_rejected(kind, box, health_port):
    out = run_launcher(kind, box, ["--print-env", "yaml"], base_env(box, health_port))
    assert out.returncode == 2
    assert "json or dotenv" in out.stderr


def run_wrapper(box, args, env):
    return subprocess.run(["node", str(WRAPPER), *args], env=env, capture_output=True, text=True, timeout=120,
                          stdin=subprocess.DEVNULL)


@needs_node
def test_wrapper_applies_the_mac_launcher_env_and_keeps_sdk_variables(box, health_port):
    env = base_env(box, health_port, FAKE_LOGIN="1", CCL_CLAUDE_BIN=str(box["bin"] / "claude"),
                   CLAUDE_CODE_ENTRYPOINT="sdk-ts", CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING="true",
                   CCL_ENV_COMMAND=json.dumps(["bash", str(MAC), "--non-interactive", "--print-env", "json"]))
    mcp = '{"mcpServers":{"paseo":{"type":"http","url":"http://x/"}}}'
    out = run_wrapper(box, ["--output-format", "stream-json", "--mcp-config", mcp, "--model", "sonnet"], env)
    assert out.returncode == 0, out.stderr
    got = json.loads(out.stdout.strip().splitlines()[-1])
    assert got["argv"] == ["--output-format", "stream-json", "--mcp-config", mcp, "--model", "sonnet"]
    e = got["env"]
    assert e["ANTHROPIC_BASE_URL"] == f"http://127.0.0.1:{health_port}"
    assert e["ANTHROPIC_DEFAULT_SONNET_MODEL"] == "claude-sonnet-5"
    assert e["CLAUDE_CODE_ENTRYPOINT"] == "sdk-ts"                    # SDK control variables survive
    assert e["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == "true"
    for name in ("ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ckff_api_url", "ANTHROPIC_CUSTOM_HEADERS"):
        assert name not in e, name


@needs_node
def test_wrapper_propagates_exit_code_and_skips_the_launcher_for_probes(box, health_port):
    env = base_env(box, health_port, CCL_CLAUDE_BIN=str(box["bin"] / "claude"), FAKE_EXIT="7",
                   CCL_ENV_COMMAND=json.dumps(["false"]))
    out = run_wrapper(box, ["--version"], env)     # the launcher command would fail; probes skip it
    assert out.returncode == 7, out.stderr


@needs_node
def test_wrapper_stops_when_the_proxy_is_down(box):
    env = base_env(box, free_port(), CCL_CLAUDE_BIN=str(box["bin"] / "claude"),
                   CCL_ENV_COMMAND=json.dumps(["bash", str(MAC), "--non-interactive", "--print-env", "json"]))
    out = run_wrapper(box, ["-p", "hi"], env)
    assert out.returncode == 3
    assert "argv" not in out.stdout


def rewrite(args, env=None):
    """Calls rewritePermissionMode from the wrapper module directly."""
    code = ("const m = await import(process.argv[1]);"
            "process.stdout.write(JSON.stringify(m.rewritePermissionMode(JSON.parse(process.argv[2]),"
            " JSON.parse(process.argv[3]))));")
    out = subprocess.run(["node", "--input-type=module", "-e", code, WRAPPER.as_uri(), json.dumps(args),
                          json.dumps(env or {})], capture_output=True, text=True, timeout=60)
    assert out.returncode == 0, out.stderr
    return json.loads(out.stdout)


@needs_node
@pytest.mark.parametrize("given, expected", [
    (["--permission-mode", "default", "--allow-dangerously-skip-permissions"],
     ["--permission-mode", "auto", "--allow-dangerously-skip-permissions"]),
    (["--resume", "abc", "--permission-mode=default"], ["--resume", "abc", "--permission-mode=auto"]),
    (["--permission-mode", "plan"], ["--permission-mode", "plan"]),
    (["--permission-mode", "auto"], ["--permission-mode", "auto"]),
    (["--permission-mode", "bypassPermissions"], ["--permission-mode", "bypassPermissions"]),
    (["--permission-mode=acceptEdits"], ["--permission-mode=acceptEdits"]),
    (["-p", "default"], ["-p", "default"]),                  # only the mode value is rewritten
    (["--permission-mode"], ["--permission-mode"]),
    ([], []),
])
def test_wrapper_turns_default_permission_mode_into_auto(given, expected):
    assert rewrite(given) == expected


@needs_node
def test_wrapper_keeps_default_permission_mode_when_asked():
    args = ["--permission-mode", "default", "--permission-mode=default"]
    assert rewrite(args, {"CCL_KEEP_DEFAULT_PERMISSION_MODE": "1"}) == args


@needs_node
def test_wrapper_starts_claude_in_auto_mode_when_paseo_asks_for_default(box, health_port):
    env = base_env(box, health_port, FAKE_LOGIN="1", CCL_CLAUDE_BIN=str(box["bin"] / "claude"),
                   CCL_ENV_COMMAND=json.dumps(["bash", str(MAC), "--non-interactive", "--print-env", "json"]))
    out = run_wrapper(box, ["--permission-mode", "default", "--allow-dangerously-skip-permissions"], env)
    assert out.returncode == 0, out.stderr
    got = json.loads(out.stdout.strip().splitlines()[-1])
    assert got["argv"] == ["--permission-mode", "auto", "--allow-dangerously-skip-permissions"]

    out = run_wrapper(box, ["--permission-mode", "default"], {**env, "CCL_KEEP_DEFAULT_PERMISSION_MODE": "1"})
    assert out.returncode == 0, out.stderr
    assert json.loads(out.stdout.strip().splitlines()[-1])["argv"] == ["--permission-mode", "default"]
