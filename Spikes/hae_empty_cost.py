"""Issue 24: what does an *empty* `get_workouts` window cost?

Measured 2026-10-25: 0.03–0.2 s (the first call ~1 s), against ~2.1 s per workout found. That
is why "Everything" simply walks weekly back to 2000 instead of probing wider windows across gaps.
Rerun it if Health Auto Export changes how it answers.

Needs Health Auto Export's server open and in the foreground on the phone. Read-only.

    python3 Spikes/hae_empty_cost.py --host <phone-ip> [--token <bearer>]

The token defaults to MaxAct's stored one (`syncToken` in its settings). Windows before 2000 are
certainly empty; one recent populated week is timed for comparison.
"""


from __future__ import annotations
import argparse
import os
import subprocess
import time
from datetime import datetime, timedelta, timezone

from hae_mcp_probe import MCPClient

FMT = "%Y-%m-%d %H:%M:%S %z"


def stored_token() -> str | None:
    plist = os.path.expanduser(
        "~/Library/Containers/com.swiatlowski.MaxAct/Data/Library/Preferences/com.swiatlowski.MaxAct.plist")
    result = subprocess.run(["defaults", "read", plist, "syncToken"], capture_output=True, text=True)
    return result.stdout.strip() or None


def timed(client: MCPClient, start: datetime, end: datetime) -> tuple[float, int]:
    arguments = {"start": start.strftime(FMT), "end": end.strftime(FMT),
                 "includeMetadata": True, "includeRoutes": False, "metadataAggregation": "minutes"}
    began = time.monotonic()
    payload, _, _ = client.call_tool("get_workouts", arguments)
    elapsed = time.monotonic() - began
    workouts = payload.get("data", {}).get("workouts", []) if isinstance(payload, dict) else []
    return elapsed, len(workouts)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=9000)
    parser.add_argument("--token")
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args()

    client = MCPClient(args.host, args.port, args.token or stored_token(), 600)
    print("connected:", client.connect().get("serverInfo"))

    empty_end = datetime(1999, 12, 1, tzinfo=timezone.utc)
    now = datetime.now(timezone.utc)
    cases = [
        ("empty week", empty_end - timedelta(days=7), empty_end),
        ("empty month", empty_end - timedelta(days=30), empty_end),
        ("empty year", empty_end - timedelta(days=365), empty_end),
        ("empty decade", empty_end - timedelta(days=3652), empty_end),
        ("recent week", now - timedelta(days=7), now),
    ]
    for label, start, end in cases:
        runs = [timed(client, start, end) for _ in range(args.repeats)]
        times = ", ".join(f"{t:.2f}" for t, _ in runs)
        print(f"{label:13s} {runs[0][1]:3d} workouts  seconds: {times}")


if __name__ == "__main__":
    main()
