"""shared/claude/settings_sync.py: Claude Code settings.json merge (spec: Claude Code settings)."""
import json
import random
import subprocess
import sys

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from conftest import REPO

sys.path.insert(0, str(REPO / "shared" / "claude"))
import settings_sync as S  # noqa: E402

HELPER = REPO / "shared" / "claude" / "settings_sync.py"
OURS = {"model", "advisorModel", "modelPicker", "env"}   # env: the search timeout (issue #69)
GLOB = "CLAUDE_CODE_GLOB_TIMEOUT_SECONDS"
OPTIONS = [
    {"model": "sonnet", "label": "Sonnet slot (main)", "description": "Main chat chain via local LiteLLM", "behavesAs": "claude-sonnet-5"},
    {"model": "fable", "label": "Fable slot (advisor)", "description": "Advisor chain via local LiteLLM", "behavesAs": "claude-fable-5"},
    {"model": "ih/cb/deepseek-v4.1-flash", "label": "DeepSeek V4.1 Flash (InferHub ih/)", "description": "IRE Top 20 #1; eligible - direct, no slot chain", "behavesAs": "claude-sonnet-5"},
]

json_scalar = st.none() | st.booleans() | st.integers(-10**6, 10**6) | st.text(max_size=12)
json_value = st.recursive(json_scalar, lambda c: st.lists(c, max_size=3) | st.dictionaries(st.text(max_size=8), c, max_size=3), max_leaves=8)
other_keys = st.text(min_size=1, max_size=12).filter(lambda k: k not in OURS)
user_settings = st.dictionaries(other_keys, json_value, max_size=8)


def run(*args, env=None):
    return subprocess.run([sys.executable, str(HELPER), *args], capture_output=True, text=True, env=env, timeout=60)


# ---- spec ----

@pytest.mark.spec
def test_sync_sets_the_three_keys():
    out = S.sync({}, OPTIONS)
    assert out["model"] == "sonnet"
    assert out["advisorModel"] == "fable"
    assert out["modelPicker"] == {"options": OPTIONS}


@pytest.mark.spec
def test_sync_overrides_a_different_advisor_and_keeps_the_rest():
    src = {"advisorModel": "opus", "permissions": {"allow": ["Bash(ls)"]}, "theme": "dark"}
    out = S.sync(src, OPTIONS)
    assert out["advisorModel"] == "fable"
    assert out["permissions"] == {"allow": ["Bash(ls)"]} and out["theme"] == "dark"
    assert src["advisorModel"] == "opus"  # input not mutated


@pytest.mark.spec
def test_cli_creates_a_missing_file_and_folder(tmp_path):
    target = tmp_path / "new" / ".claude" / "settings.json"
    opts = tmp_path / "opts.json"
    opts.write_text(json.dumps(OPTIONS))
    r = run("sync", "--settings", str(target), "--options-file", str(opts))
    assert r.returncode == 0, r.stderr
    assert r.stdout == ""
    assert "created" in r.stderr
    doc = json.loads(target.read_text(encoding="utf-8"))
    assert doc["advisorModel"] == "fable" and doc["model"] == "sonnet"
    assert not target.read_bytes().startswith(b"\xef\xbb\xbf")


@pytest.mark.spec
def test_cli_uses_claude_config_dir_when_no_settings_path(tmp_path):
    import os
    env = dict(os.environ, CLAUDE_CONFIG_DIR=str(tmp_path / "cfg"))
    r = run("sync", env=env)
    assert r.returncode == 0, r.stderr
    assert json.loads((tmp_path / "cfg" / "settings.json").read_text())["advisorModel"] == "fable"


@pytest.mark.spec
def test_cli_reports_unchanged_on_second_run(tmp_path):
    target = tmp_path / "settings.json"
    run("sync", "--settings", str(target))
    before = target.read_bytes()
    r = run("sync", "--settings", str(target))
    assert r.returncode == 0 and "unchanged" in r.stderr
    assert target.read_bytes() == before


@pytest.mark.spec
def test_cli_leaves_invalid_json_untouched(tmp_path):
    target = tmp_path / "settings.json"
    target.write_text("{ not json", encoding="utf-8")
    r = run("sync", "--settings", str(target))
    assert r.returncode == 1
    assert target.read_text(encoding="utf-8") == "{ not json"


@pytest.mark.spec
def test_unsync_removes_only_ours():
    src = {"theme": "dark", "env": {"X": "1"}}
    synced = S.sync(src, OPTIONS)
    # Since #72, unsync takes the search timeout back only with sync's record.
    assert S.unsync(synced, S.sync_record(src, synced)) == {"theme": "dark", "env": {"X": "1"}}


@pytest.mark.spec
def test_unsync_keeps_values_the_user_chose():
    mine = {"model": "opus", "advisorModel": "opus", "modelPicker": {"options": [{"model": "x", "label": "x", "description": "my own"}]}}
    assert S.unsync(mine) == mine


@pytest.mark.spec
def test_cli_unsync(tmp_path):
    target = tmp_path / "settings.json"
    target.write_text(json.dumps({"theme": "dark"}))
    run("sync", "--settings", str(target))
    r = run("unsync", "--settings", str(target))
    assert r.returncode == 0, r.stderr
    assert json.loads(target.read_text()) == {"theme": "dark"}


@pytest.mark.spec
def test_sync_adds_the_search_timeout():
    # Claude Code kills ripgrep after 20 s by default; cold scans on Windows take longer (issue #69).
    assert S.sync({}, OPTIONS)["env"] == {GLOB: "120"}


@pytest.mark.spec
def test_sync_keeps_a_search_timeout_the_user_set_and_the_rest_of_env():
    src = {"env": {GLOB: "300", "X": "1"}}
    out = S.sync(src, OPTIONS)
    assert out["env"] == {GLOB: "300", "X": "1"}
    assert src == {"env": {GLOB: "300", "X": "1"}}  # input not mutated


@pytest.mark.spec
def test_sync_adds_the_timeout_next_to_other_env_values():
    assert S.sync({"env": {"X": "1"}}, OPTIONS)["env"] == {"X": "1", GLOB: "120"}


@pytest.mark.spec
def test_sync_leaves_an_env_that_is_not_an_object_alone():
    assert S.sync({"env": "odd"}, OPTIONS)["env"] == "odd"


@pytest.mark.spec
def test_unsync_removes_the_timeout_only_while_it_is_ours():
    synced = S.sync({}, OPTIONS)
    assert S.unsync(synced, S.sync_record({}, synced)) == {}
    mine = {"env": {GLOB: "300"}}
    assert S.unsync(mine) == mine


@pytest.mark.spec
def test_cli_adds_the_timeout_on_disk(tmp_path):
    target = tmp_path / "settings.json"
    target.write_text(json.dumps({"theme": "dark"}))
    assert run("sync", "--settings", str(target)).returncode == 0
    assert json.loads(target.read_text())["env"][GLOB] == "120"


# ---- property ----

user_env = st.dictionaries(st.text(min_size=1, max_size=12).filter(lambda k: k != GLOB), st.text(max_size=8), max_size=5)


@pytest.mark.property
@settings(max_examples=150, deadline=None)
@given(user_settings, user_env)
def test_sync_keeps_every_user_env_value_and_unsync_restores_it(s, env):
    src = dict(s, env=env) if env else s
    out = S.sync(src, OPTIONS)
    assert out["env"] == {**env, GLOB: "120"}
    assert S.unsync(out, S.sync_record(src, out)) == src


@pytest.mark.property
@settings(max_examples=100, deadline=None)
@given(user_settings, st.text(min_size=1, max_size=6))
def test_sync_never_overwrites_a_user_timeout(s, value):
    out = S.sync(dict(s, env={GLOB: value}), OPTIONS)
    assert out["env"][GLOB] == value


@pytest.mark.property
@settings(max_examples=200, deadline=None)
@given(user_settings)
def test_sync_preserves_every_unrelated_key(s):
    out = S.sync(s, OPTIONS)
    for k, v in s.items():
        assert out[k] == v
    assert set(out) == set(s) | OURS


@pytest.mark.property
@settings(max_examples=200, deadline=None)
@given(user_settings, st.sampled_from([None, "opus", "fable", 3]), st.sampled_from([None, "sonnet", "haiku"]))
def test_sync_is_idempotent(s, adv, model):
    if adv is not None:
        s = dict(s, advisorModel=adv)
    if model is not None:
        s = dict(s, model=model)
    once = S.sync(s, OPTIONS)
    assert S.sync(once, OPTIONS) == once


@pytest.mark.property
@settings(max_examples=200, deadline=None)
@given(user_settings)
def test_unsync_inverts_sync_for_settings_without_our_keys(s):
    out = S.sync(s, OPTIONS)
    assert S.unsync(out, S.sync_record(s, out)) == s


@pytest.mark.property
@settings(max_examples=50, deadline=None)
@given(user_settings)
def test_cli_round_trip_keeps_unrelated_keys(tmp_path_factory, s):
    target = tmp_path_factory.mktemp("s") / "settings.json"
    target.write_text(json.dumps(s), encoding="utf-8")
    assert run("sync", "--settings", str(target)).returncode == 0
    doc = json.loads(target.read_text(encoding="utf-8"))
    assert {k: doc[k] for k in s} == s and doc["advisorModel"] == "fable"


# ---- metamorphic ----

@pytest.mark.metamorphic
@settings(max_examples=150, deadline=None)
@given(user_settings, st.randoms(use_true_random=False))
def test_reordering_keys_does_not_change_the_result(s, rnd):
    items = list(s.items())
    rnd.shuffle(items)
    assert S.sync(dict(items), OPTIONS) == S.sync(s, OPTIONS)


@pytest.mark.metamorphic
def test_reordered_file_gives_the_same_document(tmp_path):
    base = {"theme": "dark", "env": {"A": "1"}, "advisorModel": "opus", "hooks": {}, "z": [1, 2]}
    docs = []
    for i in range(5):
        items = list(base.items())
        random.Random(i).shuffle(items)
        p = tmp_path / f"s{i}.json"
        p.write_text(json.dumps(dict(items)))
        assert run("sync", "--settings", str(p)).returncode == 0
        docs.append(json.loads(p.read_text()))
    assert all(d == docs[0] for d in docs)


@pytest.mark.metamorphic
def test_sync_twice_on_disk_equals_once(tmp_path):
    a, b = tmp_path / "a.json", tmp_path / "b.json"
    for p in (a, b):
        p.write_text(json.dumps({"theme": "light"}))
    run("sync", "--settings", str(a))
    run("sync", "--settings", str(b))
    run("sync", "--settings", str(b))
    assert a.read_bytes() == b.read_bytes()
