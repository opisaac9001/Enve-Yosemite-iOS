#!/usr/bin/env python3 -I
"""Builds the park-wide elevation grid from the USGS 3D Elevation Program (3DEP) bare-earth DEM.

Source: USGS 3DEP Elevation ImageServer (The National Map), public domain U.S. Government data,
https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer
(catalog: https://data.usgs.gov/datacatalog/data/USGS%3A3a81321b-c153-416f-98b7-cc8e5f0e17c3).
The service resamples its best available 3DEP source (bilinear) onto the regular WGS84 grid requested
here, in chunks of at most CHUNK samples per side, returned as uncompressed float32 GeoTIFFs. The
responses are parsed as data with the standard library; nothing downloaded is executed.

Grids (sample centres on both edges; each request's bbox is widened by half a cell so ArcGIS pixel
centres fall exactly on the samples). The service only returns square pixels in the requested spatial
reference, widening the bbox otherwise, so cells are square in degrees, and every chunk's GeoTIFF
tiepoint and pixel scale are checked against the request:
  park      YosemiteGeo.parkBounds (−120.05…−119.05 E, 37.37…38.30 N), 1/3200° (≈27.5 m E–W × 34.7 m N–S), 3201 × 2977
  surround  −121.1…−118.6 E, 36.9…38.75 N, 1/400° (≈220 × 278 m), 1001 × 741
  outer     −123.2…−115.9 E, 35.45…40.2 N, 1/120° (≈730 × 925 m), 877 × 571. Sized for the map's zoom floor:
            ±317 km E–W and ±261 km N–S of the camera clamp's centre, which holds a landscape phone fitting
            the park between about 240 pt of chrome and a 320 pt-wide iPad split view. The service reports
            near-shore Pacific and the bays as 0 m (flat sea-level ground, no coastline drawn); open ocean
            beyond 3DEP coverage has no value and is stored as `noDataUnits`, which the app draws transparent.
            Only this tier may contain gaps.

Output (bundled): elevation-<tier>.json (header and provenance) and elevation-<tier>.bin: elevations
above `offsetMeters` (0 unless the tier dips below sea level, as the outer tier does at Death Valley) in
0.25 m units, each stored as an unsigned 16-bit little-endian residual from the planar prediction
left + above − above-left (left only on row 0, above only in column 0), wrapping modulo 2^16; the
stream is raw-DEFLATE compressed (Foundation's `.zlib` algorithm). 0.25 m is well inside 3DEP's own
vertical accuracy and saves about a fifth of the size of decimetres.

Usage: python3 -I tools/prepare_park_relief.py --tier park      [--cache research/park-dem]
       python3 -I tools/prepare_park_relief.py --tier surround  [--cache research/park-dem-surround]
       python3 -I tools/prepare_park_relief.py --tier outer     [--cache research/park-dem-outer]
"""
import argparse
import datetime as dt
import hashlib
import json
import math
import struct
import sys
import time
import urllib.parse
import urllib.request
import zlib
from array import array
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GEO = ROOT / "ios" / "PettyFieldGuide" / "Resources" / "Geo"
PARK_MANIFEST = GEO / "park-manifest.json"
PACK_MANIFEST = ROOT / "ios" / "PettyFieldGuide" / "Resources" / "Content" / "pack-manifest.json"
SERVICE = "https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer"
CATALOG = "https://data.usgs.gov/datacatalog/data/USGS%3A3a81321b-c153-416f-98b7-cc8e5f0e17c3"
TIERS = {
    # Every sample of YosemiteGeo.parkBounds at ≈30 m.
    "park": {"bounds": (-120.05, -119.05, 37.37, 38.30), "per_degree": 3200, "out": "elevation-park.json",
             "purpose": "Park-wide shaded relief, elevation tint, contours and park hike profiles; the Valley's 20 m detail tier draws on top of it"},
    # Coarse context around the park for zoomed-out views on tall or wide screens; the park tier draws on top of it.
    "surround": {"bounds": (-121.1, -118.6, 36.9, 38.75), "per_degree": 400, "out": "elevation-surround.json",
                 "purpose": "Coarse relief around the park for regional zooms near the park edge; the park tier draws on top of it"},
    # Far context for the map's zoom floor on every supported phone and iPad layout; the surround draws on top of it.
    "outer": {"bounds": (-123.2, -115.9, 35.45, 40.2), "per_degree": 120, "out": "elevation-outer.json", "gaps": True,
              "purpose": "Far terrain context so the map's most zoomed-out view on any supported layout stays on relief; the surround tier draws on top of it. Open water reads 0 m"},
}
WEST = EAST = SOUTH = NORTH = 0.0
COLS_PER_DEGREE = ROWS_PER_DEGREE = 1
CHUNK = 1024
VERTICAL_SCALE = 0.25
NO_DATA_UNITS = 0xFFFF
NO_DATA = -9999.0


def grid_shape():
    return round((EAST - WEST) * COLS_PER_DEGREE) + 1, round((NORTH - SOUTH) * ROWS_PER_DEGREE) + 1


def chunk_request(c0, r0, cols, rows):
    dx, dy = 1 / COLS_PER_DEGREE, 1 / ROWS_PER_DEGREE
    west = WEST + c0 * dx - dx / 2
    north = NORTH - r0 * dy + dy / 2
    east = west + cols * dx
    south = north - rows * dy
    params = {
        "bbox": f"{west:.9f},{south:.9f},{east:.9f},{north:.9f}", "bboxSR": 4326, "imageSR": 4326,
        "size": f"{cols},{rows}", "format": "tiff", "pixelType": "F32", "noData": NO_DATA,
        "noDataInterpretation": "esriNoDataMatchAny", "interpolation": "RSP_BilinearInterpolation",
        "compression": "None", "f": "image",
    }
    return f"{SERVICE}/exportImage?{urllib.parse.urlencode(params)}"


def parse_tiff_f32(data):
    """Single-band float32 TIFF (strips or tiles, uncompressed or Deflate without predictor) → (w, h, array('f'), georeference).
    A sparse tile (offset and byte count 0, written for areas with no source data) reads as NO_DATA; any other
    block of the wrong size is an error rather than a silently shorter grid."""
    endian = {b"II": "<", b"MM": ">"}[data[:2]]
    if struct.unpack(endian + "H", data[2:4])[0] != 42:
        raise ValueError("not a classic TIFF")
    ifd = struct.unpack(endian + "I", data[4:8])[0]
    count = struct.unpack(endian + "H", data[ifd:ifd + 2])[0]
    sizes = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 11: 4, 12: 8, 16: 8}
    codes = {1: "B", 2: "c", 3: "H", 4: "I", 7: "B", 11: "f", 12: "d", 16: "Q"}
    tags = {}
    for i in range(count):
        tag, kind, n, value = struct.unpack(endian + "HHI4s", data[ifd + 2 + i * 12: ifd + 14 + i * 12])
        size = sizes.get(kind, 1) * n
        raw = value[:size] if size <= 4 else data[struct.unpack(endian + "I", value)[0]:][:size]
        tags[tag] = list(struct.unpack(endian + codes.get(kind, "B") * n, raw)) if kind in codes and kind != 2 else raw
    width, height = tags[256][0], tags[257][0]
    scale, tiepoint = tags.get(33550), tags.get(33922)
    if tags.get(258, [32])[0] != 32 or tags.get(339, [3])[0] != 3 or tags.get(277, [1])[0] != 1:
        raise ValueError("expected one float32 band")
    compression = tags.get(259, [1])[0]
    if tags.get(317, [1])[0] != 1 or compression not in (1, 8, 32946):
        raise ValueError(f"unsupported compression {compression} / predictor {tags.get(317)}")

    def block(offset, length, samples):
        if offset == 0 and length == 0:
            return array("f", [NO_DATA]) * samples
        raw = data[offset:offset + length]
        values = array("f")
        values.frombytes(zlib.decompress(raw) if compression != 1 else raw)
        if (endian == "<") != (sys.byteorder == "little"):
            values.byteswap()
        if len(values) != samples:
            raise ValueError(f"block at {offset} holds {len(values)} samples, expected {samples}")
        return values

    out = array("f", bytes(4 * width * height))
    if 324 in tags:
        tw, th = tags[322][0], tags[323][0]
        across = (width + tw - 1) // tw
        for index, (offset, length) in enumerate(zip(tags[324], tags[325])):
            values = block(offset, length, tw * th)
            tx, ty = index % across * tw, index // across * th
            for r in range(min(th, height - ty)):
                n = min(tw, width - tx)
                out[(ty + r) * width + tx:(ty + r) * width + tx + n] = values[r * tw:r * tw + n]
    else:
        rows_per_strip = tags.get(278, [height])[0]
        for index, (offset, length) in enumerate(zip(tags[273], tags[279])):
            start = index * rows_per_strip * width
            values = block(offset, length, min(rows_per_strip * width, len(out) - start))
            out[start:start + len(values)] = values
    return width, height, out, (tiepoint[3], tiepoint[4], scale[0], scale[1]) if scale and tiepoint else None


def check_georeference(georef, c0, r0):
    """The chunk's top-left corner and pixel size must be exactly what was asked for."""
    dx, dy = 1 / COLS_PER_DEGREE, 1 / ROWS_PER_DEGREE
    expected = (WEST + c0 * dx - dx / 2, NORTH - r0 * dy + dy / 2, dx, dy)
    if georef is None or any(abs(a - b) > 1e-7 for a, b in zip(georef, expected)):
        raise ValueError(f"georeference {georef} differs from the requested {expected}")


def fetch(cache):
    cache.mkdir(parents=True, exist_ok=True)
    width, height = grid_shape()
    chunks = []
    for r0 in range(0, height, CHUNK):
        for c0 in range(0, width, CHUNK):
            cols, rows = min(CHUNK, width - c0), min(CHUNK, height - r0)
            path = cache / f"r{r0:05d}-c{c0:05d}.tif"
            url = chunk_request(c0, r0, cols, rows)
            if not path.exists():
                for attempt in range(4):
                    try:
                        req = urllib.request.Request(url, headers={"User-Agent": "EnveYosemite-data-prep"})
                        with urllib.request.urlopen(req, timeout=300) as response:
                            body = response.read()
                        check_georeference(parse_tiff_f32(body)[3], c0, r0)
                        path.write_bytes(body)
                        break
                    except Exception as error:  # network or a non-TIFF error response; retried, then fatal
                        if attempt == 3:
                            sys.exit(f"chunk {path.name} failed: {error}")
                        time.sleep(5 * (attempt + 1))
                print(f"  fetched {path.name} ({path.stat().st_size:,} bytes)")
            chunks.append({"file": path.name, "row": r0, "col": c0, "rows": rows, "cols": cols, "url": url,
                           "bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    record_path = cache / "fetch-record.json"
    if not record_path.exists():
        record_path.write_text(json.dumps({"service": SERVICE, "fetchedAt": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                           "chunks": chunks}, indent=1))
    return json.loads(record_path.read_text())


def assemble(cache, record):
    width, height = grid_shape()
    grid = array("f", bytes(4 * width * height))
    for chunk in record["chunks"]:
        data = (cache / chunk["file"]).read_bytes()
        if hashlib.sha256(data).hexdigest() != chunk["sha256"]:
            sys.exit(f"{chunk['file']} does not match its fetch record")
        w, h, values, georef = parse_tiff_f32(data)
        check_georeference(georef, chunk["col"], chunk["row"])
        if (w, h) != (chunk["cols"], chunk["rows"]) or len(values) != w * h:
            sys.exit(f"{chunk['file']}: {w}×{h}, expected {chunk['cols']}×{chunk['rows']}")
        for r in range(h):
            dst = (chunk["row"] + r) * width + chunk["col"]
            grid[dst:dst + w] = values[r * w:(r + 1) * w]
    return width, height, grid


def register(paths, fetched_at):
    """Records the header and data files in park-manifest.json and the in-app pack check."""
    entries = [{"file": p.name, "bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in paths]
    names = {e["file"] for e in entries}
    park = json.loads(PARK_MANIFEST.read_text())
    park["files"] = [f for f in park["files"] if f["file"] not in names] + [dict(e, fetchedAt=fetched_at) for e in entries]
    PARK_MANIFEST.write_text(json.dumps(park, indent=2))
    pack = json.loads(PACK_MANIFEST.read_text())
    pack["geo"] = [g for g in pack["geo"] if g["file"] not in names | {PARK_MANIFEST.name}] + entries
    pack["geo"].append({"file": PARK_MANIFEST.name, "bytes": PARK_MANIFEST.stat().st_size, "sha256": hashlib.sha256(PARK_MANIFEST.read_bytes()).hexdigest()})
    PACK_MANIFEST.write_text(json.dumps(pack, separators=(",", ":")))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tier", choices=sorted(TIERS), default="park")
    parser.add_argument("--cache", type=Path)
    args = parser.parse_args()
    tier = TIERS[args.tier]
    global WEST, EAST, SOUTH, NORTH, COLS_PER_DEGREE, ROWS_PER_DEGREE
    WEST, EAST, SOUTH, NORTH = tier["bounds"]
    COLS_PER_DEGREE = ROWS_PER_DEGREE = tier["per_degree"]
    cache = args.cache or ROOT / "research" / ("park-dem" if args.tier == "park" else f"park-dem-{args.tier}")
    out = GEO / tier["out"]
    record = fetch(cache)
    width, height, grid = assemble(cache, record)
    def is_missing(v):
        return v <= NO_DATA + 1 or v != v
    missing = sum(1 for v in grid if is_missing(v))
    if missing and not tier.get("gaps"):
        sys.exit(f"{missing} samples have no 3DEP value; refusing to fill them")
    present = [v for v in grid if not is_missing(v)]
    lo, hi = min(present), max(present)
    offset = math.floor(min(0.0, lo))
    if (hi - offset) / VERTICAL_SCALE >= NO_DATA_UNITS:
        sys.exit(f"elevation range {lo}…{hi} m does not fit the unsigned 16-bit units")

    units = array("i", (NO_DATA_UNITS if is_missing(v) else int((v - offset) / VERTICAL_SCALE + 0.5) for v in grid))
    encoded = array("H", bytes(2 * width * height))
    for row in range(height):
        base = row * width
        for col in range(width):
            i = base + col
            if row == 0:
                prediction = units[i - 1] if col else 0
            elif col == 0:
                prediction = units[i - width]
            else:
                prediction = units[i - 1] + units[i - width] - units[i - width - 1]
            encoded[i] = (units[i] - prediction) & 0xFFFF
    if sys.byteorder != "little":
        encoded.byteswap()
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    payload = compressor.compress(encoded.tobytes()) + compressor.flush()

    bin_path = out.with_suffix(".bin")
    bin_path.write_bytes(payload)
    lat_mid = (NORTH + SOUTH) / 2
    m_lat = 111132.954 - 559.822 * math.cos(2 * math.radians(lat_mid)) + 1.175 * math.cos(4 * math.radians(lat_mid))
    m_lon = math.pi / 180 * 6378137 * math.cos(math.radians(lat_mid))
    header = {
        "version": hashlib.sha256(payload).hexdigest()[:12],
        "source": "USGS 3D Elevation Program (3DEP) bare-earth DEM via The National Map 3DEPElevation ImageServer",
        "sourceUrl": SERVICE,
        "catalog": CATALOG,
        "licence": "Public domain (U.S. Government work, USGS); credit: U.S. Geological Survey, 3D Elevation Program",
        "fetchedAt": record["fetchedAt"],
        "purpose": tier["purpose"],
        "processing": f"exportImage in {len(record['chunks'])} chunks, bilinear resampling by the service onto sample centres; rounded to 0.25 m; planar-prediction residuals, raw DEFLATE",
        "bounds": {"north": NORTH, "south": SOUTH, "west": WEST, "east": EAST},
        "width": width, "height": height,
        "encoding": "uint16-le-planar-deflate",
        "dataFile": bin_path.name,
        "verticalScale": VERTICAL_SCALE,
        **({"offsetMeters": offset} if offset else {}),
        **({"noDataUnits": NO_DATA_UNITS, "missingSamples": missing} if missing else {}),
        "cellSizeMeters": {"x": round(m_lon / COLS_PER_DEGREE, 2), "y": round(m_lat / ROWS_PER_DEGREE, 2)},
        "rangeMeters": {"min": round(lo, 1), "max": round(hi, 1)},
        "dataSha256": hashlib.sha256(payload).hexdigest(),
    }
    out.write_text(json.dumps(header, indent=1))
    register([out, bin_path], record["fetchedAt"])
    print(f"{width}×{height} samples, {lo:.1f}–{hi:.1f} m → {out.name} + {bin_path.name} ({len(payload):,} bytes)")


if __name__ == "__main__":
    main()
