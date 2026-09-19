#!/usr/bin/env python3
"""Turn a real capture into an anonymised fixture for MaxActCore's decoder tests. Throwaway.

Keeps every key, unit string and value *shape* exactly as the phone sent it — that is the whole
point of the fixture — while removing anything personally identifying:

  - coordinates are translated so the route starts at a fixed fake origin, preserving shape
  - workout ids are replaced with deterministic fake UUIDs
  - timestamps are shifted to a fixed date, preserving intervals and UTC offset
  - long series are truncated to a handful of samples

    python3 Spikes/make_fixture.py <capture.json> <out.json> [--samples 5]
"""

from __future__ import annotations

import argparse
import json
import uuid
from datetime import datetime, timedelta
from typing import Any

HAE_DATE_FORMAT = "%Y-%m-%d %H:%M:%S %z"
FAKE_ORIGIN = (49.2827, -123.1207)  # Vancouver, so reverse geocoding still yields a sane place
FAKE_EPOCH = datetime(2024, 2, 6, 7, 0, 0)
NAMESPACE = uuid.UUID("00000000-0000-0000-0000-00000000ma11"[:36].replace("m", "0").replace("a", "0"))

SERIES_KEYS = [
    "route", "heartRateData", "heartRateRecovery", "stepCount", "stepCadence",
    "activeEnergy", "basalEnergy", "cyclingDistance", "cyclingSpeed", "cyclingPower",
    "cyclingCadence", "walkingAndRunningDistance", "swimDistance", "swimStroke",
]


class Anonymiser:
    def __init__(self, samples: int) -> None:
        self.samples = samples
        self.time_shift: timedelta | None = None
        self.lat_shift: float | None = None
        self.lon_shift: float | None = None

    def date(self, value: Any) -> Any:
        if not isinstance(value, str):
            return value
        try:
            parsed = datetime.strptime(value, HAE_DATE_FORMAT)
        except ValueError:
            return value
        if self.time_shift is None:
            self.time_shift = FAKE_EPOCH.replace(tzinfo=parsed.tzinfo) - parsed
        return (parsed + self.time_shift).strftime(HAE_DATE_FORMAT)

    def point(self, point: dict[str, Any]) -> dict[str, Any]:
        out = dict(point)
        if "latitude" in out and "longitude" in out:
            if self.lat_shift is None:
                self.lat_shift = FAKE_ORIGIN[0] - out["latitude"]
                self.lon_shift = FAKE_ORIGIN[1] - out["longitude"]
            out["latitude"] = round(out["latitude"] + self.lat_shift, 6)
            out["longitude"] = round(out["longitude"] + self.lon_shift, 6)
        for key in ("timestamp", "date"):
            if key in out:
                out[key] = self.date(out[key])
        if isinstance(out.get("source"), str):
            out["source"] = "TestDevice"
        return out

    def workout(self, workout: dict[str, Any], index: int) -> dict[str, Any]:
        out: dict[str, Any] = {}
        for key, value in workout.items():
            if key == "id":
                out[key] = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"maxact-fixture-{index}")).upper()
            elif key in ("start", "end"):
                out[key] = self.date(value)
            elif key in SERIES_KEYS and isinstance(value, list):
                # Keep the head of the series so intervals stay representative.
                out[key] = [self.point(p) if isinstance(p, dict) else p for p in value[: self.samples]]
            elif key == "source" and isinstance(value, dict):
                out[key] = {"name": "TestApp", "identifier": "com.example.testapp"}
            elif key == "source" and isinstance(value, str):
                out[key] = "TestDevice"
            else:
                out[key] = value
        return out


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture")
    parser.add_argument("out")
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--workouts", type=int, default=2)
    args = parser.parse_args()

    payload = json.loads(open(args.capture).read())
    workouts = payload.get("data", {}).get("workouts", [])[: args.workouts]

    anonymiser = Anonymiser(args.samples)
    fixture = {"data": {"workouts": [anonymiser.workout(w, i) for i, w in enumerate(workouts)]}}

    with open(args.out, "w") as handle:
        json.dump(fixture, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print(f"wrote {args.out}: {len(fixture['data']['workouts'])} workouts, "
          f"series truncated to {args.samples} samples")


if __name__ == "__main__":
    main()
