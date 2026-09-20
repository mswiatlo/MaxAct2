#!/usr/bin/env python3
"""Phase 1, probe C: find and characterise Health Auto Export's `.hae` files. Throwaway.

The `.hae` container is undocumented and no reference implementation reads it, so this is a
black-box identification: try every plausible container in turn and report what sticks.

    python3 Spikes/hae_file_probe.py            # inspect whatever is there now
    python3 Spikes/hae_file_probe.py --watch    # wait for iCloud to deliver something

Note the folder shown in the Files app as "Auto Export" is the app's own ubiquity container,
~/Library/Mobile Documents/iCloud~com~ifunography~HealthExport/Documents — not iCloud Drive proper.
"""

from __future__ import annotations

import argparse
import gzip
import json
import lzma
import plistlib
import subprocess
import sys
import time
import zlib
from pathlib import Path

CONTAINER = Path.home() / "Library/Mobile Documents/iCloud~com~ifunography~HealthExport/Documents"
FALLBACKS = [
    Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/Auto Export",
]

MAGIC = {
    b"\x1f\x8b": "gzip",
    b"\x78\x01": "zlib (no/low compression)",
    b"\x78\x9c": "zlib (default compression)",
    b"\x78\xda": "zlib (best compression)",
    b"bplist": "binary plist",
    b"PK\x03\x04": "zip",
    b"pbzx": "pbzx (Apple)",
    b"\xfd7zXZ": "xz",
    b"\x04\x22\x4d\x18": "lz4",
    b"AA\x01": "Apple Archive (AAR)",
    b"bvx": "LZFSE/LZVN block",
    b"SQLite": "SQLite database",
}


def identify(blob: bytes) -> str:
    for magic, name in MAGIC.items():
        if blob.startswith(magic):
            return name
    stripped = blob.lstrip()[:1]
    if stripped in (b"{", b"["):
        return "JSON (plain text)"
    if blob.startswith(b"<?xml"):
        return "XML / plist"
    return "unknown"


def try_decode(blob: bytes) -> tuple[str, object] | None:
    """Return (how, decoded) for the first container that works."""
    attempts = [
        ("plain JSON", lambda b: json.loads(b)),
        ("gzip -> JSON", lambda b: json.loads(gzip.decompress(b))),
        ("zlib -> JSON", lambda b: json.loads(zlib.decompress(b))),
        ("raw deflate -> JSON", lambda b: json.loads(zlib.decompress(b, -15))),
        ("lzma -> JSON", lambda b: json.loads(lzma.decompress(b))),
        ("binary plist", lambda b: plistlib.loads(b)),
        ("gzip -> plist", lambda b: plistlib.loads(gzip.decompress(b))),
    ]
    for how, fn in attempts:
        try:
            return how, fn(blob)
        except Exception:  # noqa: BLE001, S112 - probing; failure is the normal case
            continue
    return None


def summarise(value: object, indent: str = "  ", depth: int = 0) -> None:
    if depth > 2:
        return
    if isinstance(value, dict):
        for key, child in list(value.items())[:25]:
            kind = type(child).__name__
            extra = f" [{len(child)}]" if isinstance(child, (list, dict)) else f" = {child!r}"[:70]
            print(f"{indent}{key}: {kind}{extra}")
            if isinstance(child, (dict, list)):
                summarise(child, indent + "  ", depth + 1)
    elif isinstance(value, list) and value:
        print(f"{indent}[0] of {len(value)}:")
        summarise(value[0], indent + "  ", depth + 1)


def find_roots() -> list[Path]:
    return [p for p in [CONTAINER, *FALLBACKS] if p.exists()]


def scan(root: Path) -> list[Path]:
    """Real files plus iCloud placeholders, which are named .<name>.icloud."""
    return sorted(p for p in root.rglob("*") if p.is_file())


def materialise(path: Path) -> Path | None:
    """A dataless placeholder is `.name.hae.icloud`; ask iCloud to fetch the real file."""
    if not path.name.startswith(".") or not path.name.endswith(".icloud"):
        return path
    real = path.with_name(path.name[1:-len(".icloud")])
    print(f"  placeholder, requesting download: {real.name}")
    subprocess.run(["brctl", "download", str(real)], capture_output=True, check=False)
    for _ in range(30):
        if real.exists() and real.stat().st_size > 0:
            return real
        time.sleep(1)
    print("  download did not complete — enable Keep Downloaded on the folder")
    return None


def inspect(path: Path) -> None:
    resolved = materialise(path)
    if resolved is None:
        return
    blob = resolved.read_bytes()
    print(f"\n{'=' * 78}\n{resolved.name}  ({len(blob):,} bytes)\n{'=' * 78}")
    print(f"magic: {blob[:16]!r}")
    print(f"guess: {identify(blob)}")

    result = try_decode(blob)
    if result is None:
        print("VERDICT: opaque — no standard container decoded it.")
        print(f"first 256 bytes:\n{blob[:256]!r}")
        return

    how, decoded = result
    print(f"VERDICT: readable via {how}")
    print("structure:")
    summarise(decoded)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--watch", action="store_true", help="poll until files appear")
    parser.add_argument("--interval", type=int, default=15)
    parser.add_argument("--limit", type=int, default=4, help="how many files to inspect")
    args = parser.parse_args()

    while True:
        roots = find_roots()
        if not roots:
            print(f"container not present: {CONTAINER}")
        else:
            files: list[Path] = []
            for root in roots:
                found = scan(root)
                print(f"{root}: {len(found)} file(s)")
                files.extend(found)
            if files:
                for path in files[: args.limit]:
                    inspect(path)
                print(f"\n{len(files)} file(s) total.")
                return
        if not args.watch:
            print("\nNothing to inspect. In Health Auto Export: enable Sync to Mac, and use its")
            print("manual sync to push a specific date range rather than waiting for the")
            print("background schedule. Re-run with --watch to poll.")
            return
        time.sleep(args.interval)
        print("...")


if __name__ == "__main__":
    main()
