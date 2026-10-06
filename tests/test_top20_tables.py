"""The Windows picker, the Mac picker and the built-in CSV must list the same
Top 20 rows, or the two launchers would offer different models."""
import csv
import re

from conftest import LITELLM, REPO


def windows_rows():
    text = (REPO / "windows" / "launch-claude-inferhub.ps1").read_text(encoding="utf-8-sig")
    pat = re.compile(
        r'@\{ Rank = (\d+);\s+Name = "([^"]+)";\s+Id = "([^"]+)";\s+Eligible = \$(true|false);'
        r'\s+Cost = "([^"]+)";\s+CostOut = "([^"]+)" \}'
    )
    return [(int(r), n, i, e, c, co) for r, n, i, e, c, co in pat.findall(text)]


def mac_rows():
    text = (REPO / "mac" / "Launch Claude InferHub.command").read_text(encoding="utf-8")
    block = re.search(r"^MODELS='(.*?)'", text, re.S | re.M).group(1)
    out = []
    for line in block.strip().splitlines():
        r, n, i, e, c, co = line.split("|")
        out.append((int(r), n, i, e, c, co))
    return out


def csv_rows():
    # The pickers show the best route's cheapest listed asks, so the CSV's ask
    # columns (IRE issue #94) are what must match them, not the supply blend.
    with (LITELLM / "config" / "top20-builtin.csv").open(newline="", encoding="utf-8") as f:
        return [
            (int(r["recommendation_rank"]), r["model_family"],
             r["model_ids"].split(";")[0].strip(), r["recommendation_eligible"],
             r["best_route_min_ask_in_usdc_per_1m"], r["best_route_min_ask_out_usdc_per_1m"])
            for r in csv.DictReader(f)
        ]


def test_windows_has_twenty_rows():
    assert len(windows_rows()) == 20


def test_mac_matches_windows():
    assert mac_rows() == windows_rows()


def test_builtin_csv_matches_windows():
    assert csv_rows() == windows_rows()


def test_default_model_is_rank_one_everywhere():
    win = (REPO / "windows" / "launch-claude-inferhub.ps1").read_text(encoding="utf-8-sig")
    mac = (REPO / "mac" / "Launch Claude InferHub.command").read_text(encoding="utf-8")
    assert '$DefaultModelId = "cb/deepseek-v4.1-flash"' in win
    assert 'DEFAULT_MODEL_ID="cb/deepseek-v4.1-flash"' in mac
    assert windows_rows()[0][2] == "cb/deepseek-v4.1-flash"
