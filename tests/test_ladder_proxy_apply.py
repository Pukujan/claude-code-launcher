"""proxy_apply against a real LiteLLM Router (skipped where litellm is not installed)."""
import sys
from pathlib import Path

import pytest

litellm = pytest.importorskip("litellm")
from litellm import Router  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "shared" / "ladder"))
import ladder as L  # noqa: E402
import proxy_apply  # noqa: E402


def seat(name, rid):
    return {"model_name": name, "litellm_params": {"model": f"openai/{rid}", "api_base": "http://127.0.0.1:9/v1",
                                                    "api_key": "dummy"}}


def test_apply_sets_fallbacks_and_keeps_seat_targets():
    r = Router(model_list=[seat("sonnet", "cb/deepseek-v4.1-flash"), seat("opus", "cbcn/glm-5.3-flash")],
               fallbacks=[{"other-model": ["x"]}])
    plan = L.build_plan("cb/deepseek-v4.1-flash", ["ali/qwen3.8-flash"], "cbcn/glm-5.3-flash",
                        ["cbcn/minimax-m3"], "http://127.0.0.1:9/v1")
    res = proxy_apply.apply_plan(r, plan)
    assert res["upserted"] == ["ih/ali/qwen3.8-flash", "ih/cbcn/minimax-m3"]
    fb = {k: v for d in r.fallbacks for k, v in d.items()}
    assert fb["sonnet"] == ["ih/ali/qwen3.8-flash"]
    assert fb["opus"] == ["ih/cbcn/minimax-m3"]
    assert fb["other-model"] == ["x"]  # unrelated fallbacks survive
    seats = {d["model_name"]: d["litellm_params"]["model"] for d in r.model_list}
    assert seats["sonnet"] == "openai/cb/deepseek-v4.1-flash"  # seat routing untouched
    assert seats["ih/cbcn/minimax-m3"] == "openai/cbcn/minimax-m3"
    assert r.model_group_retry_policy["sonnet"].InternalServerErrorRetries == 3
    # rungs get the same retries as the seats
    assert r.model_group_retry_policy["ih/ali/qwen3.8-flash"].ServiceUnavailableErrorRetries == 3
    # applying again replaces, never duplicates
    proxy_apply.apply_plan(r, L.build_plan("cb/deepseek-v4.1-flash", ["cbcn/deepseek-v4-flash"], None, [], "x"))
    fb = {k: v for d in r.fallbacks for k, v in d.items()}
    assert fb["sonnet"] == ["ih/cbcn/deepseek-v4-flash"] and fb["opus"] == ["ih/cbcn/deepseek-v4-flash"]
    assert [d["model_name"] for d in r.model_list].count("ih/cbcn/deepseek-v4-flash") == 1


def test_cx_rung_uses_responses_api():
    r = Router(model_list=[seat("sonnet", "cb/deepseek-v4.1-flash")])
    proxy_apply.apply_plan(r, L.build_plan("cb/deepseek-v4.1-flash", ["cx/gpt-6.1-sol"], None, [], "x"))
    models = {d["model_name"]: d["litellm_params"]["model"] for d in r.model_list}
    assert models["ih/cx/gpt-6.1-sol"] == "openai/responses/cx/gpt-6.1-sol"
