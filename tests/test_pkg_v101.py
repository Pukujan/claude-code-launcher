"""v1.0.1-windows fixes (issue #63; spec: Port choice, Claude Code settings, Changes in v1.0.1-windows)."""
import ipaddress
import json
import os
import stat
import subprocess
import sys

import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from conftest import REPO

sys.path.insert(0, str(REPO / "shared" / "claude"))
import ccl_identity as ci  # noqa: E402
import settings_sync as S  # noqa: E402

HELPER = REPO / "shared" / "claude" / "settings_sync.py"


def run(path, *args):
    return subprocess.run([sys.executable, str(HELPER), *args, "--settings", str(path)],
                          capture_output=True, text=True, timeout=60)


def make_read_only(path):
    os.chmod(path, stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)


def make_writable(path):
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)


# ---- 6. loopback ----

@pytest.mark.spec
@pytest.mark.parametrize("host", ["127.0.0.1", "127.0.0.2", "127.1.2.3", "127.255.255.254", "::1", "[::1]",
                                  "::ffff:127.0.0.1", "::ffff:127.0.0.2", "::ffff:7f00:2", "[::ffff:127.9.9.9]",
                                  "0:0:0:0:0:0:0:1", "::1%lo", "localhost", "LOCALHOST"])
def test_loopback_accepts_all_of_127_8_and_ipv6_loopback(host):
    assert ci.is_loopback(host) is True


@pytest.mark.spec
@pytest.mark.parametrize("host", ["128.0.0.1", "126.255.255.255", "10.0.0.1", "0.0.0.0", "::", "::2",
                                  "::ffff:10.0.0.1", "::ffff:128.0.0.1", "", "nope", "127.0.0.1.evil.example",
                                  "1.127.0.0", None, 2130706433, b"127.0.0.1"])
def test_loopback_rejects_everything_else(host):
    assert ci.is_loopback(host) is False


@pytest.mark.property
@given(st.integers(0, 2**24 - 1))
def test_every_127_8_address_is_loopback_plain_and_v4_mapped(n):
    a = ipaddress.IPv4Address((127 << 24) | n)
    assert ci.is_loopback(str(a))
    assert ci.is_loopback("::ffff:" + str(a))


@pytest.mark.property
@given(st.integers(0, 2**32 - 1).filter(lambda n: n >> 24 != 127))
def test_no_other_ipv4_address_is_loopback(n):
    a = str(ipaddress.IPv4Address(n))
    assert not ci.is_loopback(a)
    assert not ci.is_loopback("::ffff:" + a)


# ---- 4. empty and whitespace-only settings.json ----

BLANKS = ["", " ", "\n", "\r\n", "\t \n  ", "\ufeff", "\ufeff  \n"]


@pytest.mark.spec
@pytest.mark.parametrize("text", BLANKS)
def test_sync_treats_a_blank_file_as_an_empty_object(tmp_path, text):
    p = tmp_path / "settings.json"
    p.write_text(text, encoding="utf-8")
    r = run(p, "sync")
    assert r.returncode == 0, r.stderr
    doc = json.loads(p.read_text(encoding="utf-8"))
    assert doc["advisorModel"] == "fable" and doc["model"] == "sonnet" and "modelPicker" in doc


@pytest.mark.spec
@pytest.mark.parametrize("text", BLANKS)
def test_unsync_leaves_a_blank_file_alone(tmp_path, text):
    p = tmp_path / "settings.json"
    p.write_text(text, encoding="utf-8")
    before = p.read_bytes()
    r = run(p, "unsync")
    assert r.returncode == 0, r.stderr
    assert p.read_bytes() == before


@pytest.mark.metamorphic
def test_missing_empty_and_whitespace_files_sync_to_the_same_document(tmp_path):
    docs = []
    for i, text in enumerate([None, "", "   \n"]):
        p = tmp_path / f"s{i}" / "settings.json"
        p.parent.mkdir()
        if text is not None:
            p.write_text(text, encoding="utf-8")
        assert run(p, "sync").returncode == 0
        docs.append(json.loads(p.read_text(encoding="utf-8")))
    assert docs[0] == docs[1] == docs[2]


@pytest.mark.spec
@pytest.mark.parametrize("text", ["{", "[]", "null", "\"x\"", "  garbage  "])
def test_non_blank_invalid_or_non_object_is_still_exit_1_and_untouched(tmp_path, text):
    p = tmp_path / "settings.json"
    p.write_text(text, encoding="utf-8")
    r = run(p, "sync")
    assert r.returncode == 1
    assert p.read_text(encoding="utf-8") == text


# ---- 5. read-only settings.json ----

@pytest.mark.spec
@pytest.mark.parametrize("action,text", [("sync", '{"theme": "dark"}'), ("sync", ""),
                                         ("unsync", '{"model": "sonnet", "advisorModel": "fable", "x": 1}')])
def test_read_only_settings_are_never_changed(tmp_path, action, text):
    p = tmp_path / "settings.json"
    p.write_text(text, encoding="utf-8")
    make_read_only(p)
    try:
        before = p.read_bytes()
        ino = p.stat().st_ino
        r = run(p, action)
        assert r.returncode == 3, (r.returncode, r.stderr)
        assert "read-only" in r.stderr and str(p) in r.stderr
        assert p.read_bytes() == before
        assert p.stat().st_ino == ino            # not replaced by a new file either
        assert not (p.stat().st_mode & stat.S_IWUSR)
    finally:
        make_writable(p)


@pytest.mark.spec
def test_read_only_file_that_needs_no_change_is_exit_0(tmp_path):
    p = tmp_path / "settings.json"
    assert run(p, "sync").returncode == 0
    make_read_only(p)
    try:
        r = run(p, "sync")
        assert r.returncode == 0, r.stderr
    finally:
        make_writable(p)


@pytest.mark.spec
def test_is_read_only_helper(tmp_path):
    p = tmp_path / "settings.json"
    p.write_text("{}", encoding="utf-8")
    assert S.is_read_only(p) is False
    make_read_only(p)
    try:
        assert S.is_read_only(p) is True
    finally:
        make_writable(p)
    assert S.is_read_only(tmp_path / "missing.json") is False


@pytest.mark.property
@settings(max_examples=40, deadline=None, suppress_health_check=[HealthCheck.function_scoped_fixture])
@given(st.dictionaries(st.text(min_size=1, max_size=8), st.integers() | st.text(max_size=8), max_size=5),
       st.sampled_from(["sync", "unsync"]))
def test_a_read_only_file_never_changes_whatever_it_holds(tmp_path_factory, doc, action):
    p = tmp_path_factory.mktemp("ro") / "settings.json"
    p.write_text(json.dumps(doc), encoding="utf-8")
    make_read_only(p)
    try:
        before = p.read_bytes()
        r = run(p, action)
        assert r.returncode in (0, 3)
        assert p.read_bytes() == before
    finally:
        make_writable(p)
