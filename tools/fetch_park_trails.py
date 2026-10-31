#!/usr/bin/env python3 -I
"""Downloads every Yosemite feature of the NPS public trails dataset as GeoJSON data, read-only.

Source: NPS Public GIS NationalDatasets, NPS_Public_Trails_Geographic (US Government work, public domain),
queried with UNITCODE='YOSE' AND ISEXTANT='True', all fields, WGS84, paged by OBJECTID. The response is
data only; nothing downloaded is executed. Output goes to an untracked research directory with a
fetch record (query, time, count, sha256) that tools/build_park_trails.py copies into the bundled pack.

Usage: python3 -I tools/fetch_park_trails.py [research/park-trails]
"""
import hashlib
import json
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SERVICE = "https://mapservices.nps.gov/arcgis/rest/services/NationalDatasets/NPS_Public_Trails_Geographic/FeatureServer/0"
WHERE = "UNITCODE='YOSE' AND ISEXTANT='True'"
PAGE = 500


def get(params):
    url = f"{SERVICE}/query?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "EnveYosemite-data-prep"}), timeout=120) as r:
        return json.loads(r.read())


def main():
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "research" / "park-trails"
    out_dir.mkdir(parents=True, exist_ok=True)
    expected = get({"where": WHERE, "returnCountOnly": "true", "f": "json"})["count"]
    features = []
    offset = 0
    while True:
        page = get({"where": WHERE, "outFields": "*", "outSR": 4326, "orderByFields": "OBJECTID", "resultOffset": offset,
                    "resultRecordCount": PAGE, "f": "geojson"})
        batch = page.get("features", [])
        features += batch
        offset += len(batch)
        if not batch or not page.get("exceededTransferLimit") and len(batch) < PAGE:
            break
    ids = [f["id"] for f in features]
    if len(set(ids)) != len(ids) or len(features) != expected:
        sys.exit(f"incomplete download: {len(features)} features, {len(set(ids))} unique, service reports {expected}")
    raw = json.dumps({"type": "FeatureCollection", "features": features}, separators=(",", ":")).encode()
    (out_dir / "park-trails-raw.geojson").write_bytes(raw)
    record = {
        "service": SERVICE, "where": WHERE, "outFields": "*", "outSR": 4326, "fetchedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "count": len(features), "sha256": hashlib.sha256(raw).hexdigest(),
        "licence": "US Government work, public domain (NPS Public GIS NationalDatasets)",
    }
    (out_dir / "fetch-record.json").write_text(json.dumps(record, indent=1))
    print(f"{len(features)} features → {out_dir / 'park-trails-raw.geojson'} ({len(raw):,} bytes)")


if __name__ == "__main__":
    main()
