#!/usr/bin/env python3
"""Generates the offline demo road network (Bengaluru - Hosur - Krishnagiri corridor, NH 44).

The geometry is approximate and synthetic (straight chords with gentle bends), meant for the demo
and tests. For real roads use tools/osm_to_graph.py.
"""
import json
import math
import sys

nodes = []   # [lat, lon]
edges = []   # dicts


def add_node(lat, lon):
    nodes.append([round(lat, 6), round(lon, 6)])
    return len(nodes) - 1


def haversine(a, b):
    r = 6371000.0
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.atan2(math.sqrt(h), math.sqrt(1 - h))


def chain(waypoints, name, speed, step_m=900, bend_m=60.0, **props):
    """Adds nodes between waypoints (each waypoint is an existing node id) and edges along them.
    Returns the list of node ids (including the waypoint ids) in order."""
    ids = [waypoints[0]]
    for a, b in zip(waypoints, waypoints[1:]):
        pa, pb = nodes[a], nodes[b]
        n = max(1, round(haversine(pa, pb) / step_m))
        dlat, dlon = pb[0] - pa[0], pb[1] - pa[1]
        norm = math.hypot(dlat, dlon * math.cos(math.radians(pa[0]))) or 1.0
        # perpendicular unit vector in degrees
        plat, plon = -dlon * math.cos(math.radians(pa[0])) / norm, dlat / norm / math.cos(math.radians(pa[0]))
        prev = a
        for i in range(1, n):
            t = i / n
            bend = math.sin(math.pi * t) * bend_m * math.sin(a * 0.7 + i)
            lat = pa[0] + dlat * t + plat * bend / 110574.0
            lon = pb[1] * t + pa[1] * (1 - t) + plon * bend / (111320.0 * math.cos(math.radians(pa[0])))
            cur = add_node(lat, lon)
            edges.append(dict(a=prev, b=cur, name=name, speed_kph=speed, **props))
            ids.append(cur)
            prev = cur
        edges.append(dict(a=prev, b=b, name=name, speed_kph=speed, **props))
        ids.append(b)
    return ids


# Corridor anchors.
silk = add_node(12.9177, 77.6238)      # Silk Board
ecity = add_node(12.8456, 77.6603)     # Electronic City
attibele = add_node(12.7790, 77.7700)  # Attibele
hosur = add_node(12.7409, 77.8253)     # Hosur
shool = add_node(12.6598, 77.9930)     # Shoolagiri
krish = add_node(12.5186, 78.2137)     # Krishnagiri
anekal = add_node(12.7100, 77.6950)    # Anekal
chandapura = add_node(12.8000, 77.7000)

chain([silk, ecity], "Hosur Road Elevated Expressway", 80, two_wheeler=False)
chain([ecity, attibele], "NH 44", 80, toll=False)
nh44_low = chain([attibele, hosur], "NH 44", 70, max_height_m=3.6)       # low underpass section
chain([hosur, shool], "NH 44", 80)
toll_chain = chain([shool, krish], "NH 44", 90, toll=False)
# Toll plaza on the first edge after Shoolagiri.
for e in edges:
    if e["a"] == toll_chain[0] and e["b"] == toll_chain[1]:
        e["toll"] = True

# Tall-vehicle bypass via Chandapura - Anekal - Hosur (state road), 12 t weight limit on one part.
bypass1 = chain([ecity, chandapura], "Chandapura Main Road", 50)
chain([chandapura, anekal], "Anekal Road", 50)
bypass2 = chain([anekal, hosur], "Anekal-Hosur Road", 55, max_weight_t=40, truck=True)
for e in edges:
    if e["name"] == "Anekal Road":
        e["max_weight_t"] = 18.0

# City grid next to Silk Board (3 x 3, ~450 m blocks) for urban map matching.
grid = {}
for i in range(3):
    for j in range(3):
        grid[(i, j)] = add_node(12.9177 + 0.004 * (i - 1) + 0.0004 * j, 77.6238 + 0.004 * (j + 1))
for i in range(3):
    for j in range(3):
        if j + 1 < 3:
            edges.append(dict(a=grid[(i, j)], b=grid[(i, j + 1)], name=f"{i + 1}th Cross Road", speed_kph=30))
        if i + 1 < 3:
            edges.append(dict(a=grid[(i, j)], b=grid[(i + 1, j)], name=f"{j + 1}th Main Road", speed_kph=30,
                              truck=(j != 1), oneway=(j == 2)))
edges.append(dict(a=silk, b=grid[(1, 0)], name="Silk Board Junction Road", speed_kph=30))

for e in edges:
    e.setdefault("speed_kph", 50)

out = {"format": "dharani-road-graph/1", "nodes": nodes, "edges": edges}
text = json.dumps(out, separators=(",", ":"))
for path in sys.argv[1:] or ["mobile-ui/assets/road_graph.json"]:
    with open(path, "w") as f:
        f.write(text)
    print(f"wrote {path}: {len(nodes)} nodes, {len(edges)} edges, {len(text) // 1024} KiB")
print("anchors:", dict(silk=silk, ecity=ecity, attibele=attibele, hosur=hosur, shool=shool, krish=krish))
