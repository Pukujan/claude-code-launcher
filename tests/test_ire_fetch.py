"""IRE fetch: online, offline with cache, offline without cache.

The "online" cases talk to a local stand-in for the GitHub contents API, so
the tests need no network and no token.
"""
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "shared" / "ire"))
import ire_fetch as F  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures" / "ire"
FILES = {
    F.TOP20_PATH: (FIX / "top20.csv").read_bytes(),
    F.SHORTLIST_PATH: (FIX / "shortlist.csv").read_bytes(),
    F.POLICY_PATH: (FIX / "policy.md").read_bytes(),
}


class FakeGitHub(BaseHTTPRequestHandler):
    files = FILES
    hits = []

    def log_message(self, *a):
        pass

    def do_GET(self):
        FakeGitHub.hits.append((self.path, self.headers.get("Authorization")))
        path = self.path.split("?")[0]
        repo = f"/repos/{F.IRE_REPO}"
        if path.startswith(repo + "/commits/"):
            body, code = b"0123456789abcdef0123456789abcdef01234567", 200
        elif path.startswith(repo + "/contents/"):
            from urllib.parse import unquote
            rel = unquote(path[len(repo + "/contents/"):])
            body = self.files.get(rel)
            code = 200 if body is not None else 404
            body = body or b'{"message":"Not Found"}'
        else:
            body, code = b"{}", 404
        self.send_response(code)
        self.end_headers()
        self.wfile.write(body)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = Path(self.tmp.name) / "cache"
        self.env = mock.patch.dict(os.environ, {
            "CCL_IRE_NO_GH": "1", "CCL_IRE_NO_GIT_CRED": "1",
        }, clear=False)
        self.env.start()
        for k in ("GH_TOKEN", "GITHUB_TOKEN", "CCL_IRE_OFFLINE", "CCL_IRE_ANON"):
            os.environ.pop(k, None)
        FakeGitHub.hits = []

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def serve(self):
        srv = HTTPServer(("127.0.0.1", 0), FakeGitHub)
        t = threading.Thread(target=srv.serve_forever, daemon=True)
        t.start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        os.environ["CCL_IRE_API_BASE"] = f"http://127.0.0.1:{srv.server_port}"
        self.addCleanup(os.environ.pop, "CCL_IRE_API_BASE", None)
        return srv


class Online(Base):
    def test_fetches_with_token_and_caches(self):
        self.serve()
        os.environ["GH_TOKEN"] = "test-token-not-real"
        b = F.get_bundle(cache_dir=self.cache, timeout=5)
        self.assertEqual(b["source"]["kind"], "github")
        self.assertEqual(b["source"]["auth"], "$GH_TOKEN")
        self.assertEqual(len(b["top20"]), 20)
        self.assertEqual(b["top20"][0]["ids"][0], "cb/deepseek-v4.1-flash")
        self.assertFalse(b["top20"][2]["eligible"])  # Gemini 3.8 Flash is gated
        self.assertEqual(b["price_policy"]["max_cost_per_mtok"], 0.10)
        self.assertEqual(len(b["shortlist"]), 9)
        self.assertEqual(b["ladders_from"], "derived")  # IRE has no picks file
        self.assertTrue(F.cache_file(self.cache).is_file())
        self.assertTrue(all(h[1] == "Bearer test-token-not-real" for h in FakeGitHub.hits))
        self.assertNotIn("test-token-not-real", json.dumps(b))  # never stored

    def test_uses_ire_fallback_picks_when_published(self):
        picks = {"main": {"fallbacks": ["cbcn/deepseek-v4-flash"]}, "advisor": {"fallbacks": ["cbcn/minimax-m3"]}}
        with mock.patch.dict(FakeGitHub.files, {F.FALLBACK_PICKS_PATH: json.dumps(picks).encode()}):
            self.serve()
            os.environ["CCL_IRE_ANON"] = "1"
            b = F.get_bundle(cache_dir=self.cache, timeout=5)
        self.assertEqual(b["ladders_from"], "ire")
        self.assertEqual(b["ladders"]["main"]["fallbacks"], ["cbcn/deepseek-v4-flash"])

    def test_price_cap_follows_ire_docs(self):
        with mock.patch.dict(FakeGitHub.files, {F.POLICY_PATH: b"cost below **$0.05 USDC per 1 million tokens** is fine"}):
            self.serve()
            os.environ["CCL_IRE_ANON"] = "1"
            b = F.get_bundle(cache_dir=self.cache, timeout=5)
        self.assertEqual(b["price_policy"]["max_cost_per_mtok"], 0.05)


class OfflineWithCache(Base):
    def test_falls_back_to_last_good_copy(self):
        self.serve()
        os.environ["CCL_IRE_ANON"] = "1"
        first = F.get_bundle(cache_dir=self.cache, timeout=5)
        os.environ["CCL_IRE_API_BASE"] = "http://127.0.0.1:9"  # nothing listens here
        b = F.get_bundle(cache_dir=self.cache, timeout=2)
        self.assertEqual(b["source"]["kind"], "cache")
        self.assertEqual(b["fetched_at"], first["fetched_at"])
        self.assertEqual(len(b["top20"]), 20)
        self.assertTrue(any("GitHub unavailable" in w for w in b["warnings"]))

    def test_offline_flag_skips_network(self):
        self.serve()
        os.environ["CCL_IRE_ANON"] = "1"
        F.get_bundle(cache_dir=self.cache, timeout=5)
        FakeGitHub.hits = []
        b = F.get_bundle(offline=True, cache_dir=self.cache)
        self.assertEqual(b["source"]["kind"], "cache")
        self.assertEqual(FakeGitHub.hits, [])

    def test_corrupt_cache_is_ignored(self):
        self.cache.mkdir(parents=True)
        F.cache_file(self.cache).write_text("{not json", encoding="utf-8")
        b = F.get_bundle(offline=True, cache_dir=self.cache)
        self.assertEqual(b["source"]["kind"], "defaults")


class OfflineNoCache(Base):
    def test_built_in_defaults(self):
        os.environ["CCL_IRE_API_BASE"] = "http://127.0.0.1:9"
        os.environ["CCL_IRE_ANON"] = "1"
        b = F.get_bundle(cache_dir=self.cache, timeout=2)
        self.assertEqual(b["source"]["kind"], "defaults")
        self.assertEqual(b["ladders"]["main"]["primary"], "cb/deepseek-v4.1-flash")
        self.assertEqual(b["ladders"]["main"]["fallbacks"], ["ali/qwen3.8-flash", "cbcn/deepseek-v4-flash"])
        self.assertEqual(b["ladders"]["advisor"]["fallbacks"], ["cbcn/minimax-m3"])
        self.assertEqual(b["retry"], {"retries": 1, "cooldown_seconds": 180})
        self.assertFalse(F.cache_file(self.cache).exists())  # defaults are never cached

    def test_no_auth_degrades_quietly(self):
        os.environ.pop("CCL_IRE_API_BASE", None)
        b = F.get_bundle(cache_dir=self.cache, timeout=2)
        self.assertEqual(b["source"]["kind"], "defaults")
        self.assertTrue(any("no GitHub auth" in w for w in b["warnings"]))


class CLI(Base):
    def test_cli_writes_bundle_file(self):
        out = Path(self.tmp.name) / "b.json"
        rc = F.main(["--offline", "--cache-dir", str(self.cache), "--out", str(out)])
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out.read_text())["schema"], F.SCHEMA)


if __name__ == "__main__":
    unittest.main()
