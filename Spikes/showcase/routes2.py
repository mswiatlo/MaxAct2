"""Showcase routes along OpenStreetMap route relations (ODbL, © OpenStreetMap contributors).

Each route is routed through its waypoints over the ways of named route relations (the Seaside
Greenway, the Grouse Grind, ...), with the general path network allowed only as a heavily
penalised connector. Writes routes.json: {name: [[lat, lon], ...]}.
"""
import json, math, sys, time, urllib.error, urllib.parse, urllib.request
from routes import metres, dijkstra, graph

UA = "MaxAct-sample-data/1.0"
SEASIDE, GRIND, CAUSEWAY, SPIRIT, ADANAC = 1905671, 3177861, 3928567, 1153151, 161175

ROUTES = {
    # name: (mode, relations, waypoints, connector cache)
    "stanley-park-seawall": ("foot", [SEASIDE], [
        (49.2925, -123.1300), (49.3013, -123.1170), (49.3140, -123.1410), (49.3010, -123.1565),
        (49.2870, -123.1430), (49.2925, -123.1300)], "cache-stanley-park-seawall.json"),
    "false-creek": ("foot", [SEASIDE], [
        (49.2733, -123.1140), (49.2732, -123.1022), (49.2700, -123.1060), (49.2705, -123.1132),
        (49.2733, -123.1140)], "cache-false-creek.json"),
    "english-bay-walk": ("foot", [SEASIDE], [
        (49.2868, -123.1428), (49.2945, -123.1505), (49.3010, -123.1565)], "cache-stanley-park-seawall.json"),
    "kits-jericho": ("foot", [SEASIDE], [
        (49.2737, -123.1545), (49.2710, -123.1700), (49.2722, -123.1975)], "cache-kits-jericho.json"),
    "grouse-grind": ("foot", [GRIND], [(49.3712, -123.0990), (49.3800, -123.0817)], "cache-grouse-grind.json"),
    "lions-gate-dundarave": ("bike", [SEASIDE, CAUSEWAY, SPIRIT], [
        (49.2935, -123.1335), (49.3150, -123.1385), (49.3265, -123.1440), (49.3330, -123.1850)], "cache-lions-gate-dundarave.json"),
    "adanac-commute": ("bike", [ADANAC], [
        (49.2775, -123.0697), (49.2777, -123.0900), (49.2810, -123.1150)], "cache-adanac-commute.json"),
}


def relation_ways(relation):
    cache = f"relation-{relation}.json"
    try:
        return json.load(open(cache))
    except FileNotFoundError:
        pass
    query = f"[out:json][timeout:90];relation({relation});way(r);out body geom;"
    request = urllib.request.Request("https://overpass-api.de/api/interpreter",
                                     data=urllib.parse.urlencode({"data": query}).encode(),
                                     headers={"User-Agent": UA, "Accept": "application/json"})
    for attempt in range(6):
        try:
            with urllib.request.urlopen(request, timeout=150) as response:
                ways = json.load(response)["elements"]
                json.dump(ways, open(cache, "w"))
                time.sleep(2)
                return ways
        except urllib.error.HTTPError as error:
            print(f"  Overpass {error.code}; retrying", file=sys.stderr)
            time.sleep(10 * (attempt + 1))
    raise RuntimeError("Overpass kept failing")


def build(name):
    mode, relations, waypoints, connectors = ROUTES[name]
    on_route = [way for r in relations for way in relation_ways(r)]
    for way in on_route:   # every relation way counts as preferred, whatever its name
        way.setdefault("tags", {})["name"] = "ROUTE " + way["tags"].get("name", "")
        way["tags"].setdefault("highway", "path")
    try:
        general = json.load(open(connectors))
    except FileNotFoundError:
        general = []
    nodes, edges, favoured, names = graph(on_route + general, mode, ["ROUTE"])
    snapped = [min((n for n in favoured if n in edges), key=lambda n: metres(nodes[n], p)) for p in waypoints]
    route = []
    for a, b in zip(snapped, snapped[1:]):
        leg = dijkstra(edges, a, b)
        route.extend(leg if not route else leg[1:])
    points = [nodes[n] for n in route]
    length = sum(metres(a, b) for a, b in zip(points, points[1:]))
    off = sum(metres(nodes[a], nodes[b]) for a, b in zip(route, route[1:]) if not names[a].startswith("ROUTE"))
    print(f"{name}: {len(points)} points, {length / 1000:.2f} km, {off / 1000:.2f} km off the relations", file=sys.stderr)
    return points


if __name__ == "__main__":
    names = sys.argv[1:] or list(ROUTES)
    result = json.load(open("routes.json"))
    for name in names:
        result[name] = build(name)
    json.dump(result, open("routes.json", "w"))
