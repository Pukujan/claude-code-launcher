"""Fallback ladder rules, picker input handling, and the proxy plan."""
import io
import json
import os
import sys
import tempfile
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
        # cbcn/deepseek-v4-flash is gated in IRE now, so the default replaces that
        # rung with the next eligible route in rank order (cbcn/minimax-m3).
        self.assertEqual(L.default_ladder(self.b, "main", "cb/deepseek-v4.1-flash"),
                         ["ali/qwen3.8-flash", "cbcn/minimax-m3"])
        self.assertEqual(L.default_ladder(self.b, "advisor", "cbcn/glm-5.3-flash"), ["cbcn/minimax-m3"])

    def test_fixed_chains_are_the_builtin_defaults(self):
        self.assertEqual(I.FIXED_LADDERS["main"]["fallbacks"], ["ali/qwen3.8-flash", "cbcn/deepseek-v4-flash"])
        self.assertEqual(I.FIXED_LADDERS["advisor"]["fallbacks"], ["cbcn/minimax-m3"])
        self.assertEqual(I.FIXED_RETRY, {"retries": 3, "cooldown_seconds": 180})

    def test_load_inputs_falls_back_without_ire(self):
        b = I.load_inputs(None, use_ire=False)
        self.assertEqual(b["source"]["kind"], "builtin")
        self.assertEqual(len(b["top20"]), 20)

    def test_load_inputs_uses_an_ire_bundle_when_given(self):
        import tempfile
        top = I.builtin_inputs()["top20"]
        bundle = {"source": "live", "top20": top,
                  "price_policy": {"free_below_per_mtok": 0.1, "unit": "USDC per 1M tokens"},
                  "ladders": {"main": ["cb/deepseek-v4.1-flash", "cbcn/minimax-m3"],
                              "advisor": ["cbcn/glm-5.3-flash"]},
                  "retries": 2, "cooldown_s": 60}
        with tempfile.TemporaryDirectory() as t:
            p = Path(t) / "b.json"
            p.write_text(json.dumps(bundle))
            b = I.load_inputs(p, use_ire=False)
        self.assertEqual(b["source"]["kind"], "ire")
        self.assertEqual(L.default_ladder(b, "main", "cb/deepseek-v4.1-flash"), ["cbcn/minimax-m3"])
        self.assertEqual(b["retry"], {"retries": 2, "cooldown_seconds": 60})

    def test_real_ire_module_output_is_understood(self):
        sys.path.insert(0, str(ROOT / "shared" / "ire"))
        import ire_fetch
        # An empty cache dir keeps this off any machine-local cache: the module
        # then falls through to its built-in defaults, so the result is the same
        # on a dev box (which may hold a live list) and in CI.
        with tempfile.TemporaryDirectory() as t:
            raw = ire_fetch.get_recommendations(offline=True, directory=Path(t))
        b = I.normalize(raw)
        self.assertIsNotNone(b)
        self.assertEqual(b["ladders"]["main"]["primary"], "cb/deepseek-v4.1-flash")
        self.assertEqual(L.default_ladder(b, "main", "cb/deepseek-v4.1-flash"),
                         ["ali/qwen3.8-flash", "cbcn/minimax-m3"])

    def test_bad_ire_bundle_is_ignored(self):
        import tempfile
        with tempfile.TemporaryDirectory() as t:
            p = Path(t) / "b.json"
            p.write_text("{broken")
            self.assertEqual(I.load_inputs(p, use_ire=False)["source"]["kind"], "builtin")

    def test_primary_removed_and_replaced_from_top20(self):
        lad = L.default_ladder(self.b, "main", "ali/qwen3.8-flash")
        self.assertNotIn("ali/qwen3.8-flash", lad)
        self.assertEqual(lad, ["cb/deepseek-v4.1-flash", "cbcn/minimax-m3"])

    def test_blocked_vendor_dropped(self):
        self.assertEqual(L.default_ladder(self.b, "main", "cb/deepseek-v4.1-flash", ["cbcn"]),
                         ["ali/qwen3.8-flash", "cx/gpt-5.6-luna"])

    def test_never_more_than_three_and_only_cheap_eligible(self):
        b = dict(self.b, ladders={"main": {"fallbacks": [
            "ali/glm-5.2", "ag/gemini-3.8-flash-high", "ali/qwen3.8-flash", "cbcn/minimax-m3",
            "cbcn/deepseek-v4-flash", "cbcn/glm-5.3-flash"]}})
        lad = L.default_ladder(b, "main", "cb/deepseek-v4.1-flash")
        self.assertEqual(lad, ["ali/glm-5.2", "ali/qwen3.8-flash", "cbcn/minimax-m3"])

    def test_ire_marks_rung_ineligible(self):
        for m in self.b["top20"]:
            if m["name"] == "Qwen3.8 Flash":
                m["eligible"] = False
        self.assertNotIn("ali/qwen3.8-flash", L.default_ladder(self.b, "main", "cb/deepseek-v4.1-flash"))

    def test_prune(self):
        self.assertEqual(L.prune_for_other_seat(["ali/qwen3.8-flash", "cbcn/deepseek-v4-flash"], ["cbcn"]),
                         (["ali/qwen3.8-flash"], ["cbcn/deepseek-v4-flash"]))

    def test_cap_price_uses_the_output_ask_then_falls_back(self):
        # issue #94: judge the cap on the output ask. An older list with no ask
        # columns leaves price_out None, so the input ask / blend is used instead.
        self.assertEqual(L.cap_price({"price_out": 0.5, "cost_per_mtok": 0.1}), 0.5)
        self.assertEqual(L.cap_price({"price_out": None, "cost_per_mtok": 0.02}), 0.02)
        self.assertEqual(L.cap_price({"cost_per_mtok": 0.03}), 0.03)
        self.assertIsNone(L.cap_price({}))


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
        self.assertEqual(self.run_picker([""]), {"fallbacks": ["ali/qwen3.8-flash", "cbcn/minimax-m3"],
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
            "x",                           # junk
            "99",                          # out of range
            "zz/not-a-route",              # unknown route
            "cx/gpt-6.1-sol",              # opt-in extra, not opted in
            n("ali/qwen3.8-flash"),
        ])
        self.assertEqual(res["fallbacks"], ["ali/qwen3.8-flash"])

    def test_hand_picks_over_cap_or_gated_are_kept_with_a_warning(self):
        # Every Top 20 route's output ask is under the cap now, so lift one over it
        # to exercise the over-cap warning (a hand pick is kept, only warned about).
        b = dict(self.b, top20=[dict(m) for m in self.b["top20"]])
        for m in b["top20"]:
            if m["name"] == "GLM 5.2":
                m["price_out"] = 0.5
        ids = [c["id"] for c in L.catalog(b) if c["id"] != "cb/deepseek-v4.1-flash"]
        out = io.StringIO()
        it = iter([f"{ids.index('ali/glm-5.2') + 1} {ids.index('ag/gemini-3.8-flash-high') + 1}"])
        res = L.prompt_ladder(b, "main", "cb/deepseek-v4.1-flash", (), inp=lambda _: next(it), out=out)
        self.assertEqual(res, {"fallbacks": ["ali/glm-5.2", "ag/gemini-3.8-flash-high"], "source": "picked"})
        self.assertIn("warning: ali/glm-5.2 costs over $0.10 per 1M", out.getvalue())
        self.assertIn("warning: ag/gemini-3.8-flash-high is gated", out.getvalue())

    def test_hand_picks_sharing_a_vendor_are_honored(self):
        ids = self.ids()
        out = io.StringIO()
        it = iter([str(ids.index("cbcn/minimax-m3") + 1)])
        res = L.prompt_ladder(self.b, "main", "cb/deepseek-v4.1-flash", ("cbcn",),
                              inp=lambda _: next(it), out=out)
        self.assertEqual(res, {"fallbacks": ["cbcn/minimax-m3"], "source": "picked"})
        warn = [ln for ln in out.getvalue().splitlines() if "shares vendor" in ln]
        self.assertEqual(len(warn), 1)
        # the default still keeps the vendors apart
        self.assertNotIn("cbcn/deepseek-v4-flash", L.default_ladder(self.b, "main", "cb/deepseek-v4.1-flash", ("cbcn",)))

    def test_frontier_toggle_and_marks(self):
        b = dict(self.b, frontier=FRONTIER)
        out = io.StringIO()
        it = iter(["f", "1 2"])
        res = L.prompt_ladder(b, "main", "cb/deepseek-v4.1-flash", (), inp=lambda _: next(it), out=out)
        self.assertEqual(res["fallbacks"], ["cx/gpt-6.1-sol", "cc/claude-fable-5-1"])
        text = out.getvalue()
        self.assertIn("IRE frontier list", text)
        fable = next(ln for ln in text.splitlines() if "cc/claude-fable-5-1" in ln and "~" in ln)
        sol = next(ln for ln in text.splitlines() if "cx/gpt-6.1-sol" in ln and "~" in ln)
        self.assertIn("OVER $0.10", fable)
        self.assertNotIn("OVER", sol)
        self.assertIn(" 0.016/1M", sol)

    def test_frontier_empty_says_so(self):
        out = io.StringIO()
        it = iter(["f", ""])
        res = L.prompt_ladder(self.b, "main", "cb/deepseek-v4.1-flash", (), inp=lambda _: next(it), out=out)
        self.assertEqual(res["source"], "default")
        self.assertIn("IRE has no frontier list", out.getvalue())

    def test_prompt_primary_from_either_list(self):
        b = dict(self.b, frontier=FRONTIER)
        it = iter(["1"])
        row = L.prompt_primary(b, "main", inp=lambda _: next(it), out=io.StringIO())
        self.assertEqual(row["id"], "cx/gpt-6.1-sol")
        it = iter(["t", "7"])   # 7th Top 20 row after the reorder
        row = L.prompt_primary(b, "main", inp=lambda _: next(it), out=io.StringIO())
        self.assertEqual(row["id"], "cbcn/deepseek-v4-pro")
        it = iter(["o"])
        self.assertEqual(L.prompt_primary(b, "advisor", allow_off=True, inp=lambda _: next(it),
                                          out=io.StringIO())["id"], "")
        it = iter(["q"])
        self.assertIsNone(L.prompt_primary(b, "main", inp=lambda _: next(it), out=io.StringIO()))


FRONTIER = [
    {"rank": 5, "name": "GPT 6.1 Sol", "vendor": "OpenAI", "route": "cx/gpt-6.1-sol", "best_route": True,
     "eligible": True, "health": "healthy", "cost_per_mtok": 0.016, "price_in": 0.016, "price_out": 0.08,
     "preferred_endpoint": "/v1/responses", "system_prompt_handling": "developer_message", "context_window": 272000},
    {"rank": 2, "name": "Claude Fable 5.1", "vendor": "Anthropic", "route": "cc/claude-fable-5-1", "best_route": True,
     "eligible": True, "health": "healthy", "cost_per_mtok": 1.0, "price_in": 1.0, "price_out": 5.0,
     "preferred_endpoint": None, "system_prompt_handling": "upstream_note", "context_window": None},
]


class HandPickedSharedVendors(unittest.TestCase):
    """End to end through ladder_cli choose: hand-picked ladders survive the other seat."""

    def test_cli_keeps_hand_picked_shared_vendor_rungs(self):
        import subprocess
        import tempfile
        cli = ROOT / "shared" / "ladder" / "ladder_cli.py"
        with tempfile.TemporaryDirectory() as t:
            st = Path(t) / "state.json"
            env = dict(os.environ, CCL_IRE_JSON=str(Path(t) / "missing.json"))
            env.pop("CCL_OPT_IN_MODELS", None)

            def choose(role, primary, answer):
                return subprocess.run([sys.executable, str(cli), "choose", "--state", str(st), "--role", role,
                                       "--primary", primary, "--no-ire"], input=answer + "\n",
                                      capture_output=True, text=True, env=env, check=True)

            cat = [c["id"] for c in L.catalog(I.builtin_inputs()) if c["id"] != "cb/deepseek-v4.1-flash"]
            # main hand-picks a cbcn rung; advisor then picks a cbcn primary and a cb rung by hand
            choose("main", "cb/deepseek-v4.1-flash", str(cat.index("cbcn/deepseek-v4-flash") + 1))
            cat_a = [c["id"] for c in L.catalog(I.builtin_inputs()) if c["id"] != "cbcn/glm-5.3-flash"]
            r = choose("advisor", "cbcn/glm-5.3-flash", str(cat_a.index("cb/hy4-preview") + 1))
            state = json.loads(st.read_text())
        self.assertEqual(state["main"]["fallbacks"], ["cbcn/deepseek-v4-flash"])
        self.assertEqual(state["advisor"]["fallbacks"], ["cb/hy4-preview"])
        self.assertIn("shares vendor 'cb/'", r.stderr)


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

    def test_price_cap_hook_applies_when_listed_in_frontier(self):
        b = dict(self.b, frontier=FRONTIER)
        os.environ["CCL_CX_SOL_MAX_PRICE"] = "0.05"
        self.assertFalse(L.rung_ok(b, "cx/gpt-6.1-sol"))
        self.assertTrue(L.validate_picks(b, "x/y", ["cx/gpt-6.1-sol"]))
        os.environ.pop("CCL_CX_SOL_MAX_PRICE")
        self.assertTrue(L.rung_ok(b, "cx/gpt-6.1-sol"))  # listed by IRE: no opt-in needed
        self.assertEqual(L.validate_picks(b, "x/y", ["cx/gpt-6.1-sol"]), [])

    def test_price_cap_hook(self):
        os.environ["CCL_OPT_IN_MODELS"] = "cx/gpt-6.1-sol"
        os.environ["CCL_CX_SOL_MAX_PRICE"] = "0.05"
        self.assertFalse(L.rung_ok(self.b, "cx/gpt-6.1-sol"))
        os.environ["CCL_CX_SOL_MAX_PRICE"] = "0.10"
        self.assertTrue(L.rung_ok(self.b, "cx/gpt-6.1-sol"))

    def test_cx_goes_through_responses_api(self):
        self.assertEqual(L.litellm_model("cx/gpt-6.1-sol"), "openai/responses/cx/gpt-6.1-sol")
        self.assertEqual(L.litellm_model("cbcn/minimax-m3"), "openai/cbcn/minimax-m3")


class FailurePolicySettings(unittest.TestCase):
    def tearDown(self):
        for k in ("CCL_RETRIES", "CCL_COOLDOWN_S"):
            os.environ.pop(k, None)

    def test_defaults_are_3_retries_and_180_s(self):
        for k in ("CCL_RETRIES", "CCL_COOLDOWN_S"):
            os.environ.pop(k, None)
        self.assertEqual(I.retry_settings(), {"retries": 3, "cooldown_seconds": 180})
        self.assertEqual(I.builtin_inputs()["retry"], {"retries": 3, "cooldown_seconds": 180})
        ire = json.loads((ROOT / "shared" / "ire" / "defaults.json").read_text())
        self.assertEqual((ire["retries"], ire["cooldown_s"]), (3, 180))

    def test_env_overrides_win_over_ire_and_defaults(self):
        os.environ["CCL_RETRIES"] = "2"
        os.environ["CCL_COOLDOWN_S"] = "20"
        self.assertEqual(I.retry_settings({"retries": 5, "cooldown_seconds": 600}),
                         {"retries": 2, "cooldown_seconds": 20})
        b = I.normalize({"source": "live", "top20": I.builtin_inputs()["top20"],
                         "price_policy": {"free_below_per_mtok": 0.1},
                         "ladders": {"main": ["cb/deepseek-v4.1-flash"], "advisor": ["cbcn/glm-5.3-flash"]},
                         "retries": 3, "cooldown_s": 180})
        self.assertEqual(b["retry"], {"retries": 2, "cooldown_seconds": 20})

    def test_bad_env_values_are_ignored(self):
        os.environ["CCL_RETRIES"] = "lots"
        os.environ["CCL_COOLDOWN_S"] = "0"
        self.assertEqual(I.retry_settings(), {"retries": 3, "cooldown_seconds": 180})

    def test_apply_reads_env_at_apply_time(self):
        import subprocess
        import tempfile
        cli = ROOT / "shared" / "ladder" / "ladder_cli.py"
        with tempfile.TemporaryDirectory() as t:
            st = Path(t) / "state.json"
            env = {k: v for k, v in os.environ.items() if k not in ("CCL_RETRIES", "CCL_COOLDOWN_S")}
            subprocess.run([sys.executable, str(cli), "choose", "--state", str(st), "--role", "main",
                            "--primary", "cb/deepseek-v4.1-flash", "--no-ire", "--non-interactive"],
                           env=env, check=True, capture_output=True)
            env.update(CCL_RETRIES="1", CCL_COOLDOWN_S="20")
            subprocess.run([sys.executable, str(cli), "apply", "--state", str(st),
                            "--base-url", "http://127.0.0.1:9"], env=env, capture_output=True)
            plan = json.loads((Path(t) / "ladder-plan.json").read_text())
        self.assertEqual(plan["retry_policy"]["ServiceUnavailableErrorRetries"], 1)
        self.assertEqual(plan["cooldown"]["cooldown_time"], 20.0)
        self.assertEqual(plan["cooldown"]["allowed_fails_policy"]["ServiceUnavailableErrorAllowedFails"], 1)

    def test_picker_says_it_plainly(self):
        out = io.StringIO()
        L.prompt_ladder(I.builtin_inputs(), "main", "cb/deepseek-v4.1-flash", (), inp=lambda _: "", out=out)
        self.assertIn("each model gets 3 retries, then the next rung; a model that fails is benched for 180 s",
                      out.getvalue())


class Plan(unittest.TestCase):
    def test_plan_shape(self):
        p = L.build_plan("cb/deepseek-v4.1-flash", ["ali/qwen3.8-flash"], "cbcn/glm-5.3-flash",
                         ["cbcn/minimax-m3"], "https://api.inferhub.dev/v1")
        self.assertEqual(p["fallbacks"]["sonnet"], ["ih/ali/qwen3.8-flash"])
        self.assertEqual(p["fallbacks"]["opus"], ["ih/cbcn/minimax-m3"])
        self.assertEqual({d["model_name"] for d in p["deployments"]}, {"ih/ali/qwen3.8-flash", "ih/cbcn/minimax-m3"})
        self.assertEqual(p["retry_policy"]["InternalServerErrorRetries"], 3)
        self.assertEqual(p["retry_policy"]["ServiceUnavailableErrorRetries"], 3)
        self.assertEqual(p["retry_policy"]["TimeoutErrorRetries"], 0)
        self.assertEqual(p["cooldown"]["cooldown_time"], 180.0)
        # benched by the failure that uses up the last retry
        self.assertEqual(p["cooldown"]["allowed_fails_policy"]["ServiceUnavailableErrorAllowedFails"], 3)
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

    def test_choose_picks_flag_records_hand_picks(self):
        import subprocess
        import tempfile
        with tempfile.TemporaryDirectory() as t:
            st = Path(t) / "st.json"
            cli = str(ROOT / "shared" / "ladder" / "ladder_cli.py")
            base = [sys.executable, cli, "choose", "--no-ire", "--state", str(st), "--role", "main",
                    "--primary", "cb/deepseek-v4.1-flash"]
            r = subprocess.run(base + ["--picks", "cbcn/glm-5.3-flash,ali/qwen3.8-flash"],
                               text=True, capture_output=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            s = json.loads(st.read_text())
            self.assertEqual(s["main"]["fallbacks"], ["cbcn/glm-5.3-flash", "ali/qwen3.8-flash"])
            self.assertEqual(s["main"]["source"], "picked")
            r = subprocess.run(base + ["--picks", "cb/deepseek-v4.1-flash"], text=True, capture_output=True)
            self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
