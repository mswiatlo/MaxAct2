"""Thins routes.json, adds elevations from Open-Meteo (Copernicus DEM), and prints Swift.

Each route becomes one string: Google's encoded-polyline scheme over three values per point —
latitude and longitude at 1e-5 degrees, elevation at 0.1 m — so it decodes with a few lines.
"""
import json, math, sys, time, urllib.request

UA = "MaxAct-sample-data/1.0"


def metres(a, b):
    lat = math.radians((a[0] + b[0]) / 2)
    return math.hypot((a[0] - b[0]) * 111_320, (a[1] - b[1]) * 111_320 * math.cos(lat))


def offset(p, a, b):
    """Distance from p to segment ab, in metres (flat approximation)."""
    lat = math.radians(a[0])
    to_xy = lambda q: ((q[1] - a[1]) * 111_320 * math.cos(lat), (q[0] - a[0]) * 111_320)
    px, py = to_xy(p); bx, by = to_xy(b)
    length = bx * bx + by * by
    t = 0 if length == 0 else max(0, min(1, (px * bx + py * by) / length))
    return math.hypot(px - t * bx, py - t * by)


def simplify(points, tolerance=2.0):
    if len(points) < 3:
        return points
    worst, index = 0, 0
    for i in range(1, len(points) - 1):
        d = offset(points[i], points[0], points[-1])
        if d > worst:
            worst, index = d, i
    if worst <= tolerance:
        return [points[0], points[-1]]
    return simplify(points[:index + 1], tolerance)[:-1] + simplify(points[index:], tolerance)


def elevations(points):
    result = []
    for start in range(0, len(points), 100):
        chunk = points[start:start + 100]
        url = ("https://api.open-meteo.com/v1/elevation?latitude=" + ",".join(f"{p[0]:.5f}" for p in chunk)
               + "&longitude=" + ",".join(f"{p[1]:.5f}" for p in chunk))
        request = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(request, timeout=60) as response:
            result += json.load(response)["elevation"]
        time.sleep(0.5)
    return result


def encode(values):
    out = []
    for value in values:
        value = ~(value << 1) if value < 0 else value << 1
        while value >= 0x20:
            out.append(chr((0x20 | (value & 0x1F)) + 63))
            value >>= 5
        out.append(chr(value + 63))
    return "".join(out)


def encode_route(points, heights):
    previous, chunks = (0, 0, 0), []
    for (lat, lon), height in zip(points, heights):
        current = (round(lat * 1e5), round(lon * 1e5), round(height * 10))
        chunks.append(encode([c - p for c, p in zip(current, previous)]))
        previous = current
    return "".join(chunks)


routes = json.load(open("routes.json"))
lines = []
for name in sorted(routes):
    points = [tuple(p) for p in routes[name]]
    # Drop consecutive duplicates, then thin.
    points = [p for i, p in enumerate(points) if i == 0 or metres(p, points[i - 1]) > 0.5]
    thin = simplify(points)
    heights = elevations(thin)
    length = sum(metres(a, b) for a, b in zip(thin, thin[1:]))
    print(f"{name}: {len(points)} -> {len(thin)} points, {length / 1000:.2f} km, "
          f"elevation {min(heights):.0f}-{max(heights):.0f} m", file=sys.stderr)
    lines.append(f'        "{name}": #"{encode_route(thin, heights)}"#,')
open("fixture.swift.txt", "w").write("\n".join(lines) + "\n")
