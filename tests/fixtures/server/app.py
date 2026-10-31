"""The inventory API that tests/fixtures/api/openapi.yaml describes, for the
contract_test command's integration tests. Standard library only.

    python3 tests/fixtures/server/app.py [PORT]

With BUG=1 in the environment, GET /items returns each price as a string,
which the document doesn't allow, so Schemathesis's
response_schema_conformance check fails.
"""

import json
import math
import os
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BUG = os.environ.get("BUG") == "1"
ITEMS = {1: {"id": 1, "name": "widget", "price": 2.5}}
LOCK = threading.Lock()
ITEM_PATH = re.compile(r"^/items/([^/]+)$")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def error(self, status, message, allow=None):
        data = json.dumps({"error": message}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if allow:
            self.send_header("Allow", allow)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def path_only(self):
        return self.path.split("?", 1)[0]

    def item_id(self):
        match = ITEM_PATH.match(self.path_only())
        if not match:
            return None, None
        raw = match.group(1)
        if not re.fullmatch(r"[1-9][0-9]*", raw):
            return False, raw
        return int(raw), raw

    def do_GET(self):
        path = self.path_only()
        if path == "/items":
            with LOCK:
                items = [dict(item) for item in ITEMS.values()]
            if BUG:
                for item in items:
                    item["price"] = "%.2f" % item["price"]
            return self.send_json(200, items)
        item_id, raw = self.item_id()
        if item_id is None:
            return self.error(404, "no such path")
        if item_id is False:
            return self.error(400, "the identifier must be a positive integer, not %r" % raw)
        with LOCK:
            item = ITEMS.get(item_id)
        if item is None:
            return self.error(404, "no item %d" % item_id)
        return self.send_json(200, item)

    def do_POST(self):
        if self.path_only() != "/items":
            if ITEM_PATH.match(self.path_only()):
                return self.error(405, "method not allowed", allow="GET, DELETE")
            return self.error(404, "no such path")
        try:
            data = json.loads(self.body() or b"null")
        except (ValueError, UnicodeDecodeError):
            return self.error(400, "the body must be JSON")
        if not isinstance(data, dict) or set(data) != {"name", "price"}:
            return self.error(400, "the body must have name and price, and nothing else")
        name, price = data["name"], data["price"]
        if not isinstance(name, str) or not 1 <= len(name) <= 100:
            return self.error(400, "name must be 1 to 100 characters")
        if isinstance(price, bool) or not isinstance(price, (int, float)) or not math.isfinite(price) or price < 0:
            return self.error(400, "price must be a number of at least 0")
        with LOCK:
            item_id = max(ITEMS, default=0) + 1
            ITEMS[item_id] = {"id": item_id, "name": name, "price": price}
            item = dict(ITEMS[item_id])
        return self.send_json(201, item)

    def do_DELETE(self):
        item_id, raw = self.item_id()
        if item_id is None:
            if self.path_only() == "/items":
                return self.error(405, "method not allowed", allow="GET, POST")
            return self.error(404, "no such path")
        if item_id is False:
            return self.error(400, "the identifier must be a positive integer, not %r" % raw)
        with LOCK:
            found = ITEMS.pop(item_id, None)
        if found is None:
            return self.error(404, "no item %d" % item_id)
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    # Every other method, including TRACE, which Schemathesis sends to check
    # that undocumented methods are refused: http.server would answer 501.
    def not_allowed(self):
        if self.path_only() == "/items":
            return self.error(405, "method not allowed", allow="GET, POST")
        if ITEM_PATH.match(self.path_only()):
            return self.error(405, "method not allowed", allow="GET, DELETE")
        return self.error(404, "no such path")

    do_PUT = do_PATCH = do_HEAD = do_OPTIONS = do_TRACE = do_CONNECT = not_allowed


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
