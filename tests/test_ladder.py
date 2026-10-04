"""Fallback ladder rules, picker input handling, and the proxy plan."""
import io
import json
import os
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "shared" / "ladder"))
import inputs as I  # noqa: E402
import ladder as L  # noqa: E402


def ire_bundle():
    """The built-in inputs: the launchers' Top 20 table plus the fixed chains."""
    return I.builtin_inputs()


class Defaults(unittest.TestCase):
    def setUp(self):
        self.b = ire_bundle()
        os.environ.pop("CCL_OPT_IN_MODELS", None)

    def test_stock_chains_when_nothing_blocks(self):
        self.assertEqual(L.default_ladder(self.b, "main", "cb/deepseek-v4.1-flash"),
                         ["ali/qwen3.8-flash", "cbcn/deepseek-v4-flash"])
        self.assertEqual(L.default_ladder(self.b, "advisor", "cbcn/glm-5.3-flash"), ["cbcn/minimax-m3"])

    def test_fixed_chains_are_the_builtin_defaults(self):
        self.assertEqual(I.FIXED_LADDERS["main"]["fallbacks"], ["ali/qwen3.8-flash", "cbcn/deepseek-v4-flash"])
        self.assertEqual(I.FIXED_LADDERS["advisor"]["fallbacks"], ["cbcn/minimax-m3"])
        self.assertEqual(I.FIXED_RETRY, {"retries": 1, "cooldown_seconds": 180})

    def test_load_inputs_falls_back_without_ire(self):
        b = I.load_inputs(None, use_ire=False)
        self.assertEqual(b["source"]["kind"], "builtin")
        self.assertEqual(len(b["top20"]), 20)

    def test_load_inputs_uses_an_ire_bundle_when_given(self):
        import tempfile
        bundle = dict(I.builtin_inputs(), source={"kind": "github", "detail": "x"},
                      ladders={"main": {"fallbacks": ["cbcn/minimax-m3"]}, "advisor": {"fallbacks": []}})
        with tempfile.TemporaryDirectory() as t:
            p = Path(t) / "b.json"
            p.write_text(json.dumps(bundle))
            b = I.load_inputs(p, use_ire=False)
        self.assertEqual(b["source"]["kind"], "ire")
        self.assertEqual(L.default_ladder(b, "main", "cb/deepseek-v4.1-flash"), ["cbcn/minimax-m3"])

    def test_bad_ire_bundle_is_ignored(self):
        import tempfile
        with tempfile.TemporaryDirectory() as t:
            p = Path(t) / "b.json"
            p.write_text("{broken")
            self.assertEqual(I.load_inputs(p, use_ire=False)["source"]["kind"], "builtin")

    def test_primary_removed_and_replaced_from_top20(self):
        lad = L.default_ladder(self.b, "main", "ali/qwen3.8-flash")
        self.assertNotIn("ali/qwen3.8-flash", lad)
        self.assertEqual(lad, ["cbcn/deepseek-v4-flash", "cb/deepseek-v4.1-flash"])

    def test_blocked_vendor_dropped(self):
        self.assertEqual(L.default_ladder(self.b, "main", "cb/deepseek-v4.1-flash", ["cbcn"]),
                         ["ali/qwen3.8-flash"])

    def test_never_more_than_three_and_only_cheap_eligible(self):
        b = dict(self.b, ladders={"main": {"fallbacks": [
            "ali/glm-5.2", "ag/gemini-3.8-flash-high", "ali/qwen3.8-flash", "cbcn/minimax-m3",
            "cbcn/deepseek-v4-flash", "cbcn/glm-5.3-flash"]}})
        lad = L.default_ladder(b, "main", "cb/deepseek-v4.1-flash")
        self.assertEqual(lad, ["ali/qwen3.8-flash", "cbcn/minimax-m3", "cbcn/deepseek-v4-flash"])

    def test_ire_marks_rung_ineligible(self):
        for m in self.b["top20"]:
            if m["name"] == "Qwen3.8 Flash":
                m["eligible"] = False
        self.assertNotIn("ali/qwen3.8-flash", L.default_ladder(self.b, "main", "cb/deepseek-v4.1-flash"))

    def test_prune(self):
        self.assertEqual(L.prune_for_other_seat(["ali/qwen3.8-flash", "cbcn/deepseek-v4-flash"], ["cbcn"]),
                         (["ali/qwen3.8-flash"], ["cbcn/deepseek-v4-flash"]))


class Picker(unittest.TestCase):
    def setUp(self):
        self.b = ire_bundle()
        os.environ.pop("CCL_OPT_IN_MODELS", None)

    def run_picker(self, answers, **kw):
        it = iter(answers)
        return L.prompt_ladder(self.b, kw.pop("role", "main"), kw.pop("primary", "cb/deepseek-v4.1-flash"),
                               kw.pop("blocked", ()), inp=lambda _: next(it), out=io.StringIO(), **kw)

    def ids(self):
        return [c["id"] for c in L.catalog(self.b) if c["id"] != "cb/deepseek-v4.1-flash"]

    def test_enter_accepts_default(self):
        self.assertEqual(self.run_picker([""]), {"fallbacks": ["ali/qwen3.8-flash", "cbcn/deepseek-v4-flash"],
                                                 "source": "default"})

    def test_zero_means_none(self):
        self.assertEqual(self.run_picker(["0"])["fallbacks"], [])

    def test_pick_in_order(self):
        ids = self.ids()

        def n(r):
            return str(ids.index(r) + 1)

        res = self.run_picker([f"{n('cbcn/minimax-m3')} {n('ali/qwen3.8-flash')}"])
        self.assertEqual(res, {"fallbacks": ["cbcn/minimax-m3", "ali/qwen3.8-flash"], "source": "picked"})

    def test_rejects_bad_then_accepts(self):
        ids = self.ids()

        def n(r):
            return str(ids.index(r) + 1)

        res = self.run_picker([
            "1 2 3 4",                     # too many
            n("ali/glm-5.2"),              # over the price cap
            n("ag/gemini-3.8-flash-high"),  # gated
            n("cbcn/minimax-m3"),          # blocked vendor
            "x",                           # junk
            n("ali/qwen3.8-flash"),
        ], blocked=("cbcn",))
        self.assertEqual(res["fallbacks"], ["ali/qwen3.8-flash"])


class CxOptIn(unittest.TestCase):
    def setUp(self):
        self.b = ire_bundle()

    def tearDown(self):
        for k in ("CCL_OPT_IN_MODELS", "CCL_CX_SOL_MAX_PRICE"):
            os.environ.pop(k, None)

    def test_hidden_until_opted_in(self):
        os.environ.pop("CCL_OPT_IN_MODELS", None)
        self.assertNotIn("cx/gpt-6.1-sol", [c["id"] for c in L.catalog(self.b)])
        self.assertFalse(L.rung_ok(self.b, "cx/gpt-6.1-sol"))

    def test_opted_in_is_pickable_but_never_in_defaults(self):
        os.environ["CCL_OPT_IN_MODELS"] = "cx/gpt-6.1-sol"
        cat = {c["id"]: c for c in L.catalog(self.b)}
        self.assertTrue(cat["cx/gpt-6.1-sol"]["eligible"])
        self.assertTrue(L.rung_ok(self.b, "cx/gpt-6.1-sol"))
        self.assertNotIn("cx/gpt-6.1-sol", L.default_ladder(self.b, "main", "ali/qwen3.8-flash"))

    def test_price_cap_hook(self):
        os.environ["CCL_OPT_IN_MODELS"] = "cx/gpt-6.1-sol"
        os.environ["CCL_CX_SOL_MAX_PRICE"] = "0.05"
        self.assertFalse(L.rung_ok(self.b, "cx/gpt-6.1-sol"))
        os.environ["CCL_CX_SOL_MAX_PRICE"] = "0.10"
        self.assertTrue(L.rung_ok(self.b, "cx/gpt-6.1-sol"))

    def test_cx_goes_through_responses_api(self):
        self.assertEqual(L.litellm_model("cx/gpt-6.1-sol"), "openai/responses/cx/gpt-6.1-sol")
        self.assertEqual(L.litellm_model("cbcn/minimax-m3"), "openai/cbcn/minimax-m3")


class Plan(unittest.TestCase):
    def test_plan_shape(self):
        p = L.build_plan("cb/deepseek-v4.1-flash", ["ali/qwen3.8-flash"], "cbcn/glm-5.3-flash",
                         ["cbcn/minimax-m3"], "https://api.inferhub.dev/v1")
        self.assertEqual(p["fallbacks"]["sonnet"], ["ih/ali/qwen3.8-flash"])
        self.assertEqual(p["fallbacks"]["opus"], ["ih/cbcn/minimax-m3"])
        self.assertEqual({d["model_name"] for d in p["deployments"]}, {"ih/ali/qwen3.8-flash", "ih/cbcn/minimax-m3"})
        self.assertEqual(p["retry_policy"]["InternalServerErrorRetries"], 1)
        self.assertEqual(p["cooldown"]["cooldown_time"], 180.0)
        self.assertNotIn("sk-", json.dumps(p))
        for d in p["deployments"]:
            self.assertEqual(d["litellm_params"]["api_key"], "os.environ/INFERHUB_API_KEY")

    def test_advisor_off_follows_main(self):
        p = L.build_plan("cb/deepseek-v4.1-flash", ["ali/qwen3.8-flash"], None, [], "x")
        self.assertEqual(p["fallbacks"]["opus"], ["ih/ali/qwen3.8-flash"])


class Cli(unittest.TestCase):
    def test_choose_both_seats_keeps_vendors_apart(self):
        import subprocess
        import tempfile
        with tempfile.TemporaryDirectory() as t:
            st = Path(t) / "st.json"
            cli = str(ROOT / "shared" / "ladder" / "ladder_cli.py")
            for role, prim in (("main", "cb/deepseek-v4.1-flash"), ("advisor", "cbcn/glm-5.3-flash")):
                r = subprocess.run([sys.executable, cli, "choose", "--no-ire", "--state", str(st),
                                    "--role", role, "--primary", prim], input="\n", text=True, capture_output=True)
                self.assertEqual(r.returncode, 0, r.stderr)
            s = json.loads(st.read_text())
            self.assertEqual(s["main"]["fallbacks"], ["ali/qwen3.8-flash"])
            self.assertEqual(s["advisor"]["fallbacks"], ["cbcn/minimax-m3"])
            main_v = {L.prefix(s["main"]["primary"])} | {L.prefix(r) for r in s["main"]["fallbacks"]}
            adv_v = {L.prefix(s["advisor"]["primary"])} | {L.prefix(r) for r in s["advisor"]["fallbacks"]}
            self.assertFalse(main_v & adv_v)


if __name__ == "__main__":
    unittest.main()
