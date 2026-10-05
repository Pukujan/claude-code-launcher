"""v1.0.2-windows (issue #72): the three defects the holdout rerun found in v1.0.1.

#3 here: settings_sync unsync removes CLAUDE_CODE_GLOB_TIMEOUT_SECONDS only when the
launcher's sync added it (recorded next to settings.json), treats "120" and 120 the same,
and never drops an env it didn't create. Also --only-if-ours for configs the launcher
can't prove it wrote (#1). The installer side of #1 and #2 is in tests/pester.
"""
import json
import subprocess
import sys

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from conftest import REPO

sys.path.insert(0, str(REPO / "shared" / "claude"))
import settings_sync as S  # noqa: E402

HELPER = REPO / "shared" / "claude" / "settings_sync.py"
GLOB = "CLAUDE_CODE_GLOB_TIMEOUT_SECONDS"


def run(*args):
    return subprocess.run([sys.executable, str(HELPER), *args], capture_output=True, text=True, timeout=60)


@pytest.mark.spec
@pytest.mark.parametrize("value", ["120", 120, "30", 30, "300"])
def test_a_timeout_the_user_set_survives_unsync_in_any_form(value):
    mine = {"theme": "dark", "env": {GLOB: value}}
    assert S.unsync(mine) == mine


@pytest.mark.spec
@pytest.mark.parametrize("value", ["120", 120])
def test_a_timeout_our_sync_added_goes_in_either_form(value):
    rec = {"glob_timeout_added": True, "env_created": False}
    assert S.unsync({"env": {GLOB: value, "X": "1"}}, rec) == {"env": {"X": "1"}}


@pytest.mark.spec
def test_a_changed_value_stays_even_when_we_added_the_key():
    rec = {"glob_timeout_added": True, "env_created": True}
    assert S.unsync({"env": {GLOB: "30"}}, rec) == {"env": {GLOB: "30"}}


@pytest.mark.spec
def test_env_is_dropped_only_when_our_sync_created_it():
    assert S.unsync({"env": {GLOB: "120"}}, {"glob_timeout_added": True, "env_created": True}) == {}
    assert S.unsync({"env": {GLOB: "120"}}, {"glob_timeout_added": True, "env_created": False}) == {"env": {}}


@pytest.mark.spec
def test_sync_record_tracks_what_sync_added():
    before = {"theme": "dark"}
    after = S.sync(before, S.SLOT_OPTIONS)
    assert S.sync_record(before, after) == {"glob_timeout_added": True, "env_created": True}
    before = {"env": {"X": "1"}}
    assert S.sync_record(before, S.sync(before, S.SLOT_OPTIONS)) == {"glob_timeout_added": True, "env_created": False}
    before = {"env": {GLOB: "120"}}
    assert S.sync_record(before, S.sync(before, S.SLOT_OPTIONS)) == {"glob_timeout_added": False, "env_created": False}


@pytest.mark.spec
def test_sync_contract_mentions_the_timeout_key():
    assert GLOB in (S.sync.__doc__ or "")


@pytest.mark.spec
def test_cli_round_trip_leaves_the_file_and_folder_as_they_were(tmp_path):
    target = tmp_path / "settings.json"
    target.write_text(json.dumps({"theme": "dark"}))
    assert run("sync", "--settings", str(target)).returncode == 0
    assert json.loads(target.read_text())["env"][GLOB] == "120"
    assert run("unsync", "--settings", str(target)).returncode == 0
    assert json.loads(target.read_text()) == {"theme": "dark"}
    assert sorted(p.name for p in tmp_path.iterdir()) == ["settings.json"]


@pytest.mark.spec
@pytest.mark.parametrize("value", ["120", 120])
def test_cli_keeps_the_users_own_timeout_and_env(tmp_path, value):
    target = tmp_path / "settings.json"
    target.write_text(json.dumps({"env": {GLOB: value}}))
    assert run("sync", "--settings", str(target)).returncode == 0
    assert run("unsync", "--settings", str(target)).returncode == 0
    assert json.loads(target.read_text()) == {"env": {GLOB: value}}


@pytest.mark.spec
def test_only_if_ours_leaves_a_config_without_proof_alone(tmp_path):
    target = tmp_path / "settings.json"
    text = json.dumps({"model": "sonnet", "advisorModel": "fable", "theme": "dark"})
    target.write_text(text)
    r = run("unsync", "--only-if-ours", "--settings", str(target))
    assert r.returncode == 0, r.stderr
    assert target.read_text() == text
    assert "no sign" in r.stderr


@pytest.mark.spec
def test_only_if_ours_cleans_a_config_with_our_picker_or_record(tmp_path):
    a = tmp_path / "a" / "settings.json"
    a.parent.mkdir()
    a.write_text(json.dumps({"theme": "dark"}))
    run("sync", "--settings", str(a))
    (a.parent / S.RECORD_NAME).unlink()    # a v1.0.0 install had no record; the picker is the proof
    assert run("unsync", "--only-if-ours", "--settings", str(a)).returncode == 0
    assert json.loads(a.read_text()) == {"theme": "dark", "env": {GLOB: "120"}}
    b = tmp_path / "b" / "settings.json"
    b.parent.mkdir()
    b.write_text(json.dumps({"theme": "dark"}))
    run("sync", "--settings", str(b))
    assert run("unsync", "--only-if-ours", "--settings", str(b)).returncode == 0
    assert json.loads(b.read_text()) == {"theme": "dark"}


timeout_values = st.sampled_from(["120", 120, "30", 30, "300", "", 0, None])
user_env = st.dictionaries(st.text(min_size=1, max_size=8).filter(lambda k: k != GLOB), st.text(max_size=6), max_size=4)


@pytest.mark.property
@settings(max_examples=200, deadline=None)
@given(user_env, timeout_values)
def test_unsync_without_a_record_never_changes_env(env, value):
    doc = {"env": {**env, GLOB: value}}
    assert S.unsync(doc).get("env") == doc["env"]


@pytest.mark.metamorphic
@settings(max_examples=200, deadline=None)
@given(user_env, st.booleans())
def test_string_and_number_forms_get_the_same_treatment(env, added):
    rec = {"glob_timeout_added": added, "env_created": False}
    s = S.unsync({"env": {**env, GLOB: "120"}}, rec)
    n = S.unsync({"env": {**env, GLOB: 120}}, rec)
    assert (GLOB in s["env"]) == (GLOB in n["env"])


@pytest.mark.metamorphic
@settings(max_examples=200, deadline=None)
@given(user_env)
def test_sync_then_unsync_with_its_record_is_the_identity(env):
    before = {"env": dict(env)} if env else {}
    after = S.sync(before, S.SLOT_OPTIONS)
    assert S.unsync(after, S.sync_record(before, after)) == before
