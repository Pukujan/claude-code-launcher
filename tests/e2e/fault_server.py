#!/usr/bin/env python3
"""Deliberately broken upstream for fault-injection tests.

Answers every request with HTTP 503 and counts the hits per path, so a test
can see how many times the proxy tried the broken primary before moving on.
GET /hits returns the counts. Loopback only.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HITS = {}


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        sys.stderr.write("[fault] " + fmt % a + "\n")

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/hits":
            return self._send(200, HITS)
        self._send(404, {"error": "nope"})

    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            model = json.loads(raw or b"{}").get("model", "?")
        except ValueError:
            model = "?"
        HITS[model] = HITS.get(model, 0) + 1
        self._send(503, {"error": {"message": "fault injected: primary is down", "type": "service_unavailable"}})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 4019
    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
