"""The hot-reload path works without a master key, but only from loopback."""
import http.server
import json
import threading

import pytest

import reload_runtime


def test_headers_without_key_have_no_authorization():
    assert "Authorization" not in reload_runtime.request_headers(None)
    assert reload_runtime.request_headers("k")["Authorization"] == "Bearer k"


def test_no_dead_windows_paths():
    src = open(reload_runtime.__file__, encoding="utf-8").read()
    assert "D:\\\\claude" not in src and r"D:\claude" not in src


class _Handler(http.server.BaseHTTPRequestHandler):
    seen = []

    def log_message(self, *a):
        pass

    def do_GET(self):
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        _Handler.seen.append(self.headers.get("Authorization"))
        body = json.dumps({"scope": "seat", "updated": 14, "aliases": {}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)


def test_keyless_reload_posts_without_auth(monkeypatch, capsys):
    srv = http.server.HTTPServer(("127.0.0.1", 0), _Handler)  # random port, never 4000
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        monkeypatch.delenv("LITELLM_MASTER_KEY", raising=False)
        monkeypatch.setenv("CLAUDE_IH_ENV_FILES", "")
        monkeypatch.setattr(reload_runtime, "REPO_ROOT", reload_runtime.Path("/nonexistent"))
        monkeypatch.setattr("sys.argv", ["reload_runtime.py", "--base-url",
                                         f"http://127.0.0.1:{srv.server_port}", "--strict"])
        assert reload_runtime.main() == 0
        assert _Handler.seen == [None]
        assert "Reloaded scope=seat" in capsys.readouterr().out
    finally:
        srv.shutdown()


starlette = pytest.importorskip("starlette")
import sitecustomize  # noqa: E402  (needs starlette, installed from the pinned overrides)


@pytest.mark.parametrize("host,ok", [("127.0.0.1", True), ("::1", True), ("192.168.1.5", False), ("0.0.0.0", False)])
def test_keyless_endpoint_accepts_loopback_only(host, ok):
    assert sitecustomize._wb_authorized(None, None, {"client": (host, 5555)}) is ok
    assert sitecustomize._wb_authorized(None, "local", {"client": (host, 5555)}) is ok


def test_keyless_endpoint_rejects_missing_client():
    assert sitecustomize._wb_authorized(None, None, {}) is False


def test_with_master_key_token_must_match():
    scope = {"client": ("127.0.0.1", 1)}
    assert sitecustomize._wb_authorized("sk-x", "sk-x", scope) is True
    assert sitecustomize._wb_authorized("sk-x", "local", scope) is False
    assert sitecustomize._wb_authorized("sk-x", None, scope) is False
