#!/usr/bin/env python3
"""Collects a test build's log (ios/Voxl/TestLog.swift): each POST is a batch of events, appended as one JSON line
per event to ~/.cache/voxl-ios/testlog/<session>.jsonl. Listens on 127.0.0.1 only:

  ios/testlog.py [PORT]     default 6919

For a phone, put it on the tailnet for the test only, then take it off again:
  tailscale serve --bg --https=6909 http://127.0.0.1:6919
  tailscale serve --https=6909 off
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

OUT = Path.home() / ".cache/voxl-ios/testlog"


class Collect(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            session = re.sub(r"[^A-Za-z0-9-]", "", str(body.get("session", "none")))[:16] or "none"
            OUT.mkdir(parents=True, exist_ok=True)
            with open(OUT / f"{session}.jsonl", "a") as f:
                for e in body.get("events", []):
                    f.write(json.dumps(e, ensure_ascii=False) + "\n")
            self.send_response(200)
        except Exception:
            self.send_response(400)
        self.end_headers()

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 6919), Collect).serve_forever()
