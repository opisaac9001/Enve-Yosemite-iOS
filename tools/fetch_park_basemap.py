#!/usr/bin/env python3 -I
"""Downloads the park-wide NPS layers for the continuous map as GeoJSON data, read-only.

Source: NPS Public GIS NationalDatasets (US Government works, public domain), the same `_Geographic`
services and filters as the bundled Valley packs (see map-manifest.json), queried for all of Yosemite
(UNITCODE='YOSE') instead of the Valley envelope: roads and buildings (ISEXTANT='True'), parking lots
and points of interest. All fields, WGS84, paged by OBJECTID. Nothing downloaded is executed. Output
goes to an untracked research directory with a fetch record (query, time, count, sha256) per layer
that tools/build_park_basemap.py copies into the bundled packs.

Usage: python3 -I tools/fetch_park_basemap.py [research/park-basemap]
"""
import hashlib
import json
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ROOT_URL = "https://mapservices.nps.gov/arcgis/rest/services/NationalDatasets/"
LAYERS = {
    "roads": ("NPS_Public_Roads_Geographic", "UNITCODE='YOSE' AND ISEXTANT='True'"),
    "buildings": ("NPS_Public_Buildings_Geographic", "UNITCODE='YOSE' AND ISEXTANT='True'"),
    "parking": ("NPS_Public_ParkingLots_Geographic", "UNITCODE='YOSE'"),
    "pois": ("NPS_Public_POIs_Geographic", "UNITCODE='YOSE'"),
}
PAGE = 1000


def get(service, params):
    url = f"{ROOT_URL}{service}/FeatureServer/0/query?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "EnveYosemite-data-prep"}), timeout=180) as r:
        return json.loads(r.read())


def fetch(name, service, where, out_dir):
    expected = get(service, {"where": where, "returnCountOnly": "true", "f": "json"})["count"]
    features, offset = [], 0
    while True:
        page = get(service, {"where": where, "outFields": "*", "outSR": 4326, "orderByFields": "OBJECTID",
                             "resultOffset": offset, "resultRecordCount": PAGE, "f": "geojson"})
        batch = page.get("features", [])
        features += batch
        offset += len(batch)
        if not batch or not page.get("exceededTransferLimit") and len(batch) < PAGE:
            break
    ids = [f["id"] for f in features]
    if len(set(ids)) != len(ids) or len(features) != expected:
        sys.exit(f"{name}: incomplete download, {len(features)} features, {len(set(ids))} unique, service reports {expected}")
    raw = json.dumps({"type": "FeatureCollection", "features": features}, separators=(",", ":")).encode()
    (out_dir / f"{name}-raw.geojson").write_bytes(raw)
    print(f"{name}: {len(features)} features ({len(raw):,} bytes)")
    return {"service": f"{ROOT_URL}{service}/FeatureServer/0", "where": where, "outFields": "*", "outSR": 4326,
            "fetchedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "count": len(features),
            "sha256": hashlib.sha256(raw).hexdigest()}


def main():
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "research" / "park-basemap"
    out_dir.mkdir(parents=True, exist_ok=True)
    record = {name: fetch(name, service, where, out_dir) for name, (service, where) in LAYERS.items()}
    record["licence"] = "US Government works, public domain (NPS Public GIS NationalDatasets)"
    (out_dir / "fetch-record.json").write_text(json.dumps(record, indent=1))


if __name__ == "__main__":
    main()
