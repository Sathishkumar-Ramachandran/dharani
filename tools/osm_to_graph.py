#!/usr/bin/env python3
"""Builds road_graph.json from OpenStreetMap via Overpass. UNTESTED in this repo.

usage: osm_to_graph.py south west north east out.json
"""
import json, subprocess, sys

s, w, n, e, out = sys.argv[1:6]
q = f'[out:json][timeout:120];(way["highway"~"motorway|trunk|primary|secondary|tertiary|unclassified|residential"]({s},{w},{n},{e}););out body;>;out skel qt;'
raw = subprocess.run(["curl", "-fsS", "--data-urlencode", f"data={q}", "https://overpass-api.de/api/interpreter"],
                     check=True, capture_output=True).stdout
data = json.loads(raw)
coords = {x["id"]: (x["lat"], x["lon"]) for x in data["elements"] if x["type"] == "node"}
idx, nodes, edges = {}, [], []
def nid(i):
    if i not in idx:
        idx[i] = len(nodes); nodes.append(list(coords[i]))
    return idx[i]
def num(v):
    try: return float(str(v).split()[0])
    except Exception: return 0
for way in (x for x in data["elements"] if x["type"] == "way"):
    t = way.get("tags", {}); hw = t.get("highway", "")
    speed = num(t.get("maxspeed")) or {"motorway": 80, "trunk": 70, "primary": 55, "secondary": 45}.get(hw, 30)
    for a, b in zip(way["nodes"], way["nodes"][1:]):
        if a in coords and b in coords and a != b:
            edges.append(dict(a=nid(a), b=nid(b), name=t.get("ref") or t.get("name", ""), speed_kph=speed,
                              oneway=t.get("oneway") == "yes", toll=t.get("toll") == "yes",
                              max_height_m=num(t.get("maxheight")), max_weight_t=num(t.get("maxweight")),
                              two_wheeler=hw not in ("motorway",)))
json.dump({"format": "dharani-road-graph/1", "nodes": nodes, "edges": edges}, open(out, "w"), separators=(",", ":"))
print(len(nodes), "nodes", len(edges), "edges")
