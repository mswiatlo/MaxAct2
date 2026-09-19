#!/usr/bin/env python3
"""Phase 1, probe A: query the Health Auto Export MCP server over HTTP. Throwaway.

Resolves the tool-name contract by trial, because `listTools` is documented as non-functional and
tool names differ between contract versions (v1.1.0 `get_workouts` vs v1.0.0 `workouts`).

    python3 Spikes/hae_mcp_probe.py --host 192.168.1.42 --token <bearer> --days 30

Health Auto Export must be running and in the foreground on the phone: the server stops when the
app is backgrounded.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import hae_analyze  # noqa: E402

CAPTURES = Path(__file__).parent / "captures"
WORKOUT_TOOL_NAMES = ["get_workouts", "workouts"]  # newest contract first


def call(url: str, token: str | None, method: str, params: dict, timeout: float) -> tuple[object, int, float]:
    request_body = json.dumps(
        {"jsonrpc": "2.0", "id": str(int(time.time() * 1000)), "method": method, "params": params}
    ).encode()
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    started = time.monotonic()
    request = urllib.request.Request(url, data=request_body, headers=headers, method="POST")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        raw = response.read()
    elapsed = time.monotonic() - started
    return json.loads(raw), len(raw), elapsed


def unwrap(response: object) -> object:
    """Peel the JSON-RPC and MCP content envelopes to reach the actual payload."""
    if not isinstance(response, dict):
        return response
    if "error" in response:
        raise RuntimeError(f"JSON-RPC error: {response['error']}")
    result = response.get("result", response)
    # MCP tool results are commonly {"content": [{"type": "text", "text": "<json>"}]}
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
    parser.add_argument("--host", required=True, help="the iPhone's LAN IP, from HAE's Server screen")
    parser.add_argument("--port", type=int, default=9000)
    parser.add_argument("--token", help="bearer token from HAE's Server screen (omit for plain TCP-style HTTP)")
    parser.add_argument("--days", type=int, default=30, help="size of the window to request")
    parser.add_argument("--end", help="window end, yyyy-MM-dd (default: today)")
    parser.add_argument("--timeout", type=float, default=300.0)
    parser.add_argument("--no-routes", action="store_true", help="measure the payload without routes")
    args = parser.parse_args()

    url = f"http://{args.host}:{args.port}/mcp"
    end = datetime.strptime(args.end, "%Y-%m-%d") if args.end else datetime.now()
    start = end - timedelta(days=args.days)
    fmt = "%Y-%m-%d %H:%M:%S %z"
    window = {
        "start": start.astimezone().strftime(fmt),
        "end": end.astimezone().strftime(fmt),
    }

    print(f"endpoint: {url}")
    print(f"window:   {window['start']}  ->  {window['end']}  ({args.days} days)")

    # Record what listTools does, since the docs claim it doesn't work.
    try:
        tools, _, _ = call(url, args.token, "listTools", {}, timeout=30)
        print(f"listTools: {json.dumps(tools)[:400]}")
    except Exception as error:  # noqa: BLE001 - this is a probe; any failure is a finding
        print(f"listTools: failed ({type(error).__name__}: {error})")

    arguments = {**window, "includeMetadata": True, "includeRoutes": not args.no_routes}
    for tool in WORKOUT_TOOL_NAMES:
        print(f"\ntrying tool {tool!r} with {json.dumps(arguments)}")
        try:
            response, size, elapsed = call(
                url, args.token, "callTool", {"name": tool, "arguments": arguments}, args.timeout
            )
        except urllib.error.HTTPError as error:
            print(f"  HTTP {error.code}: {error.read()[:300]!r}")
            continue
        except Exception as error:  # noqa: BLE001
            print(f"  {type(error).__name__}: {error}")
            continue

        try:
            payload = unwrap(response)
        except RuntimeError as error:
            print(f"  {error}")
            continue

        CAPTURES.mkdir(exist_ok=True)
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        path = CAPTURES / f"mcp-{tool}-{stamp}.json"
        path.write_text(json.dumps(payload, indent=2))
        print(f"  saved: {path}")

        hae_analyze.analyze(
            payload, label=f"MCP {tool} ({args.days}d window)", raw_bytes=size, elapsed=elapsed
        )
        return

    print("\nNo workout tool name succeeded. Check that HAE is foregrounded and the token is current.")


if __name__ == "__main__":
    main()
