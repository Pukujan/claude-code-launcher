"""shared/ultracode/uc_models.py: UltraCode orchestrator/worker choices (issue #40)."""
import importlib.util
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
from conftest import REPO

spec = importlib.util.spec_from_file_location("uc_models", REPO / "shared" / "ultracode" / "uc_models.py")
uc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(uc)

EXAMPLE = json.loads((REPO / "tests" / "fixtures" / "ultracode" / "config.example.json").read_text())
PROXY = "http://127.0.0.1:4017"
TOP = [{"rank": "1", "name": "DeepSeek V4.1 Flash", "id": "cb/deepseek-v4.1-flash", "eligible": True},
       {"rank": "3", "name": "Gemini 3.8 Flash", "id": "ag/gemini-3.8-flash-high", "eligible": False}]
ENV_ALL = {"REQUESTY_API_KEY": "x", "CKFF_TEST_KEY": "x"}


def build(env=None, which=lambda _: None, home="/nonexistent", **kw):
    return uc.build(EXAMPLE, TOP, PROXY, 8258, env=ENV_ALL if env is None else env,
                    which=which, home=home, **kw)


def test_ids_start_with_claude_and_seats_come_first():
    cfg, choices, _ = build(main_name="DeepSeek V4.1 Flash")
    ids = [c[0] for c in choices]
    assert all(i.startswith("claude") for i in ids)
    assert ids[:2] == ["claude-ih-main", "claude-ih-fast"]  # advisor OFF -> no advisor seat
    assert "DeepSeek V4.1 Flash" in choices[0][1]
    assert [m["id"] for m in cfg["models"]] == ids


def test_advisor_seat_only_when_advisor_on():
    _, choices, _ = build(advisor_name="GLM 5.3")
    assert "claude-ih-advisor" in [c[0] for c in choices]


def test_inferhub_routes_are_anthropic_passthrough_to_litellm():
    cfg, _, _ = build()
    r = cfg["routes"]
    assert r["claude-ih-main"] == {"upstream": PROXY, "model": "sonnet"}
    assert r["claude-ih-fast"] == {"upstream": PROXY, "model": "small-fast"}
    assert r["claude-ih-cb-deepseek-v4-1-flash"] == {"upstream": PROXY, "model": "ih/cb/deepseek-v4.1-flash"}
    assert "type" not in r["claude-ih-ag-gemini-3-8-flash-high"]
    assert cfg["proxy"] == {"listen_port": 8258, "anthropic_upstream": PROXY, "include_stock_models": False,
                            "learn_stock_models": False, "max_tokens_floor": 64000}


def test_gated_rows_are_labelled():
    _, choices, _ = build()
    assert dict(choices)["claude-ih-ag-gemini-3-8-flash-high"].endswith("gated)")


def test_ckff_is_never_offered():
    cfg, choices, notes = build()
    ids = [c[0] for c in choices]
    assert not [i for i in ids if "ckff" in i]
    assert "claude-sneaky" not in ids  # CKFF upstream host
    assert all(c["id"] != "claude-ckff-luna" for c in cfg["router"]["candidates"])
    assert "skip claude-ckff-luna: CKFF" in notes
    assert "ckff" not in json.dumps(cfg).lower()


def test_unusable_own_options_are_dropped():
    _, choices, notes = build()
    ids = [c[0] for c in choices]
    assert "claude-requesty" in ids                     # ${VAR} resolvable
    for gone in ("claude-opus", "claude-minimax-m3", "claude-gpt-5.5-codex", "claude-composer", "claude-local"):
        assert gone not in ids, gone
    assert any("REPLACE" not in n and "claude-minimax-m3: no key" in n for n in notes)


def test_codex_and_cursor_kept_when_installed(tmp_path):
    (tmp_path / ".codex").mkdir()
    (tmp_path / ".codex" / "auth.json").write_text("{}")
    _, choices, _ = build(home=tmp_path, which=lambda n: "/bin/" + n)
    ids = [c[0] for c in choices]
    assert "claude-gpt-5.5-codex" in ids and "claude-composer" in ids


def test_auto_router_keeps_only_usable_non_ckff_candidates():
    cfg, choices, _ = build()
    assert "claude-auto" in [c[0] for c in choices]
    assert [c["id"] for c in cfg["router"]["candidates"]] == ["claude-requesty"]
    assert cfg["router"]["classifier"] == "claude-requesty"
    assert cfg["router"]["default"] == "claude-requesty"


def test_auto_router_dropped_without_non_ckff_candidates():
    cfg, choices, notes = build(env={"CKFF_TEST_KEY": "x"})
    assert "claude-auto" not in [c[0] for c in choices]
    assert "router" not in cfg and "claude-auto" not in cfg["routes"]
    assert any("claude-auto" in n for n in notes)


def test_no_secret_values_reach_the_list(tmp_path):
    top = tmp_path / "top20.txt"
    top.write_text("1|DeepSeek V4.1 Flash|cb/deepseek-v4.1-flash|true|0.022\n")
    ex = tmp_path / "example.json"
    ex.write_text(json.dumps(EXAMPLE))
    out, lst = tmp_path / "config.json", tmp_path / "list.tsv"
    uc.main(["build", "--example", str(ex), "--top20", str(top), "--proxy-base", PROXY,
             "--port", "8258", "--config-out", str(out), "--list-out", str(lst)])
    lines = lst.read_text().splitlines()
    assert lines[0].split("\t")[0] == "claude-ih-main"
    assert "claude-ih-cb-deepseek-v4-1-flash\tDeepSeek V4.1 Flash (InferHub #1)" in lines
    assert json.loads(out.read_text())["proxy"]["listen_port"] == 8258


def test_selection_payload_matches_the_shim():
    assert uc.selection_payload("a", "") == {"orch": "a", "worker": "a", "worker_explicit": False}
    assert uc.selection_payload("a", "a") == {"orch": "a", "worker": "a", "worker_explicit": False}
    assert uc.selection_payload("a", "b") == {"orch": "a", "worker": "b", "worker_explicit": True}


def _free_port():
    import socket
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _write_config(tmp_path, port):
    cfg, _, _ = build()
    cfg["proxy"]["listen_port"] = port
    p = tmp_path / "config.json"
    p.write_text(json.dumps(cfg))
    return p, cfg


def test_preselect_writes_selection_when_no_shim(tmp_path):
    port = _free_port()
    cfgp, _ = _write_config(tmp_path, port)
    state = tmp_path / "state" / "selection.json"
    got = uc.preselect(cfgp, state, "claude-ih-main", "claude-ih-fast", timeout=0.3)
    assert got == (port, "written")
    assert json.loads(state.read_text()) == {"orch": "claude-ih-main", "worker": "claude-ih-fast",
                                             "worker_explicit": True}


def _fake_shim(cfg, upstream, posts):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, obj):
            b = json.dumps(obj).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

        def do_GET(self):
            self._send({"ok": True, "upstream": upstream,
                        "custom_models": [{"id": m["id"]} for m in cfg["models"]] + [{"id": "claude-worker-ih-main"}],
                        "slots": {k: {"model": v.get("model")} for k, v in cfg["routes"].items()}})

        def do_POST(self):
            posts.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
            self._send({"ok": True})
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def test_preselect_posts_to_a_matching_running_shim(tmp_path):
    posts = []
    cfg, _, _ = build()
    srv = _fake_shim(cfg, PROXY, posts)
    try:
        cfgp, _ = _write_config(tmp_path, srv.server_address[1])
        state = tmp_path / "selection.json"
        got = uc.preselect(cfgp, state, "claude-ih-main", "", timeout=1)
        assert got == (srv.server_address[1], "posted")
        assert posts == [{"orchestrator": "claude-ih-main", "worker": ""}]
        assert not state.exists()
    finally:
        srv.shutdown()


def test_preselect_moves_off_a_different_shim(tmp_path):
    posts = []
    cfg, _, _ = build()
    srv = _fake_shim(cfg, "http://127.0.0.1:9999", posts)  # other upstream = other config
    try:
        port = srv.server_address[1]
        cfgp, _ = _write_config(tmp_path, port)
        new_port, how = uc.preselect(cfgp, tmp_path / "s.json", "claude-ih-main", "", timeout=1)
        assert how == "written" and new_port > port and not posts
        assert json.loads(cfgp.read_text())["proxy"]["listen_port"] == new_port
    finally:
        srv.shutdown()


def test_preselect_rejects_unknown_ids(tmp_path):
    cfgp, _ = _write_config(tmp_path, _free_port())
    with pytest.raises(SystemExit):
        uc.preselect(cfgp, tmp_path / "s.json", "claude-ckff-luna", "", timeout=0.3)


def test_launchers_use_the_helper_and_leave_the_global_ultracode_alone():
    win = (REPO / "windows" / "launch-claude-inferhub.ps1").read_text(encoding="utf-8")
    mac = (REPO / "mac" / "Launch Claude InferHub.command").read_text(encoding="utf-8")
    for text in (win, mac):
        assert "uc_models.py" in text
        assert "install.ps1" not in text and "install.sh" not in text
        assert "WindowsApps" not in text
        assert "Install-UltraCodeCommand" not in text and "install_ultracode" not in text
        assert "--no-project" in text
