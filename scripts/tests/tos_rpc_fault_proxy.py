#!/usr/bin/env python3
"""Deterministic localhost fault proxy for autonomous iOS RPC UI tests."""

import argparse
import json
import threading
import time
import urllib.error
import urllib.request
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.mode = "normal"
        self.counts = Counter()


def handler(state: State, upstream: str):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, _format, *_args):
            return

        def send_json(self, status, value):
            payload = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            if self.path == "/readyz":
                self.send_json(200, {"ok": True})
                return
            if self.path == "/__stats":
                with state.lock:
                    self.send_json(200, {"mode": state.mode, "counts": dict(state.counts)})
                return
            self.send_error(404)

        def do_POST(self):
            size = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(size)
            if self.path == "/__control":
                value = json.loads(body or b"{}")
                with state.lock:
                    state.mode = value.get("mode", "normal")
                    if value.get("reset_counts", False):
                        state.counts.clear()
                self.send_json(200, {"ok": True})
                return

            try:
                envelope = json.loads(body)
                method = envelope.get("method", "unknown")
            except (ValueError, TypeError):
                method = "malformed-request"
            with state.lock:
                state.counts[method] += 1
                mode = state.mode
                if mode == "fail_next_read" and method not in ("sendBoc", "sendBocReturnHash"):
                    state.mode = "normal"

            if mode == "offline" or mode == "fail_next_read":
                self.send_json(503, {"error": "fault proxy offline"})
                return
            if mode == "malformed":
                payload = b"not-json"
                self.send_response(200)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return

            request = urllib.request.Request(
                upstream + self.path,
                data=body,
                headers={"Content-Type": self.headers.get("Content-Type", "application/json")},
                method="POST",
            )
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    payload = response.read()
                    status = response.status
                    content_type = response.headers.get("Content-Type", "application/json")
            except urllib.error.HTTPError as error:
                payload = error.read()
                status = error.code
                content_type = error.headers.get("Content-Type", "application/json")

            is_broadcast = method in ("sendBoc", "sendBocReturnHash")
            if mode == "drop_broadcast_response" and is_broadcast:
                self.close_connection = True
                return
            if mode == "delay_broadcast_response" and is_broadcast:
                time.sleep(15)

            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="127.0.0.1:18645")
    parser.add_argument("--upstream", default="http://127.0.0.1:18545")
    args = parser.parse_args()
    host, port = args.listen.rsplit(":", 1)
    server = ThreadingHTTPServer((host, int(port)), handler(State(), args.upstream.rstrip("/")))
    server.serve_forever()


if __name__ == "__main__":
    main()
