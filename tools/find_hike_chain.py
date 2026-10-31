#!/usr/bin/env python3 -I
"""Finds the shortest chain of NPS trail features between anchor points, for review before it enters a manifest.

The graph's nodes are feature endpoints snapped within 2 m; every feature is an edge walked in either
direction. The first and last anchors may attach to the nearest point of a feature (a fractional trim);
intermediate anchors must sit within 80 m of a node. Nothing is bridged: when the anchors are not
connected by features the tool says so instead of inventing a line.

Usage: python3 -I tools/find_hike_chain.py <trails.geojson> lon,lat [lon,lat ...] lon,lat [--max-attach 60]
Prints the ordered segments (manifest format), feature names and the one-way length in miles.
"""
import heapq
import json
import math
import sys
from pathlib import Path

SNAP_M = 2.0


def haversine(a, b):
    r = 6371008.8
    la1, lo1, la2, lo2 = map(math.radians, (a[1], a[0], b[1], b[0]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * r * math.asin(min(1, math.sqrt(h)))


class Feature:
    def __init__(self, fid, props, coords):
        self.id = fid
        self.props = props
        self.coords = [(c[0], c[1]) for c in coords]
        self.cum = [0.0]
        for i in range(1, len(self.coords)):
            self.cum.append(self.cum[-1] + haversine(self.coords[i - 1], self.coords[i]))
        self.length = self.cum[-1]

    @property
    def name(self):
        return self.props.get("TRLNAME") or self.props.get("TRLALTNAME") or "(unnamed)"

    def nearest(self, lonlat):
        kx = 111_320 * math.cos(math.radians(lonlat[1]))
        px, py = lonlat[0] * kx, lonlat[1] * 110_574
        best = (float("inf"), 0.0)
        for s in range(1, len(self.coords)):
            ax, ay = self.coords[s - 1][0] * kx, self.coords[s - 1][1] * 110_574
            bx, by = self.coords[s][0] * kx, self.coords[s][1] * 110_574
            dx, dy = bx - ax, by - ay
            l2 = dx * dx + dy * dy
            t = 0 if l2 == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / l2))
            d = math.hypot(ax + t * dx - px, ay + t * dy - py)
            if d < best[0]:
                frac = (self.cum[s - 1] + t * (self.cum[s] - self.cum[s - 1])) / self.length if self.length else 0.0
                best = (d, frac)
        return best


def load(path):
    doc = json.loads(Path(path).read_text())
    feats = {}
    for f in doc["features"]:
        g = f["geometry"]
        if g["type"] == "LineString":
            feats[f["id"]] = Feature(f["id"], f["properties"], g["coordinates"])
        elif g["type"] == "MultiLineString":
            for k, part in enumerate(g["coordinates"]):
                feats[f"{f['id']}-{k}"] = Feature(f"{f['id']}-{k}", f["properties"], part)
    return feats


class Graph:
    def __init__(self, feats):
        self.feats = feats
        self.nodes = []            # lonlat
        self.edges = {}            # node -> [(node, feature id, forward, metres)]
        self.ends = {}             # feature id -> (start node, end node)
        for f in feats.values():
            a = self.node(f.coords[0])
            b = self.node(f.coords[-1])
            self.ends[f.id] = (a, b)
            self.edges.setdefault(a, []).append((b, f.id, True, f.length))
            self.edges.setdefault(b, []).append((a, f.id, False, f.length))

    def node(self, lonlat):
        for i, n in enumerate(self.nodes):
            if haversine(n, lonlat) <= SNAP_M:
                return i
        self.nodes.append(lonlat)
        return len(self.nodes) - 1

    def nearest_node(self, lonlat):
        best = min(range(len(self.nodes)), key=lambda i: haversine(self.nodes[i], lonlat))
        return best, haversine(self.nodes[best], lonlat)

    def dijkstra(self, source_costs, targets, excluded=frozenset()):
        """source_costs: {node: cost}; returns (cost, path of (feature, forward)) to the cheapest target."""
        dist = dict(source_costs)
        prev = {}
        heap = [(c, n) for n, c in source_costs.items()]
        heapq.heapify(heap)
        done = set()
        while heap:
            c, n = heapq.heappop(heap)
            if n in done:
                continue
            done.add(n)
            if n in targets:
                target = n
                path = []
                while n in prev:
                    pn, fid, fwd = prev[n]
                    path.append((fid, fwd))
                    n = pn
                return c, path[::-1], target
            for m, fid, fwd, w in self.edges.get(n, []):
                if fid in excluded:
                    continue
                nc = c + w
                if nc < dist.get(m, float("inf")):
                    dist[m] = nc
                    prev[m] = (n, fid, fwd)
                    heapq.heappush(heap, (nc, m))
        return None


def attach(graph, lonlat, max_m):
    """Candidate attachments of an anchor: (feature, fraction, distance) for features within max_m."""
    out = []
    for f in graph.feats.values():
        d, frac = f.nearest(lonlat)
        if d <= max_m:
            out.append((f, frac, d))
    return sorted(out, key=lambda x: x[2])


def main(argv):
    max_attach = 60.0
    if "--max-attach" in argv:
        i = argv.index("--max-attach")
        max_attach = float(argv[i + 1])
        del argv[i:i + 2]
    # --loop: later legs avoid features already walked, so a via point yields a circuit rather than a retrace.
    loop = "--loop" in argv
    if loop:
        argv.remove("--loop")
    feats = load(argv[1])
    anchors = [tuple(float(x) for x in a.split(",")) for a in argv[2:]]
    if len(anchors) < 2:
        sys.exit("need a start and an end anchor")
    graph = Graph(feats)
    segments = []
    total = 0.0

    def push(fid, f0, f1):
        f = feats[fid]
        metres = abs(f1 - f0) * f.length
        if metres < 0.5:
            return
        segments.append({"feature": fid, "from": round(f0, 6), "to": round(f1, 6), "metres": round(metres, 1), "name": f.name})

    # Start: either a node or a point on a feature; both ends of the attached feature become sources.
    start_opts = attach(graph, anchors[0], max_attach)
    if not start_opts:
        sys.exit(f"no feature within {max_attach} m of the start anchor")
    legs = list(zip(anchors, anchors[1:]))
    if len(legs) == 1:
        end_opts = attach(graph, anchors[1], max_attach)
        if end_opts and end_opts[0][0].id == start_opts[0][0].id:
            # Both anchors sit on one feature: a single trimmed segment, no detour via its ends.
            f, f0, d0 = start_opts[0]
            _, f1, d1 = end_opts[0]
            print(f"# both anchors attach to {f.id} ({f.name}) at {f0:.3f} ({d0:.1f} m) and {f1:.3f} ({d1:.1f} m)")
            push(f.id, f0, f1)
            legs = []
    for li, (a, b) in enumerate(legs):
        first, last = li == 0, li == len(legs) - 1
        if first:
            f, frac, d = start_opts[0]
            sa, sb = graph.ends[f.id]
            sources = {sa: frac * f.length, sb: (1 - frac) * f.length}
            start_desc = f"start attaches to {f.id} ({f.name}) at fraction {frac:.3f}, {d:.1f} m away"
        else:
            n, d = graph.nearest_node(a)
            sources = {n: 0.0}
            start_desc = f"via node {n} ({d:.1f} m from anchor)"
        if last:
            end_opts = attach(graph, b, max_attach)
            if not end_opts:
                sys.exit(f"no feature within {max_attach} m of the end anchor")
            ef, efrac, ed = end_opts[0]
            ea, eb = graph.ends[ef.id]
            targets = {ea, eb}
            end_desc = f"end attaches to {ef.id} ({ef.name}) at fraction {efrac:.3f}, {ed:.1f} m away"
        else:
            n, d = graph.nearest_node(b)
            if d > 80:
                sys.exit(f"via anchor {b} is {d:.0f} m from the nearest node; it must be a junction")
            targets = {n}
            end_desc = f"via node {n} ({d:.1f} m from anchor)"
        used = frozenset(s["feature"] for s in segments) if loop else frozenset()
        result = graph.dijkstra(sources, targets, used)
        if result is None:
            sys.exit(f"leg {li}: the anchors are not connected by trail features ({start_desc}; {end_desc})")
        cost, path, reached = result
        print(f"# leg {li}: {start_desc}; {end_desc}")
        if first:
            f, frac, _ = start_opts[0]
            sa, sb = graph.ends[f.id]
            # The leg starts with a partial feature to whichever end the path left from.
            first_node = sa if (not path and reached == sa) or (path and graph.ends[path[0][0]][0 if path[0][1] else 1] == sa) else sb
            if first_node == sa and frac > 0:
                push(f.id, frac, 0.0)
            elif first_node == sb and frac < 1:
                push(f.id, frac, 1.0)
        for fid, fwd in path:
            push(fid, 0.0 if fwd else 1.0, 1.0 if fwd else 0.0)
        if last:
            ea, eb = graph.ends[ef.id]
            if reached == ea and efrac > 0:
                push(ef.id, 0.0, efrac)
            elif reached == eb and efrac < 1:
                push(ef.id, 1.0, efrac)
    total = sum(s["metres"] for s in segments)
    print(json.dumps([{k: v for k, v in s.items() if k in ("feature", "from", "to")} for s in segments], separators=(",", ":")))
    for s in segments:
        print(f"  {s['feature']:>8}  {s['from']:.3f}→{s['to']:.3f}  {s['metres']:7.1f} m  {s['name']}")
    print(f"one-way {total / 1609.344:.2f} mi ({total:.0f} m), {len(segments)} segments")


if __name__ == "__main__":
    main(sys.argv)
