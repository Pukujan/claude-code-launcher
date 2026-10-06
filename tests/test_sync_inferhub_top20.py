"""The vendored InferHub generator prices a row from its best-route ask.

IRE issue #94: the shown price must be the price of the route the row names.
A CSV that predates the ask columns still generates, on the supply blend.
"""
from pathlib import Path

import sync_inferhub_top20

ASK_ROW = {
    "recommendation_rank": "1",
    "model_family": "DeepSeek V4.1 Flash",
    "recommendation_eligible": "true",
    "model_ids": "cb/deepseek-v4.1-flash;ali/deepseek-v4.1-flash",
    "supply_weighted_median_cost_usdc_per_1m": "0.015792",
    "best_route_min_ask_in_usdc_per_1m": "0.00015",
    "best_route_min_ask_out_usdc_per_1m": "0.0006",
}

BLEND_ROW = {
    "recommendation_rank": "1",
    "model_family": "DeepSeek V4.1 Flash",
    "recommendation_eligible": "true",
    "model_ids": "cb/deepseek-v4.1-flash",
    "supply_weighted_median_cost_usdc_per_1m": "0.022",
}


def price_lines(row):
    text = sync_inferhub_top20.build_yaml([row], "https://api.inferhub.dev/v1", Path("x.csv"))
    return [ln.strip() for ln in text.splitlines() if "cost_per_token" in ln]


def test_ask_pair_wins_over_the_blend():
    assert price_lines(ASK_ROW) == [
        "input_cost_per_token: 1.5e-10",
        "output_cost_per_token: 6e-10",
    ]


def test_blend_row_still_generates():
    assert price_lines(BLEND_ROW) == ["input_cost_per_token: 2.2e-08"]


def test_blend_row_writes_no_output_cost():
    assert not any("output_cost_per_token" in ln for ln in price_lines(BLEND_ROW))


def test_description_names_the_basis():
    ask = sync_inferhub_top20.build_yaml([ASK_ROW], "https://api.inferhub.dev/v1", Path("x.csv"))
    blend = sync_inferhub_top20.build_yaml([BLEND_ROW], "https://api.inferhub.dev/v1", Path("x.csv"))
    assert "price basis: best-route ask, USD per 1M tokens" in ask
    assert "price basis: supply blend, USD per 1M tokens" in blend
