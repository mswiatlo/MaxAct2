#!/usr/bin/env python3
"""Phase 1, probe B: capture one real Health Auto Export REST push. Throwaway.

Replaces the vendor's Node + MongoDB + Grafana reference server for our purposes: we only need the
raw bytes the phone sends, which is also the exact fixture our Swift decoder must be tested
against. Parsed database rows would not be.

    python3 Spikes/hae_capture.py [--port 8080]

Then in Health Auto Export: Automations -> new REST API automation ->
    URL     http://<this-mac-ip>:8080/
    Method  POST
    Format  JSON
and include workout routes + metrics. Ctrl-C to stop.
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import hae_analyze  # noqa: E402

CAPTURES = Path(__file__).parent / "captures"


class CaptureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        length = int(self.headers.get("Content-Length") or 0)
        body = b""
        while len(body) < length:  # large bodies arrive in many chunks
            chunk = self.rfile.read(min(65536, length - len(body)))
            if not chunk:
                break
            body += chunk

        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        CAPTURES.mkdir(exist_ok=True)
        raw_path = CAPTURES / f"{stamp}.json"
        raw_path.write_bytes(body)

        print(f"\n--- POST {self.path} from {self.client_address[0]} ---")
        print(f"saved: {raw_path.relative_to(Path.cwd()) if raw_path.is_relative_to(Path.cwd()) else raw_path}")
        for header in ("Content-Type", "automation-name", "automation-id", "session-id"):
            if value := self.headers.get(header):
                print(f"{header}: {value}")

        try:
            hae_analyze.analyze(json.loads(body), label=f"REST push {stamp}", raw_bytes=len(body))
        except json.JSONDecodeError as error:
            print(f"body is not JSON ({error}); first 200 bytes: {body[:200]!r}")

        # HAE retries on failure, so always acknowledge.
        response = json.dumps({"success": True}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, *_args: object) -> None:
        pass  # we print our own, more useful, summary


def local_ip() -> str:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.connect(("10.255.255.255", 1))
        return probe.getsockname()[0]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()

    print(f"Listening on http://{local_ip()}:{args.port}/  (also http://{socket.gethostname()}:{args.port}/)")
    print("Point a Health Auto Export REST automation here, then trigger it. Ctrl-C to stop.")
    try:
        ThreadingHTTPServer(("0.0.0.0", args.port), CaptureHandler).serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
