#!/usr/bin/env python3 -I
"""Validates the hike route manifest against the bundled NPS trail geometry and writes the app pack.

Input:  content/hikes/hike-routes.json (reviewed ordered feature chains with trims and anchors)
        ios/PettyFieldGuide/Resources/Geo/trails.geojson (must already contain the appended NPS features) for
        Valley routes, and Geo/park-trails.geojson (tools/build_park_trails.py) for routes marked "geometry": "park"
        ios/PettyFieldGuide/Resources/Content/trails.json and park-hikes.json (published distances and route labels)
Output: ios/PettyFieldGuide/Resources/Content/hike-routes.json (resolved fractions, trace lengths, bounds,
        milestones with chainage, provenance) and docs/hiking-atlas/<route>.svg review drawings.

Usage: python3 -I tools/build_hike_routes.py [--check] [--no-atlas]
Exit 1 when any route fails continuity, endpoint, closure, membership or length checks.
"""
import hashlib
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "content" / "hikes" / "hike-routes.json"
GEO = ROOT / "ios" / "PettyFieldGuide" / "Resources" / "Geo" / "trails.geojson"
PARK_GEO = ROOT / "ios" / "PettyFieldGuide" / "Resources" / "Geo" / "park-trails.geojson"
TRAILS = ROOT / "ios" / "PettyFieldGuide" / "Resources" / "Content" / "trails.json"
PARK_HIKES = ROOT / "ios" / "PettyFieldGuide" / "Resources" / "Content" / "park-hikes.json"
PACK = ROOT / "ios" / "PettyFieldGuide" / "Resources" / "Content" / "hike-routes.json"
ATLAS = ROOT / "docs" / "hiking-atlas"

CONTINUITY_M = 2.0        # consecutive segments must meet within this
ANCHOR_SNAP_M = 50.0      # an anchored trim must lie within this of the feature
MILESTONE_M = 60.0        # a milestone must lie within this of the travelled line
PUBLISHED_RATIO = (0.75, 1.35)


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

    def point(self, frac):
        target = frac * self.length
        for s in range(1, len(self.coords)):
            if target <= self.cum[s] or s == len(self.coords) - 1:
                seg = self.cum[s] - self.cum[s - 1]
                t = 0 if seg == 0 else max(0.0, min(1.0, (target - self.cum[s - 1]) / seg))
                a, b = self.coords[s - 1], self.coords[s]
                return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
        return self.coords[-1]

    def nearest(self, lonlat):
        """(distance m, fraction) of the nearest point on the feature to lonlat."""
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

    def slice(self, f0, f1):
        reverse = f1 < f0
        lo, hi = (f1, f0) if reverse else (f0, f1)
        out = [self.point(lo)]
        for s, c in enumerate(self.coords):
            f = self.cum[s] / self.length if self.length else 0
            if lo < f < hi:
                out.append(c)
        out.append(self.point(hi))
        return out[::-1] if reverse else out


def load_features(path=GEO):
    doc = json.loads(path.read_text())
    feats = {}
    for f in doc["features"]:
        g = f["geometry"]
        if g["type"] == "LineString":
            feats[f["id"]] = Feature(f["id"], f["properties"], g["coordinates"])
        elif g["type"] == "MultiLineString":
            for k, part in enumerate(g["coordinates"]):
                feats[f"{f['id']}-{k}"] = Feature(f"{f['id']}-{k}", f["properties"], part)
    return feats, hashlib.sha256(path.read_bytes()).hexdigest(), len(doc["features"]), doc.get("fetchedAt")


def line_length(coords):
    return sum(haversine(coords[i - 1], coords[i]) for i in range(1, len(coords)))


def nearest_on_line(coords, cum, lonlat):
    kx = 111_320 * math.cos(math.radians(lonlat[1]))
    px, py = lonlat[0] * kx, lonlat[1] * 110_574
    best = (float("inf"), 0.0)
    for s in range(1, len(coords)):
        ax, ay = coords[s - 1][0] * kx, coords[s - 1][1] * 110_574
        bx, by = coords[s][0] * kx, coords[s][1] * 110_574
        dx, dy = bx - ax, by - ay
        l2 = dx * dx + dy * dy
        t = 0 if l2 == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / l2))
        d = math.hypot(ax + t * dx - px, ay + t * dy - py)
        if d < best[0]:
            best = (d, cum[s - 1] + t * (cum[s] - cum[s - 1]))
    return best


def resolve_route(route, manifest, feats, trails, errors):
    rid = route["id"]
    anchors = manifest["anchors"]
    trail = next((t for t in trails if t["id"] == route["trailId"]), None)
    if trail is None:
        errors.append(f"{rid}: unknown trail {route['trailId']}")
        return None
    published = next((r for r in trail["routes"] if r["label"] == route["label"]), None)
    if published is None:
        errors.append(f"{rid}: trails.json has no route labelled {route['label']!r} for {route['trailId']}")
        return None

    segments = []
    coords = []
    for i, seg in enumerate(route["segments"]):
        feat = feats.get(seg["feature"])
        if feat is None:
            errors.append(f"{rid}: segment {i} references feature {seg['feature']} that is not in the {route.get('geometry', 'valley')} trail pack")
            return None
        fr = []
        for key in ("from", "to"):
            v = seg[key]
            if isinstance(v, dict):
                anchor = anchors[v["at"]]
                d, frac = feat.nearest(anchor["lonlat"])
                if d > ANCHOR_SNAP_M:
                    errors.append(f"{rid}: segment {i} anchor {v['at']} is {d:.1f} m from feature {feat.id}")
                fr.append(frac)
            else:
                fr.append(float(v))
        f0, f1 = fr
        if abs(f1 - f0) * feat.length < 0.5:
            errors.append(f"{rid}: segment {i} on {feat.id} is shorter than 0.5 m")
        part = feat.slice(f0, f1)
        if coords:
            joint = haversine(coords[-1], part[0])
            if joint > CONTINUITY_M:
                errors.append(f"{rid}: segment {i} ({feat.id}) starts {joint:.1f} m from the end of segment {i - 1}")
            part = part[1:]
        coords += part
        # Parts of a multi-part NPS feature are keyed "<id>-<k>"; the pack keeps the integer id and the part index.
        base, _, part = str(feat.id).partition("-")
        segment = {"feature": int(base), "name": feat.props.get("TRLNAME"), "altName": feat.props.get("TRLALTNAME"),
                   "surface": feat.props.get("TRLSURFACE"), "use": feat.props.get("TRLUSE"),
                   "from": round(f0, 6), "to": round(f1, 6), "metres": round(abs(f1 - f0) * feat.length, 1)}
        if part:
            segment["part"] = int(part)
        segments.append(segment)

    one_way = line_length(coords)
    kind = route["kind"]
    travelled = coords + coords[-2::-1] if kind == "outAndBack" else coords
    total = line_length(travelled)
    start, dest = anchors[route["start"]], anchors[route["destination"]]
    d_start = haversine(coords[0], start["lonlat"])
    d_dest = haversine(coords[-1], dest["lonlat"])
    if d_start > ANCHOR_SNAP_M:
        errors.append(f"{rid}: trace starts {d_start:.1f} m from anchor {route['start']}")
    if d_dest > ANCHOR_SNAP_M:
        errors.append(f"{rid}: trace ends {d_dest:.1f} m from anchor {route['destination']}")
    if kind == "loop":
        closure = haversine(coords[0], coords[-1])
        if closure > CONTINUITY_M:
            errors.append(f"{rid}: loop does not close ({closure:.1f} m between start and end)")
        if route["start"] != route["destination"]:
            errors.append(f"{rid}: a loop must start and end at the same anchor")
    elif route["start"] == route["destination"]:
        errors.append(f"{rid}: {kind} routes need distinct start and destination anchors")

    cum = [0.0]
    for i in range(1, len(travelled)):
        cum.append(cum[-1] + haversine(travelled[i - 1], travelled[i]))
    milestones = []
    for aid in [route["start"]] + route["milestones"] + [route["destination"]]:
        anchor = anchors[aid]
        d, chain_m = nearest_on_line(travelled, cum, anchor["lonlat"])
        if d > MILESTONE_M:
            errors.append(f"{rid}: milestone {aid} is {d:.1f} m from the route")
        role = "start" if aid == route["start"] and not milestones else ("destination" if aid == route["destination"] and len(milestones) == len(route["milestones"]) + 1 else "waypoint")
        if kind == "loop" and aid == route["destination"] and milestones:
            chain_m = cum[-1]
        milestones.append({"anchor": aid, "name": anchor["name"], "role": role, "lonlat": anchor["lonlat"], "chainageMiles": round(chain_m / 1609.344, 2),
                           "offsetMetres": round(d, 1), "source": anchor["source"]})
    last = -1.0
    for m in milestones:
        if m["chainageMiles"] + 1e-9 < last:
            errors.append(f"{rid}: milestone {m['anchor']} is out of travel order")
        last = m["chainageMiles"]

    ratio = total / 1609.344 / published["distanceMi"]
    if not PUBLISHED_RATIO[0] <= ratio <= PUBLISHED_RATIO[1]:
        errors.append(f"{rid}: trace {total / 1609.344:.2f} mi is {ratio:.2f}× the published {published['distanceMi']} mi")
    xs = [c[0] for c in coords]
    ys = [c[1] for c in coords]
    names = {}
    for s in segments:
        names[s["name"] or "unnamed"] = round(names.get(s["name"] or "unnamed", 0) + s["metres"], 1)
    resolved = {
        "id": rid, "trailId": route["trailId"], "label": route["label"], "kind": kind, "isDefault": route["isDefault"],
        "publishedMiles": published["distanceMi"], "traceMiles": round(total / 1609.344, 2), "traceOneWayMiles": round(one_way / 1609.344, 2),
        "traceToPublishedRatio": round(ratio, 3),
        "bounds": {"west": round(min(xs), 6), "south": round(min(ys), 6), "east": round(max(xs), 6), "north": round(max(ys), 6)},
        "start": milestones[0], "destination": milestones[-1], "milestones": milestones[1:-1],
        "segments": segments, "metresByName": names, "unnamedFeatures": sum(1 for s in segments if not s["name"]),
        "sequence": route["sequence"], "traceNote": route["traceNote"],
        "_coords": coords, "_travelled": travelled,
    }
    # Valley routes omit the key so their pack entries stay byte-identical.
    if route.get("geometry") == "park":
        resolved["geometry"] = "park"
    return resolved


def atlas_svg(route, feats):
    coords = route["_coords"]
    b = route["bounds"]
    pad = 0.12
    w_deg = max(b["east"] - b["west"], 0.004)
    h_deg = max(b["north"] - b["south"], 0.004)
    west, east = b["west"] - w_deg * pad, b["east"] + w_deg * pad
    south, north = b["south"] - h_deg * pad, b["north"] + h_deg * pad
    kx = math.cos(math.radians((north + south) / 2))
    width = 900.0
    scale = width / ((east - west) * kx)
    height = (north - south) * scale

    def xy(c):
        return ((c[0] - west) * kx * scale, (north - c[1]) * scale)

    def path(cs):
        return "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y in (xy(c) for c in cs))

    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:.0f}" height="{height + 70:.0f}" viewBox="0 0 {width:.0f} {height + 70:.0f}" font-family="Helvetica, Arial, sans-serif">',
           '<rect width="100%" height="100%" fill="#f6f2ea"/>']
    # Context: every bundled trail feature inside the frame, thin grey, so reviewers see what was not chosen.
    for f in feats.values():
        if any(west <= c[0] <= east and south <= c[1] <= north for c in f.coords[::5] + f.coords[-1:]):
            out.append(f'<path d="{path(f.coords)}" fill="none" stroke="#b9b0a2" stroke-width="1" stroke-dasharray="3 3"/>')
    out.append(f'<path d="{path(coords)}" fill="none" stroke="#fff4e0" stroke-width="7" stroke-linejoin="round" stroke-linecap="round"/>')
    out.append(f'<path d="{path(coords)}" fill="none" stroke="#F5921A" stroke-width="3.5" stroke-linejoin="round" stroke-linecap="round"/>')
    for m in [route["start"]] + route["milestones"] + [route["destination"]]:
        x, y = xy(m["lonlat"])
        colour = {"start": "#1F4D3F", "destination": "#C93B2E"}.get(m["role"], "#3B7EA8")
        out.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="5" fill="{colour}" stroke="#fff" stroke-width="1.5"/>')
        out.append(f'<text x="{x + 8:.1f}" y="{y + 4:.1f}" font-size="11" fill="#2b2620">{m["name"]} · {m["chainageMiles"]} mi</text>')
    km = 1000 * kx * scale / (111_320 * kx)
    out.append(f'<line x1="20" y1="{height + 30:.0f}" x2="{20 + km:.1f}" y2="{height + 30:.0f}" stroke="#2b2620" stroke-width="2"/>')
    out.append(f'<text x="20" y="{height + 24:.0f}" font-size="11" fill="#2b2620">1 km · north up · WGS84 lon/lat {west:.4f}…{east:.4f}, {south:.4f}…{north:.4f}</text>')
    out.append(f'<text x="20" y="{height + 52:.0f}" font-size="12" fill="#2b2620" font-weight="bold">{route["id"]} — {route["label"]} ({route["kind"]}): trace {route["traceMiles"]} mi vs published {route["publishedMiles"]} mi; {len(route["segments"])} NPS features</text>')
    out.append("</svg>")
    return "\n".join(out)


def build(check_only=False, atlas=True):
    manifest = json.loads(SOURCE.read_text())
    feats, sha, count, _ = load_features()
    park_feats, park_sha, park_count, park_fetched = load_features(PARK_GEO)
    packs = {"valley": feats, "park": park_feats}
    valley = json.loads(TRAILS.read_text())["trails"]
    park = json.loads(PARK_HIKES.read_text())["trails"]
    trails = valley + park
    errors = []
    routes = []
    ids = set()
    for route in manifest["routes"]:
        if route["id"] in ids:
            errors.append(f"duplicate route id {route['id']}")
        ids.add(route["id"])
        if route.get("geometry", "valley") not in packs:
            errors.append(f"{route['id']}: unknown geometry {route['geometry']!r}")
            continue
        resolved = resolve_route(route, manifest, packs[route.get("geometry", "valley")], trails, errors)
        if resolved:
            routes.append(resolved)
    # Valley hikes must be traced completely; park-wide hikes are traced only where the bundled geometry
    # holds the whole route, and the app labels the rest as untraced.
    for trail in trails:
        own = [r for r in routes if r["trailId"] == trail["id"]]
        published = {r["id"] for r in trail["routes"]}
        for r in own:
            if r["id"] not in published:
                errors.append(f"{trail['id']}: traced route {r['id']} has no published route with that id")
        if trail in valley and len(own) != len(trail["routes"]):
            errors.append(f"{trail['id']}: {len(trail['routes'])} published routes but {len(own)} traced")
        if own and sum(1 for r in own if r["isDefault"]) != 1:
            errors.append(f"{trail['id']}: exactly one default route is required")
    for route in routes:
        print(f"{route['id']:32} {route['kind']:10} trace {route['traceMiles']:6.2f} mi  published {route['publishedMiles']:5} mi  ratio {route['traceToPublishedRatio']:.3f}  features {len(route['segments']):3d}")
    if errors:
        print("\n".join("ERROR " + e for e in errors))
        sys.exit(1)
    print(f"{len(routes)} routes validated against {count} Valley features (sha256 {sha[:12]}…) and {park_count} park features (sha256 {park_sha[:12]}…)")
    if check_only:
        return
    pack = {
        "schema": 1,
        "generated": manifest.get("generated", "2026-10-27"),
        "geometry": {"file": "trails.geojson", "sha256": sha, "featureCount": count,
                     "source": "NPS Public GIS NationalDatasets NPS_Public_Trails_Geographic (UNITCODE YOSE), fetched 2026-09-21; John Muir Trail features 20072 and 22688 fetched 2026-10-27"},
        "parkGeometry": {"file": "park-trails.geojson", "sha256": park_sha, "featureCount": park_count,
                         "source": f"NPS Public GIS NationalDatasets NPS_Public_Trails_Geographic (UNITCODE YOSE, all {park_count} existing features), fetched {park_fetched}"},
        "derivation": manifest["derivation"],
        "routes": [{k: v for k, v in r.items() if not k.startswith("_")} for r in routes],
    }
    PACK.write_text(json.dumps(pack, ensure_ascii=False, separators=(",", ":")))
    print(f"wrote {PACK.relative_to(ROOT)} ({PACK.stat().st_size:,} bytes)")
    if atlas:
        ATLAS.mkdir(parents=True, exist_ok=True)
        for route in routes:
            (ATLAS / f"{route['id']}.svg").write_text(atlas_svg(route, packs[route.get("geometry", "valley")]))
        index = ["# Hiking route atlas", "", "Generated by `tools/build_hike_routes.py` from the bundled NPS geometry; orange is the traced route, dashed grey every other NPS trail feature in the frame. Coordinates are WGS84, north up.", ""]
        for route in routes:
            index.append(f"- [{route['id']}]({route['id']}.svg) — {route['label']} ({route['kind']}): trace {route['traceMiles']} mi vs published {route['publishedMiles']} mi, {len(route['segments'])} features")
        (ATLAS / "README.md").write_text("\n".join(index) + "\n")
        print(f"wrote {len(routes)} atlas drawings to {ATLAS.relative_to(ROOT)}")


if __name__ == "__main__":
    build(check_only="--check" in sys.argv, atlas="--no-atlas" not in sys.argv)
