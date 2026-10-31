#!/usr/bin/env python3 -I
"""Writes the bundled park-wide trail pack from the read-only NPS download made by tools/fetch_park_trails.py.

Input:  research/park-trails/park-trails-raw.geojson and fetch-record.json (untracked)
Output: ios/PettyFieldGuide/Resources/Geo/park-trails.geojson, plus its entries in park-manifest.json and
        Content/pack-manifest.json.

Every NPS feature keeps its OBJECTID as the GeoJSON id and its vertices, rounded to 6 decimal places
(about 0.1 m), so hike-route manifests can cite the same ids as the Valley pack. Only the descriptive
attributes the app shows are kept. Nothing is joined, snapped or simplified here.

Usage: python3 -I tools/build_park_trails.py [research/park-trails]
"""
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GEO = ROOT / "ios" / "PettyFieldGuide" / "Resources" / "Geo"
OUT = GEO / "park-trails.geojson"
PARK_MANIFEST = GEO / "park-manifest.json"
PACK_MANIFEST = ROOT / "ios" / "PettyFieldGuide" / "Resources" / "Content" / "pack-manifest.json"
KEEP = ("TRLNAME", "TRLALTNAME", "MAPLABEL", "TRLFEATTYPE", "TRLCLASS", "TRLUSE", "TRLSURFACE", "TRLSTATUS",
        "SEASONAL", "SEASDESC", "MAINTAINER", "XYACCURACY", "MAPMETHOD")


def rounded(coords):
    return [[round(c[0], 6), round(c[1], 6)] for c in coords]


def main():
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "research" / "park-trails"
    raw_bytes = (src / "park-trails-raw.geojson").read_bytes()
    record = json.loads((src / "fetch-record.json").read_text())
    if hashlib.sha256(raw_bytes).hexdigest() != record["sha256"]:
        sys.exit("park-trails-raw.geojson does not match its fetch record")
    raw = json.loads(raw_bytes)
    features = []
    for f in sorted(raw["features"], key=lambda f: f["id"]):
        g = f["geometry"]
        if g["type"] == "LineString":
            geometry = {"type": "LineString", "coordinates": rounded(g["coordinates"])}
        elif g["type"] == "MultiLineString":
            geometry = {"type": "MultiLineString", "coordinates": [rounded(part) for part in g["coordinates"]]}
        else:
            sys.exit(f"unexpected geometry {g['type']} on feature {f['id']}")
        props = {k: f["properties"].get(k) for k in KEEP}
        features.append({"type": "Feature", "id": f["id"], "geometry": geometry, "properties": props})
    doc = {
        "type": "FeatureCollection",
        "name": "park-trails",
        "source": f"NPS Public GIS NationalDatasets NPS_Public_Trails_Geographic, {record['where']}",
        "service": record["service"],
        "fetchedAt": record["fetchedAt"],
        "licence": record["licence"],
        "rawSha256": record["sha256"],
        "processing": "OBJECTID kept as id; coordinates rounded to 6 decimal places; descriptive attributes subset; no joining, snapping or simplification",
        "accuracyNote": "NPS XYACCURACY is mostly Unknown; lines are orientation data, not survey data",
        "features": features,
    }
    data = json.dumps(doc, separators=(",", ":")).encode()
    OUT.write_bytes(data)
    sha = hashlib.sha256(data).hexdigest()
    entry = {"file": OUT.name, "count": len(features), "bytes": len(data), "sha256": sha}

    park = json.loads(PARK_MANIFEST.read_text())
    park["files"] = [f for f in park["files"] if f["file"] != OUT.name] + [dict(entry, fetchedAt=record["fetchedAt"])]
    PARK_MANIFEST.write_text(json.dumps(park, indent=2))
    pack = json.loads(PACK_MANIFEST.read_text())
    pack["geo"] = [g for g in pack["geo"] if g["file"] not in (OUT.name, PARK_MANIFEST.name)]
    pack["geo"].append({"file": OUT.name, "bytes": len(data), "sha256": sha})
    pack["geo"].append({"file": PARK_MANIFEST.name, "bytes": PARK_MANIFEST.stat().st_size, "sha256": hashlib.sha256(PARK_MANIFEST.read_bytes()).hexdigest()})
    PACK_MANIFEST.write_text(json.dumps(pack, separators=(",", ":")))
    print(f"wrote {OUT.relative_to(ROOT)}: {len(features)} features, {len(data):,} bytes (sha256 {sha[:12]}…)")


if __name__ == "__main__":
    main()
