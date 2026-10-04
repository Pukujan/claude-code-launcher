"""Native Claude Code slots (issue #53): one chain per slot, the same defaults in the
yaml, the Python fallback and both launchers, and CKFF off unless switched on."""
import re
import sys

import pytest
import yaml
from conftest import REPO

sys.path.insert(0, str(REPO / "shared" / "litellm" / "scripts"))
import slots  # noqa: E402

CFG = REPO / "shared" / "litellm" / "config" / "inferhub_fallbacks.yaml"
WIN = REPO / "windows" / "launch-claude-inferhub.ps1"


def test_yaml_and_builtin_defaults_agree():
    doc = yaml.safe_load(CFG.read_text(encoding="utf-8"))
    assert doc["ckff_enabled"] is False
    for s in slots.SLOTS:
        assert doc["slots"][s]["chain"] == slots.BUILTIN_DEFAULTS[s], s
    assert slots.default_slots(CFG) == slots.BUILTIN_DEFAULTS


def test_windows_launcher_defaults_match_the_yaml():
    text = WIN.read_text(encoding="utf-8-sig")
    block = text[text.index("$SlotDefaults = [ordered]@{"):]
    block = block[:block.index("\n}")]
    for s in slots.SLOTS:
        m = re.search(rf'^\s*{s}\s*=\s*@\(([^)]*)\)', block, re.M)
        assert m, s
        assert re.findall(r'"([^"]+)"', m.group(1)) == slots.BUILTIN_DEFAULTS[s], s


def test_defaults_are_alexs_picks():
    d = slots.BUILTIN_DEFAULTS
    assert d["sonnet"] == ["cb/deepseek-v4.1-flash", "ali/qwen3.8-flash", "cbcn/glm-5.3-flash"]
    assert d["haiku"] == d["sonnet"]
    assert d["opus"][:2] == ["cb/gpt-6-astra", "cx/gpt-6.1-sol"] and d["opus"][2].startswith("ali/qwen3.8-max")
    assert d["fable"] == ["cbcn/glm-5.3-flash", "ali/qwen3.8-flash", "cb/deepseek-v4.1-flash"]
    assert not [c for chain in d.values() for c in chain if slots.is_ckff_id(c)]


def test_astra_and_sol_are_not_ckff():
    assert not slots.is_ckff_id("cb/gpt-6-astra") and not slots.is_ckff_id("cx/gpt-6.1-sol")
    assert slots.is_ckff_id("ckff/gpt-6-astra")
    assert slots.is_ckff_deployment({"litellm_params": {"api_key": "os.environ/ckff_api_key"}})
    assert not slots.is_ckff_deployment({"litellm_params": {"api_key": "os.environ/INFERHUB_API_KEY"}})


def test_resolve_order_overrides_then_seat_then_defaults():
    seat = {"slots": {"opus": ["cx/gpt-6.1-sol"], "sonnet": [], "bogus": ["x"]}}
    out = slots.resolve_slots(seat, {"haiku": ["cbcn/minimax-m3", "cbcn/minimax-m3", ""]}, CFG)
    assert out["opus"] == ["cx/gpt-6.1-sol"]
    assert out["sonnet"] == slots.BUILTIN_DEFAULTS["sonnet"]   # empty saved chain = default
    assert out["haiku"] == ["cbcn/minimax-m3"]                 # repeats and blanks dropped
    assert set(out) == set(slots.SLOTS)


def test_parse_slot_arg():
    assert slots.parse_slot_arg("Opus=cb/gpt-6-astra, cx/gpt-6.1-sol") == ("opus", ["cb/gpt-6-astra", "cx/gpt-6.1-sol"])
    with pytest.raises(ValueError):
        slots.parse_slot_arg("main=cb/x")


@pytest.mark.parametrize("raw,want", [("on", True), ("1", True), ("off", False), ("", False), ("maybe", False)])
def test_ckff_switch(raw, want, tmp_path):
    assert slots.ckff_enabled(CFG, {"CCL_CKFF": raw}) is want
    on = tmp_path / "on.yaml"
    on.write_text("ckff_enabled: true\n")
    assert slots.ckff_enabled(on, {}) is True and slots.ckff_enabled(on, {"CCL_CKFF": "off"}) is False


def test_every_served_name_belongs_to_one_slot():
    seen = {}
    for s in slots.SLOTS:
        for n in slots.slot_names(s, ckff_on=False):
            assert n not in seen, (n, seen.get(n), s)
            seen[n] = s
    assert seen["claude-opus-5-5"] == "opus" and seen["claude-fable-5"] == "fable" and seen["advisor"] == "fable"
    assert seen["claude-haiku-4-5"] == "haiku"
    assert "claude-haiku-4-5" not in slots.slot_names("haiku", ckff_on=True)
    for s in slots.SLOTS:
        assert slots.PINS[s] in slots.SLOT_NAMES[s]
