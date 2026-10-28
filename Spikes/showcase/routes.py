"""Builds the showcase routes from OpenStreetMap (ODbL, © OpenStreetMap contributors).

For each route: fetch the path network in a box around its waypoints from Overpass, then run
Dijkstra through the waypoints, preferring paths named in `prefer` and penalising roads.
Writes routes.json: {name: [[lat, lon], ...]}.
"""
import heapq, json, math, sys, time, urllib.error, urllib.request, urllib.parse

UA = "MaxAct-sample-data/1.0"

ROUTES = {
    # name: (mode, waypoints, preferred-name fragments)
    "stanley-park-seawall": ("foot", [
        (49.2935, -123.1335), (49.3000, -123.1240), (49.3013, -123.1170), (49.3105, -123.1310),
        (49.3135, -123.1420), (49.3045, -123.1560), (49.2960, -123.1515), (49.2885, -123.1440),
        (49.2935, -123.1335)],
        ["Stanley Park Seawall", "Seawall"]),
    "false-creek": ("foot", [
        (49.2733, -123.1140), (49.2732, -123.1022), (49.2700, -123.1060), (49.2705, -123.1132),
        (49.2733, -123.1140)],
        ["Seawall", "Seaside", "Cambie"]),
    "kits-jericho": ("foot", [
        (49.2737, -123.1545), (49.2710, -123.1700), (49.2722, -123.1975)],
        ["Seaside", "Point Grey", "Seawall"]),
    "english-bay-walk": ("foot", [
        (49.2868, -123.1428), (49.2945, -123.1505), (49.3010, -123.1565)],
        ["Stanley Park Seawall", "Seawall"]),
    "queen-elizabeth-park": ("foot", [
        (49.2437, -123.1170), (49.2428, -123.1140), (49.2418, -123.1125), (49.2405, -123.1095),
        (49.2392, -123.1120), (49.2405, -123.1150), (49.2437, -123.1170)],
        []),
    "grouse-grind": ("foot", [(49.3712, -123.0990), (49.3800, -123.0817)], ["Grouse Grind"]),
    "lions-gate-dundarave": ("bike", [
        (49.2925, -123.1300), (49.3150, -123.1385), (49.3265, -123.1440), (49.3330, -123.1850)],
        ["Seawall", "Spirit Trail", "Lions Gate", "Centennial Seawalk"]),
    "adanac-commute": ("bike", [
        (49.2775, -123.0697), (49.2777, -123.0900), (49.2810, -123.1150), (49.2840, -123.1200)],
        ["Adanac", "Union", "Dunsmuir"]),
}

PATHS = {"footway", "cycleway", "path", "pedestrian", "steps", "track", "bridleway", "living_street"}
QUIET = {"residential", "service", "unclassified"}
ROADS = {"tertiary", "secondary", "primary", "trunk", "tertiary_link", "secondary_link", "primary_link"}


def overpass(bbox):
    s, w, n, e = bbox
    query = f"""[out:json][timeout:60];
way["highway"]({s},{w},{n},{e});
out body geom;"""
    request = urllib.request.Request("https://overpass-api.de/api/interpreter",
                                     data=urllib.parse.urlencode({"data": query}).encode(),
                                     headers={"User-Agent": UA, "Accept": "application/json"})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return json.load(response)["elements"]
        except urllib.error.HTTPError as error:
            print(f"  Overpass {error.code}; retrying in {10 * (attempt + 1)} s", file=sys.stderr)
            time.sleep(10 * (attempt + 1))
    raise RuntimeError("Overpass kept failing")


def metres(a, b):
    lat = math.radians((a[0] + b[0]) / 2)
    return math.hypot((a[0] - b[0]) * 111_320, (a[1] - b[1]) * 111_320 * math.cos(lat))


def graph(ways, mode, prefer):
    nodes, edges, favoured, names = {}, {}, set(), {}
    for way in ways:
        tags = way.get("tags", {})
        kind = tags.get("highway")
        if kind not in PATHS | QUIET | ROADS:
            continue
        if mode == "foot" and tags.get("foot") == "no":
            continue
        if mode == "bike" and (tags.get("bicycle") == "no" or kind in {"steps"}):
            continue
        name = tags.get("name", "")
        preferred = any(p.lower() in name.lower() for p in prefer)
        if preferred:
            factor = 1.0
        elif kind in PATHS:
            factor = 6.0
        elif kind in QUIET:
            factor = 8.0
        else:
            factor = 15.0
        if mode == "bike" and tags.get("bicycle") in {"designated"}:
            factor *= 0.8
        ids, geometry = way["nodes"], way["geometry"]
        for node, point in zip(ids, geometry):
            nodes[node] = (point["lat"], point["lon"])
            if preferred:
                favoured.add(node)
            names.setdefault(node, name or kind)
        for a, b in zip(ids, ids[1:]):
            cost = metres(nodes[a], nodes[b]) * factor
            edges.setdefault(a, []).append((b, cost))
            edges.setdefault(b, []).append((a, cost))
    return nodes, edges, favoured, names


def nearest(nodes, edges, point, favoured):
    pool = [n for n in (favoured or nodes) if n in edges]
    return min(pool, key=lambda n: metres(nodes[n], point))


def dijkstra(edges, start, goal):
    best, previous, queue = {start: 0}, {}, [(0, start)]
    while queue:
        cost, node = heapq.heappop(queue)
        if node == goal:
            break
        if cost > best[node]:
            continue
        for neighbour, step in edges.get(node, []):
            new = cost + step
            if new < best.get(neighbour, math.inf):
                best[neighbour], previous[neighbour] = new, node
                heapq.heappush(queue, (new, neighbour))
    path, node = [goal], goal
    while node != start:
        node = previous[node]
        path.append(node)
    return path[::-1]


def build(name):
    mode, waypoints, prefer = ROUTES[name]
    lats, lons = [p[0] for p in waypoints], [p[1] for p in waypoints]
    bbox = (min(lats) - 0.006, min(lons) - 0.009, max(lats) + 0.006, max(lons) + 0.009)
    cache = f"cache-{name}.json"
    try:
        ways = json.load(open(cache))
    except FileNotFoundError:
        ways = overpass(bbox)
        json.dump(ways, open(cache, "w"))
    nodes, edges, favoured, names = graph(ways, mode, prefer)
    snapped = [nearest(nodes, edges, p, favoured) for p in waypoints]
    route = []
    for a, b in zip(snapped, snapped[1:]):
        leg = dijkstra(edges, a, b)
        route.extend(leg if not route else leg[1:])
    points = [nodes[n] for n in route]
    length = sum(metres(a, b) for a, b in zip(points, points[1:]))
    print(f"{name}: {len(points)} points, {length / 1000:.2f} km", file=sys.stderr)
    used = []
    for n in route:
        if not used or used[-1] != names[n]:
            used.append(names[n])
    print("  via: " + " > ".join(used), file=sys.stderr)
    return points


if __name__ == "__main__":
    names = sys.argv[1:] or list(ROUTES)
    try:
        result = json.load(open("routes.json"))
    except FileNotFoundError:
        result = {}
    for name in names:
        result[name] = build(name)
        time.sleep(2)   # be gentle with the public Overpass server
    json.dump(result, open("routes.json", "w"))
