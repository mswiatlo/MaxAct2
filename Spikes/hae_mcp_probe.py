#!/usr/bin/env python3
"""Phase 1, probe A: query the Health Auto Export MCP server over HTTP. Throwaway.

The help pages describe a simplified `callTool` JSON-RPC shape — that is the *TCP* transport. The
HTTP transport is real MCP Streamable HTTP: you must `initialize`, carry the returned
`Mcp-Session-Id` on every later request, and use the standard `tools/list` / `tools/call` methods.
`tools/list` works fine here, contrary to the docs.

    python3 Spikes/hae_mcp_probe.py --host 10.0.0.158 --token <bearer> --days 7
    python3 Spikes/hae_mcp_probe.py --host ... --token ... --aggregation seconds

Health Auto Export must be foregrounded on the phone: the server stops when it is backgrounded.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import hae_analyze  # noqa: E402

# Captures live OUTSIDE the repository. They are raw exports containing real GPS traces and
# heart rate, and keeping them in the project tree twice caused trouble: Xcode swept them into
# Copy Bundle Resources, and gitignored files referenced by the project dangle on a fresh clone.
CAPTURES = Path(os.environ.get("MAXACT_CAPTURES", Path.home() / ".maxact-spike-captures"))
PROTOCOL_VERSION = "2025-06-18"


class MCPClient:
    def __init__(self, host: str, port: int, token: str | None, timeout: float) -> None:
        self.url = f"http://{host}:{port}/mcp"
        self.token = token
        self.timeout = timeout
        self.session_id: str | None = None

    def _headers(self) -> dict[str, str]:
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        return headers

    def _post(self, message: dict, *, timeout: float | None = None) -> tuple[bytes, dict]:
        request = urllib.request.Request(
            self.url, data=json.dumps(message).encode(), headers=self._headers(), method="POST"
        )
        with urllib.request.urlopen(request, timeout=timeout or self.timeout) as response:
            return response.read(), dict(response.headers)

    def connect(self) -> dict:
        body, headers = self._post(
            {
                "jsonrpc": "2.0",
                "id": "init",
                "method": "initialize",
                "params": {
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": {"name": "maxact-spike", "version": "0.1"},
                },
            },
            timeout=30,
        )
        self.session_id = headers.get("Mcp-Session-Id")
        if not self.session_id:
            raise RuntimeError("server did not return an Mcp-Session-Id")
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"}, timeout=15)
        return json.loads(body).get("result", {})

    def list_tools(self) -> list[dict]:
        body, _ = self._post({"jsonrpc": "2.0", "id": "tools", "method": "tools/list", "params": {}}, timeout=30)
        return json.loads(body).get("result", {}).get("tools", [])

    def call_tool(self, name: str, arguments: dict) -> tuple[object, int, float]:
        started = time.monotonic()
        body, _ = self._post(
            {"jsonrpc": "2.0", "id": name, "method": "tools/call",
             "params": {"name": name, "arguments": arguments}}
        )
        elapsed = time.monotonic() - started
        response = json.loads(body)
        if "error" in response:
            raise RuntimeError(f"JSON-RPC error: {response['error']}")
        return unwrap(response.get("result", response)), len(body), elapsed


def unwrap(result: object) -> object:
    """MCP tool results arrive as {"content": [{"type": "text", "text": "<json>"}]}."""
    if isinstance(result, dict) and isinstance(result.get("content"), list):
        for item in result["content"]:
            if isinstance(item, dict) and item.get("type") == "text":
                try:
                    return json.loads(item["text"])
                except (json.JSONDecodeError, KeyError):
                    return item.get("text")
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=9000)
    parser.add_argument("--token")
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--end", help="window end, yyyy-MM-dd (default: now)")
    parser.add_argument("--aggregation", default="minutes",
                        help="metadataAggregation: controls heart-rate bucket size")
    parser.add_argument("--no-routes", action="store_true")
    parser.add_argument("--no-metadata", action="store_true",
                        help="drop every time-series; the summary-only case")
    parser.add_argument("--timeout", type=float, default=300.0)
    parser.add_argument("--list-tools", action="store_true", help="print the tool schemas and exit")
    args = parser.parse_args()

    client = MCPClient(args.host, args.port, args.token, args.timeout)
    info = client.connect()
    server = info.get("serverInfo", {})
    print(f"connected: {server.get('name')} {server.get('version')} "
          f"(protocol {info.get('protocolVersion')}, session {client.session_id})")

    if args.list_tools:
        for tool in client.list_tools():
            print(f"\n{tool['name']}: {tool.get('description', '')}")
            print(json.dumps(tool.get("inputSchema", {}), indent=2))
        return

    end = datetime.strptime(args.end, "%Y-%m-%d") if args.end else datetime.now()
    start = end - timedelta(days=args.days)
    fmt = "%Y-%m-%d %H:%M:%S %z"
    arguments = {
        "start": start.astimezone().strftime(fmt),
        "end": end.astimezone().strftime(fmt),
        "includeMetadata": not args.no_metadata,
        "includeRoutes": not args.no_routes,
        "metadataAggregation": args.aggregation,
    }
    print(f"get_workouts {json.dumps(arguments)}")

    payload, size, elapsed = client.call_tool("get_workouts", arguments)

    CAPTURES.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    path = CAPTURES / f"mcp-workouts-{args.days}d-{args.aggregation}-{stamp}.json"
    path.write_text(json.dumps(payload, indent=2))
    print(f"saved: {path}")

    hae_analyze.analyze(
        payload,
        label=f"MCP get_workouts — {args.days}d window, aggregation={args.aggregation}, "
              f"routes={not args.no_routes}",
        raw_bytes=size,
        elapsed=elapsed,
    )


if __name__ == "__main__":
    main()
