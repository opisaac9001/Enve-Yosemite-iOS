#!/usr/bin/env python3 -I
"""Writes the park-wide supplements that extend the Valley packs into one continuous map.

Inputs (untracked research downloads, parsed as data only):
  research/park-basemap/   NPS roads, buildings, parking lots and POIs for all of Yosemite (tools/fetch_park_basemap.py)
  research/nhd-hu8/        USGS NHD High Resolution HU8 shapefile packages 18040006, 18040008, 18040009, 18090101
                           from https://prd-tnm.s3.amazonaws.com/StagedProducts/Hydrography/NHD/HU8/Shape/
  research/gnis/           USGS GNIS DomesticNames_CA_Text.zip from
                           https://prd-tnm.s3.amazonaws.com/StagedProducts/GeographicNames/DomesticNames/

Outputs in ios/PettyFieldGuide/Resources/Geo/, each recorded in park-manifest.json and Content/pack-manifest.json:
  park-roads.geojson, park-buildings.geojson, park-parking.geojson, park-pois.geojson
      NPS features whose OBJECTID is not already in the Valley pack (roads/buildings/parking/pois.geojson).
      The park-wide download contains every Valley feature with identical geometry, so the Valley pack plus
      these supplements is the whole park with no feature twice. Coordinates rounded to 6 decimals.
  park-water.geojson
      NHD flowlines that are named, or unnamed perennial streams (FCode 46006), and NHD lakes/ponds and
      reservoirs of at least 0.002 km², intersecting YosemiteGeo.parkBounds and not already in
      waterways.geojson (same NHD permanent identifiers). Artificial paths through those lakes are dropped.
      Reaches of the same name that meet end to end are joined into one line. Vertices simplified with
      Douglas–Peucker at 3 m and rounded to 5 decimals (about 1 m). NAD83
      coordinates are used as WGS84 (they differ by about a metre here).
  park-names.geojson
      GNIS official names inside parkBounds for summits, passes (Gap), meadows (Flat), valleys and canyons,
      ridges, pillars, cliffs, basins and ranges, as label points.

Usage: python3 -I tools/build_park_basemap.py
"""
import glob
import hashlib
import io
import json
import math
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import shapefile_reader  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
GEO = ROOT / "ios" / "PettyFieldGuide" / "Resources" / "Geo"
RESEARCH = ROOT / "research"
PARK_MANIFEST = GEO / "park-manifest.json"
PACK_MANIFEST = ROOT / "ios" / "PettyFieldGuide" / "Resources" / "Content" / "pack-manifest.json"
WEST, SOUTH, EAST, NORTH = -120.05, 37.37, -119.05, 38.30
NHD_URL = "https://prd-tnm.s3.amazonaws.com/StagedProducts/Hydrography/NHD/HU8/Shape/"
GNIS_URL = "https://prd-tnm.s3.amazonaws.com/StagedProducts/GeographicNames/DomesticNames/DomesticNames_CA_Text.zip"
GNIS_CLASSES = {"Summit", "Gap", "Flat", "Valley", "Ridge", "Pillar", "Cliff", "Basin", "Range"}
NPS_KEEP = {
    "roads": ("RDNAME", "RDALTNAME", "RDCLASS", "RDSURFACE", "RDONEWAY", "RDSTATUS", "RTENUMBER", "SEASONAL", "SEASDESC",
              "PUBLICDISPLAY", "OPENTOPUBLIC", "MAPLABEL", "XYACCURACY"),
    "buildings": ("BLDGNAME", "BLDGALTNAME", "BLDGTYPE", "BLDGSTATUS", "PUBLICDISPLAY", "MAPLABEL", "XYACCURACY"),
    "parking": ("LOTNAME", "LOTALTNAME", "LOTTYPE", "PUBLICDISPLAY", "OPENTOPUBLIC", "MAPLABEL", "SEASONAL", "SEASDESC",
                "ACCESSNOTES", "XYACCURACY"),
    "pois": ("POINAME", "POIALTNAME", "POITYPE", "POISTATUS", "PUBLICDISPLAY", "OPENTOPUBLIC", "MAPLABEL", "SEASONAL",
             "SEASDESC", "XYACCURACY"),
}
VALLEY_FILES = {"roads": "roads.geojson", "buildings": "buildings.geojson", "parking": "parking.geojson", "pois": "pois.geojson"}
M_LAT = 111_000.0
M_LON = 111_320.0 * math.cos(math.radians((SOUTH + NORTH) / 2))


def rounded(coords, places):
    if coords and isinstance(coords[0], (int, float)):
        return [round(coords[0], places), round(coords[1], places)]
    return [rounded(c, places) for c in coords]


def simplify(points, tolerance=3.0):
    if len(points) < 3:
        return points
    xy = [((x - points[0][0]) * M_LON, (y - points[0][1]) * M_LAT) for x, y in points]
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    tol2 = tolerance * tolerance
    while stack:
        a, b = stack.pop()
        if b - a < 2:
            continue
        ax, ay = xy[a]
        dx, dy = xy[b][0] - ax, xy[b][1] - ay
        length2 = dx * dx + dy * dy
        best, index = 0.0, a
        for i in range(a + 1, b):
            px, py = xy[i][0] - ax, xy[i][1] - ay
            t = max(0.0, min(1.0, (px * dx + py * dy) / length2)) if length2 else 0.0
            ex, ey = px - t * dx, py - t * dy
            d = ex * ex + ey * ey
            if d > best:
                best, index = d, i
        if best > tol2:
            keep[index] = True
            stack += [(a, index), (index, b)]
    return [p for p, k in zip(points, keep) if k]


def merge_reaches(reaches):
    """Joins NHD reaches of the same name (or both unnamed) where exactly two of them meet, so a creek is
    one line instead of dozens of short reaches. Returns (first permanent id, points, name) per chain."""
    def key(p):
        return round(p[0], 6), round(p[1], 6)

    lines = [(pid, list(part), row.get("gnis_name")) for pid, parts, row in reaches for part in parts]
    ends = {}
    for i, (_, pts, name) in enumerate(lines):
        for end in (key(pts[0]), key(pts[-1])):
            ends.setdefault((name, end), []).append(i)
    used = [False] * len(lines)

    def grow(chain, name):
        """Appends unused neighbours at the chain's last point while the junction joins exactly two lines."""
        while True:
            tip = key(chain[-1])
            meeting = ends.get((name, tip), [])
            nxt = [j for j in meeting if not used[j]]
            if len(meeting) != 2 or len(nxt) != 1:
                return chain
            used[nxt[0]] = True
            pts = lines[nxt[0]][1]
            chain += (pts if key(pts[0]) == tip else pts[::-1])[1:]

    out = []
    for i, (pid, pts, name) in enumerate(lines):
        if used[i]:
            continue
        used[i] = True
        chain = grow(list(pts), name)
        chain = grow(chain[::-1], name)[::-1]
        out.append((pid, chain, name))
    return out


def in_bounds(parts):
    return any(WEST <= x <= EAST and SOUTH <= y <= NORTH for part in parts for x, y in part)


def write_pack(name, doc, entries):
    path = GEO / name
    data = json.dumps(doc, separators=(",", ":"), ensure_ascii=False).encode()
    path.write_bytes(data)
    entries.append({"file": name, "count": len(doc["features"]), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                    "fetchedAt": doc["fetchedAt"]})
    print(f"{name}: {len(doc['features'])} features, {len(data):,} bytes")


def nps_supplements(entries):
    src = RESEARCH / "park-basemap"
    record = json.loads((src / "fetch-record.json").read_text())
    for layer, file in VALLEY_FILES.items():
        raw_bytes = (src / f"{layer}-raw.geojson").read_bytes()
        if hashlib.sha256(raw_bytes).hexdigest() != record[layer]["sha256"]:
            sys.exit(f"{layer}-raw.geojson does not match its fetch record")
        valley = json.loads((GEO / file).read_text())["features"]
        valley_ids = {f["id"] for f in valley}
        raw = json.loads(raw_bytes)["features"]
        raw_ids = {f["id"] for f in raw}
        if not valley_ids <= raw_ids:
            sys.exit(f"{layer}: Valley features {sorted(valley_ids - raw_ids)[:5]} are missing from the park-wide download")
        features = [{"type": "Feature", "id": f["id"], "geometry": {"type": f["geometry"]["type"], "coordinates": rounded(f["geometry"]["coordinates"], 6)},
                     "properties": {k: f["properties"].get(k) for k in NPS_KEEP[layer]}}
                    for f in sorted(raw, key=lambda f: f["id"]) if f["id"] not in valley_ids and f.get("geometry")]
        r = record[layer]
        write_pack(f"park-{layer}.geojson", {
            "type": "FeatureCollection", "name": f"park-{layer}",
            "source": f"NPS Public GIS NationalDatasets, {r['service'].split('/')[-3]}, {r['where']}",
            "service": r["service"], "fetchedAt": r["fetchedAt"], "licence": record["licence"], "rawSha256": r["sha256"],
            "processing": f"Features already in {file} (same OBJECTID, identical geometry) are left out; OBJECTID kept as id; coordinates rounded to 6 decimals",
            "features": features,
        }, entries)


def nhd_water(entries):
    valley_ids = {f["id"] for f in json.loads((GEO / "waterways.geojson").read_text())["features"]}
    zips = sorted(glob.glob(str(RESEARCH / "nhd-hu8" / "NHD_H_*_HU8_Shape.zip")))
    if len(zips) != 4:
        sys.exit("expected the four NHD HU8 packages under research/nhd-hu8")
    lakes, flowlines, seen = [], [], set()
    for path in zips:
        archive = zipfile.ZipFile(path)
        for shape_type, parts, row in shapefile_reader.records(archive.read("Shape/NHDWaterbody.shp"), archive.read("Shape/NHDWaterbody.dbf")):
            pid = row["permanent_"]
            if pid in seen or row.get("ftype") not in (390, 436) or (row.get("areasqkm") or 0) < 0.002 or not in_bounds(parts):
                continue
            seen.add(pid)
            lakes.append((pid, parts, row))
        for shape_type, parts, row in shapefile_reader.records(archive.read("Shape/NHDFlowline.shp"), archive.read("Shape/NHDFlowline.dbf")):
            pid = row["permanent_"]
            if pid in seen or not in_bounds(parts):
                continue
            if not (row.get("gnis_name") or row.get("fcode") == 46006):
                continue
            seen.add(pid)
            flowlines.append((pid, parts, row))
    lake_ids = {pid for pid, _, _ in lakes}
    features = []
    for pid, parts, row in lakes:
        if f"nhd-{pid}" in valley_ids:
            continue
        rings = [rounded(simplify(ring), 5) for ring in parts]
        rings = [r for r in rings if len(r) >= 4]
        if rings:
            features.append({"type": "Feature", "id": f"nhd-{pid}", "geometry": {"type": "Polygon", "coordinates": rings},
                             "properties": {"gnis_name": row.get("gnis_name"), "ftype": row["ftype"], "fcode": row.get("fcode"), "areasqkm": row.get("areasqkm")}})
    reaches = [(pid, [part for part in parts if len(part) >= 2], row) for pid, parts, row in flowlines
               if f"nhd-{pid}" not in valley_ids and not (row.get("ftype") == 558 and row.get("wbarea_per") in lake_ids)]
    for pid, line, name in merge_reaches(reaches):
        features.append({"type": "Feature", "id": f"nhd-{pid}", "geometry": {"type": "LineString", "coordinates": rounded(simplify(line), 5)},
                         "properties": {"gnis_name": name} if name else {}})
    fetched = (RESEARCH / "nhd-hu8" / "fetched-at.txt").read_text().strip()
    packages = {Path(p).name: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in zips}
    write_pack("park-water.geojson", {
        "type": "FeatureCollection", "name": "park-water",
        "source": "USGS National Hydrography Dataset (NHD) High Resolution, HU8 staged shapefiles " + ", ".join(sorted(packages)),
        "service": NHD_URL, "fetchedAt": fetched, "licence": "Public domain (U.S. Government work, USGS)", "packageSha256": packages,
        "processing": "Named flowlines and unnamed perennial streams (FCode 46006); lakes/ponds (FType 390) and reservoirs (436) of at least 0.002 km²; "
                      "intersecting parkBounds; features already in waterways.geojson and artificial paths through kept lakes left out; "
                      "same-name reaches joined where exactly two meet (id is the first reach's); Douglas–Peucker 3 m; rounded to 5 decimals; NAD83 used as WGS84",
        "features": features,
    }, entries)


def gnis_names(entries):
    path = RESEARCH / "gnis" / "DomesticNames_CA_Text.zip"
    archive = zipfile.ZipFile(path)
    text = io.TextIOWrapper(archive.open("Text/DomesticNames_CA.txt"), encoding="utf-8-sig")
    header = text.readline().rstrip("\n").split("|")
    features = []
    for line in text:
        row = dict(zip(header, line.rstrip("\n").split("|")))
        if row["feature_class"] not in GNIS_CLASSES or "(historical)" in row["feature_name"]:
            continue
        try:
            lat, lon = float(row["prim_lat_dec"]), float(row["prim_long_dec"])
        except ValueError:
            continue
        if SOUTH <= lat <= NORTH and WEST <= lon <= EAST:
            features.append({"type": "Feature", "id": f"gnis-{row['feature_id']}", "geometry": {"type": "Point", "coordinates": [round(lon, 6), round(lat, 6)]},
                             "properties": {"name": row["feature_name"], "class": row["feature_class"]}})
    features.sort(key=lambda f: f["id"])
    write_pack("park-names.geojson", {
        "type": "FeatureCollection", "name": "park-names",
        "source": "USGS Geographic Names Information System (GNIS), Domestic Names, California",
        "service": GNIS_URL, "fetchedAt": (RESEARCH / "gnis" / "fetched-at.txt").read_text().strip(),
        "licence": "Public domain (U.S. Government work, USGS / U.S. Board on Geographic Names)",
        "packageSha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "processing": "Official names inside parkBounds for classes " + ", ".join(sorted(GNIS_CLASSES)) + "; historical names left out; primary coordinates",
        "features": features,
    }, entries)


def update_manifests(entries):
    names = {e["file"] for e in entries}
    park = json.loads(PARK_MANIFEST.read_text())
    park["files"] = [f for f in park["files"] if f["file"] not in names] + entries
    PARK_MANIFEST.write_text(json.dumps(park, indent=2))
    pack = json.loads(PACK_MANIFEST.read_text())
    pack["geo"] = [g for g in pack["geo"] if g["file"] not in names | {PARK_MANIFEST.name}]
    pack["geo"] += [{"file": e["file"], "bytes": e["bytes"], "sha256": e["sha256"]} for e in entries]
    pack["geo"].append({"file": PARK_MANIFEST.name, "bytes": PARK_MANIFEST.stat().st_size, "sha256": hashlib.sha256(PARK_MANIFEST.read_bytes()).hexdigest()})
    PACK_MANIFEST.write_text(json.dumps(pack, separators=(",", ":")))


def main():
    entries = []
    nps_supplements(entries)
    nhd_water(entries)
    gnis_names(entries)
    update_manifests(entries)


if __name__ == "__main__":
    main()
