#!/usr/bin/env python3
"""The part of the Cloudflare API certbot uses. TXT records go to Pebble's DNS server.

mock-cloudflare.py <port> <challtestsrv management URL>

GET /_state shows the tokens seen, and how many records were added and are still there.
"""
import json
import sys
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

ZONE = {"id": "zone1", "name": "example.com", "status": "active"}
records = {}
added = 0
tokens = set()


def challenge_dns(action, name, value=None):
    body = {"host": name.rstrip(".") + "."}
    if value is not None:
        body["value"] = value
    request = urllib.request.Request(
        f"{sys.argv[2]}/{action}", data=json.dumps(body).encode(), method="POST"
    )
    urllib.request.urlopen(request).read()


class Handler(BaseHTTPRequestHandler):
    def reply(self, result, info=False):
        body = {"success": True, "errors": [], "messages": [], "result": result}
        if info:
            body["result_info"] = {"page": 1, "per_page": 100, "count": len(result),
                                   "total_count": len(result), "total_pages": 1}
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def route(self):
        url = urllib.parse.urlparse(self.path)
        tokens.add(self.headers.get("Authorization", ""))
        return url.path.removeprefix("/client/v4"), urllib.parse.parse_qs(url.query)

    def do_GET(self):
        if self.path == "/_state":
            data = json.dumps({"tokens": sorted(tokens), "added": added, "present": len(records)}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        path, query = self.route()
        # the SDK asks for pages until one comes back empty; everything fits on page 1
        if int(query.get("page", ["1"])[0]) > 1:
            self.reply([], info=True)
        elif path == "/zones":
            names = query.get("name", [])
            self.reply([ZONE] if ZONE["name"] in names else [], info=True)
        elif path.endswith("/dns_records"):
            found = [r for r in records.values()
                     if r.get("type") == query.get("type", [r.get("type")])[0]
                     and r.get("name") == query.get("name.exact", [r.get("name")])[0]
                     and r.get("content") == query.get("content.exact", [r.get("content")])[0]]
            self.reply(found, info=True)
        else:
            self.send_error(404)

    def do_POST(self):
        global added
        path, _ = self.route()
        record = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        added += 1
        record["id"] = f"record{added}"
        record["zone_id"] = ZONE["id"]
        records[record["id"]] = record
        challenge_dns("set-txt", record["name"], record["content"])
        self.reply(record)

    def do_DELETE(self):
        path, _ = self.route()
        record_id = path.rsplit("/", 1)[-1]
        record = records.pop(record_id, None)
        if record:
            challenge_dns("clear-txt", record["name"])
        self.reply({"id": record_id})

    def log_message(self, *args):
        pass


HTTPServer(("0.0.0.0", int(sys.argv[1])), Handler).serve_forever()
