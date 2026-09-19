"""Shared analysis for Phase 1 sync-path probes. Throwaway — deleted when Phase 1 concludes.

Answers the questions PLAN.md Phase 1 asks of every candidate sync path:
  - does a workout carry a route, and a heart-rate series?
  - at what sample interval, i.e. how much fidelity would an exported TCX actually have?
  - how big is the payload, and how long did it take?
"""

from __future__ import annotations

import json
import statistics
from datetime import datetime
from typing import Any

HAE_DATE_FORMAT = "%Y-%m-%d %H:%M:%S %z"

# Fields we expect to care about later, so we can see at a glance what a real payload omits.
INTERESTING_FIELDS = [
    "distance", "activeEnergyBurned", "activeEnergy", "totalEnergy", "intensity",
    "heartRateData", "heartRateRecovery", "stepCount", "stepCadence", "speed",
    "avgSpeed", "maxSpeed", "elevationUp", "elevationDown", "temperature",
    "humidity", "location", "isIndoor", "route", "metadata",
]


def parse_date(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        return datetime.strptime(value, HAE_DATE_FORMAT)
    except ValueError:
        try:  # some transports may hand back ISO-8601 instead
            return datetime.fromisoformat(value)
        except ValueError:
            return None


def interval_stats(timestamps: list[datetime]) -> str:
    """Median/min/max gap between consecutive samples, in seconds."""
    stamps = sorted(t for t in timestamps if t is not None)
    if len(stamps) < 2:
        return "n/a (fewer than 2 samples)"
    deltas = [
        (b - a).total_seconds()
        for a, b in zip(stamps, stamps[1:])
        if (b - a).total_seconds() > 0
    ]
    if not deltas:
        return "n/a (all samples share one timestamp)"
    return (
        f"median {statistics.median(deltas):.1f}s  "
        f"min {min(deltas):.1f}s  max {max(deltas):.1f}s  n={len(deltas) + 1}"
    )


def describe_workout(workout: dict[str, Any], index: int) -> None:
    name = workout.get("name", "?")
    duration = workout.get("duration")
    duration_text = f"{duration / 60:.0f} min" if isinstance(duration, (int, float)) else "?"
    print(f"\n  [{index}] {name} — {workout.get('start', '?')} — {duration_text}")
    print(f"      id: {workout.get('id', '<MISSING>')}")

    route = workout.get("route") or []
    if route:
        stamps = [parse_date(p.get("timestamp")) for p in route]
        print(f"      route: {len(route)} points, interval {interval_stats(stamps)}")
        keys = sorted({k for p in route for k in p})
        print(f"      route point keys: {', '.join(keys)}")
    else:
        print("      route: ABSENT")

    for series_name in ("heartRateData", "heartRateRecovery"):
        series = workout.get(series_name) or []
        if series:
            stamps = [parse_date(s.get("date")) for s in series]
            print(f"      {series_name}: {len(series)} samples, interval {interval_stats(stamps)}")
            print(f"      {series_name} keys: {', '.join(sorted(series[0].keys()))}")
        else:
            print(f"      {series_name}: ABSENT")

    present = [f for f in INTERESTING_FIELDS if f in workout]
    missing = [f for f in INTERESTING_FIELDS if f not in workout]
    print(f"      present: {', '.join(present) or '(none)'}")
    print(f"      absent:  {', '.join(missing) or '(none)'}")

    unexpected = sorted(set(workout) - set(INTERESTING_FIELDS) - {"id", "name", "start", "end", "duration"})
    if unexpected:
        print(f"      UNDOCUMENTED KEYS: {', '.join(unexpected)}")


def analyze(payload: Any, *, label: str, raw_bytes: int, elapsed: float | None = None) -> None:
    print(f"\n{'=' * 78}\n{label}\n{'=' * 78}")
    print(f"payload: {raw_bytes:,} bytes ({raw_bytes / 1_048_576:.2f} MiB)")
    if elapsed is not None:
        print(f"elapsed: {elapsed:.2f}s")

    # Tolerate both the documented envelope and a bare list, since the MCP tool's
    # response shape is not documented.
    workouts: list[dict[str, Any]] = []
    if isinstance(payload, dict):
        data = payload.get("data", payload)
        if isinstance(data, dict):
            workouts = data.get("workouts") or []
            metrics = data.get("metrics") or []
            print(f"envelope keys: {', '.join(sorted(payload.keys()))}")
            print(f"workouts: {len(workouts)}   metrics: {len(metrics)}")
    elif isinstance(payload, list):
        workouts = [w for w in payload if isinstance(w, dict)]
        print(f"bare list of {len(workouts)} items (no envelope)")

    if not workouts:
        print("\nNo workouts in this payload.")
        print("Note: HAE cannot read health data while the phone is locked, and a denied")
        print("permission is indistinguishable from no data. Check Health -> Sharing -> Apps.")
        return

    with_route = sum(1 for w in workouts if w.get("route"))
    with_hr = sum(1 for w in workouts if w.get("heartRateData"))
    print(f"with route: {with_route}/{len(workouts)}   with heartRateData: {with_hr}/{len(workouts)}")

    # Detail the few most interesting: longest, and the first with a route.
    by_duration = sorted(workouts, key=lambda w: w.get("duration") or 0, reverse=True)
    shown: list[int] = []
    for w in by_duration[:3]:
        idx = workouts.index(w)
        shown.append(idx)
        describe_workout(w, idx)
    for i, w in enumerate(workouts):
        if w.get("route") and i not in shown:
            describe_workout(w, i)
            break
