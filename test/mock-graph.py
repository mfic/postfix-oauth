#!/usr/bin/env python3
"""Mock Microsoft Graph + Entra token endpoint for the relay tests.

Usage: mock-graph.py <port> <statedir>

Every POST is appended to <statedir>/requests.jsonl as one JSON object
(path, authorization, content-type, body). POSTs to */token get a static
client-credentials token response; for everything else the response status
is read from <statedir>/status (default 202) on each request, so tests can
flip it without restarting the server. Responds 200 to GET /health.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
STATEDIR = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        record = {
            "path": self.path,
            "authorization": self.headers.get("Authorization", ""),
            "content_type": self.headers.get("Content-Type", ""),
            "body": self.rfile.read(length).decode("utf-8", "replace"),
        }
        with open(os.path.join(STATEDIR, "requests.jsonl"), "a") as f:
            f.write(json.dumps(record) + "\n")

        if self.path.rstrip("/").endswith("/token"):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(
                b'{"access_token": "test-token-123", "expires_in": 3600}'
            )
            return

        status = 202
        try:
            with open(os.path.join(STATEDIR, "status")) as f:
                status = int(f.read().strip())
        except (OSError, ValueError):
            pass
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"error":{"code":"Mock"}}' if status >= 400 else b"")

    def log_message(self, *args):
        pass


HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
