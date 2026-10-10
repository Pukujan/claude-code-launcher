"""The lab roster's tokens per second reach the picker table and the bundle."""
import json
import sys

from conftest import REPO

sys.path.insert(0, str(REPO / "shared" / "ire"))
import apply_lab_roster as roster  # noqa: E402


def test_apply_copies_tokens_per_second_into_the_picker(tmp_path):
    src = tmp_path / "roster.json"
    bundle = tmp_path / "ire.json"
    table = tmp_path / "table.txt"
    csv_path = tmp_path / "top20.csv"
    src.write_text(json.dumps({
        "cheap": [{
            "route": "cb/deepseek-v4.1-flash",
            "name": "DeepSeek V4.1 Flash",
            "price_in": 0.0003,
            "price_out": 0.0012,
            "tps": 114.8,
        }],
        "frontier": [{
            "route": "cb/claude-opus-5",
            "name": "Claude Opus 5",
            "price_in": 0.09,
            "price_out": 0.45,
            "tps": 95.1,
            "frontier_rank": 1,
        }],
        "utility": [{
            "route": "ali/qwen3.8-omni-flash",
            "name": "Qwen3.8 Omni Flash",
            "price_in": 0.00135,
            "price_out": 0.00423,
            "tps": 45,
        }],
    }), encoding="utf-8")

    picker, text, utility = roster.apply(src, bundle, table, csv_path)

    assert (picker, text, utility) == (2, 1, 1)
    saved = json.loads(bundle.read_text(encoding="utf-8"))
    assert saved["top20"][0]["tps"] == 114.8
    assert saved["top20"][1]["tps"] == 45
    assert saved["frontier"][0]["tps"] == 95.1
    lines = table.read_text(encoding="utf-8").splitlines()
    assert lines[0].endswith("|114.8")
    assert lines[1].endswith("|45")
