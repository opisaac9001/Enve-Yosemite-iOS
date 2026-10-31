#!/usr/bin/env python3
"""Build a compact relief grid from public Mapzen/Tilezen Terrarium tiles.

Downloads the Terrarium tiles covering the requested bounds from the AWS Open Data bucket
(public, no account), decodes them with the standard library only, resamples the Web Mercator
pixels onto a regular WGS84 latitude/longitude grid and writes the same `uint16-le-base64` JSON
layout as `elevation-valley.json`, with full provenance.

One tier is shipped from this tool, the 20 m Valley detail (the park and surround tiers come from USGS
3DEP through tools/prepare_park_relief.py):
  python3 -I tools/prepare_basemap_terrain.py --cache /tmp/petty-field-guide-terrain-tiles \
      --out ios/PettyFieldGuide/Resources/Geo/elevation-basemap.json --zoom 13 --cell 20

The cache directory holds the raw tiles (untracked). Only the derived grids are bundled.
The sun/shadow grid (`elevation-valley.json`) is a separate asset and is not touched.
"""
import argparse
import base64
import datetime as dt
import hashlib
import json
import math
import struct
import sys
import time
import urllib.request
import zlib
from array import array
from pathlib import Path

TILE_TEMPLATE = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
REGISTRY = "https://registry.opendata.aws/terrain-tiles/"
ATTRIBUTION_DOC = "https://github.com/tilezen/joerd/blob/master/docs/attribution.md"
VERTICAL_SCALE = 0.1
MAX_DOWNLOAD_BYTES = 25 * 1024 * 1024

# Valley map extent (YosemiteGeo.valleyBounds) plus 0.04° on every side.
DEFAULT_BOUNDS = {"west": -119.76, "south": 37.65, "east": -119.49, "north": 37.82}


def mercator_pixel(lat, lon, zoom):
    n = 256 * (1 << zoom)
    x = (lon + 180.0) / 360.0 * n
    lat_r = math.radians(lat)
    y = (1.0 - math.log(math.tan(lat_r) + 1.0 / math.cos(lat_r)) / math.pi) / 2.0 * n
    return x, y


def decode_png(data):
    """8-bit RGB/RGBA non-interlaced PNG → (width, height, channels, bytes)."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos = 8
    width = height = channels = None
    idat = bytearray()
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or interlace != 0 or color not in (2, 6):
                raise ValueError(f"unsupported PNG layout depth={depth} color={color} interlace={interlace}")
            channels = 3 if color == 2 else 4
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    out = bytearray(stride * height)
    prev = bytearray(stride)
    offset = 0
    for row in range(height):
        filter_type = raw[offset]
        line = bytearray(raw[offset + 1:offset + 1 + stride])
        offset += 1 + stride
        if filter_type == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filter_type == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif filter_type == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif filter_type == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        elif filter_type != 0:
            raise ValueError(f"bad PNG filter {filter_type}")
        out[row * stride:(row + 1) * stride] = line
        prev = line
    return width, height, channels, bytes(out)


def terrarium_elevations(png_bytes):
    width, height, channels, pixels = decode_png(png_bytes)
    if width != 256 or height != 256:
        raise ValueError("terrarium tiles are 256×256")
    values = array("f", bytes(4 * 256 * 256))
    for i in range(256 * 256):
        r, g, b = pixels[i * channels], pixels[i * channels + 1], pixels[i * channels + 2]
        values[i] = (r * 256.0 + g + b / 256.0) - 32768.0
    return values


def fetch_tile(cache, z, x, y):
    path = cache / f"{z}-{x}-{y}.png"
    if path.exists():
        return path.read_bytes(), False
    url = TILE_TEMPLATE.format(z=z, x=x, y=y)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=60) as resp:
                data = resp.read()
            path.write_bytes(data)
            return data, True
        except Exception as error:  # noqa: BLE001 - retry transient network failures
            if attempt == 3:
                raise
            time.sleep(2 * (attempt + 1))
            print(f"retry {url}: {error}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cache", type=Path, required=True, help="directory for raw tile downloads (untracked)")
    parser.add_argument("--out", type=Path, required=True, help="output JSON grid")
    parser.add_argument("--zoom", type=int, default=13)
    parser.add_argument("--cell", type=float, default=20.0, help="target grid spacing in metres")
    parser.add_argument("--purpose", default="Detail relief for the Valley map. The sun/shadow preview keeps its own smaller grid (elevation-valley.json).")
    for key, value in DEFAULT_BOUNDS.items():
        parser.add_argument(f"--{key}", type=float, default=value)
    args = parser.parse_args()
    bounds = {k: getattr(args, k) for k in DEFAULT_BOUNDS}
    zoom = args.zoom
    args.cache.mkdir(parents=True, exist_ok=True)

    x0, y0 = mercator_pixel(bounds["north"], bounds["west"], zoom)
    x1, y1 = mercator_pixel(bounds["south"], bounds["east"], zoom)
    tx0, tx1 = int(x0 // 256), int(x1 // 256)
    ty0, ty1 = int(y0 // 256), int(y1 // 256)
    tiles_x, tiles_y = tx1 - tx0 + 1, ty1 - ty0 + 1
    mosaic_w, mosaic_h = tiles_x * 256, tiles_y * 256
    mosaic = array("f", bytes(4 * mosaic_w * mosaic_h))

    tile_records = []
    downloaded = 0
    for ty in range(ty0, ty1 + 1):
        for tx in range(tx0, tx1 + 1):
            data, fresh = fetch_tile(args.cache, zoom, tx, ty)
            downloaded += len(data) if fresh else 0
            if downloaded > MAX_DOWNLOAD_BYTES:
                sys.exit("download budget exceeded")
            tile_records.append({"z": zoom, "x": tx, "y": ty, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
            values = terrarium_elevations(data)
            ox, oy = (tx - tx0) * 256, (ty - ty0) * 256
            for row in range(256):
                start = (oy + row) * mosaic_w + ox
                mosaic[start:start + 256] = values[row * 256:(row + 1) * 256]
            print(f"tile {zoom}/{tx}/{ty} {'fetched' if fresh else 'cached'} {len(data):,} bytes", file=sys.stderr)

    mid_lat = (bounds["north"] + bounds["south"]) / 2
    m_per_deg_lat = 111_132.954 - 559.822 * math.cos(math.radians(2 * mid_lat)) + 1.175 * math.cos(math.radians(4 * mid_lat))
    m_per_deg_lon = math.radians(1) * 6_378_137 * math.cos(math.radians(mid_lat))
    span_x = (bounds["east"] - bounds["west"]) * m_per_deg_lon
    span_y = (bounds["north"] - bounds["south"]) * m_per_deg_lat
    # Samples sit on both edges, so spacing is span / (count - 1), matching TerrainGrid.coordinate(col:row:).
    width = max(2, round(span_x / args.cell) + 1)
    height = max(2, round(span_y / args.cell) + 1)

    out = array("H", bytes(2 * width * height))
    lo, hi = math.inf, -math.inf
    base_x, base_y = tx0 * 256, ty0 * 256
    for row in range(height):
        lat = bounds["north"] - (row / (height - 1)) * (bounds["north"] - bounds["south"])
        for col in range(width):
            lon = bounds["west"] + (col / (width - 1)) * (bounds["east"] - bounds["west"])
            px, py = mercator_pixel(lat, lon, zoom)
            fx, fy = px - base_x - 0.5, py - base_y - 0.5
            ix, iy = int(math.floor(fx)), int(math.floor(fy))
            tx_, ty_ = fx - ix, fy - iy
            ix = min(max(ix, 0), mosaic_w - 2)
            iy = min(max(iy, 0), mosaic_h - 2)
            a = mosaic[iy * mosaic_w + ix]
            b = mosaic[iy * mosaic_w + ix + 1]
            c = mosaic[(iy + 1) * mosaic_w + ix]
            d = mosaic[(iy + 1) * mosaic_w + ix + 1]
            value = (a * (1 - tx_) + b * tx_) * (1 - ty_) + (c * (1 - tx_) + d * tx_) * ty_
            lo, hi = min(lo, value), max(hi, value)
            out[row * width + col] = min(65535, max(0, int(round(value / VERTICAL_SCALE))))

    if sys.byteorder != "little":
        out.byteswap()
    payload = out.tobytes()
    document = {
        "version": hashlib.sha256(payload).hexdigest()[:12],
        "purpose": args.purpose,
        "source": f"Mapzen/Tilezen Terrarium terrain tiles on AWS Open Data, zoom {zoom}; US coverage derived from USGS 3DEP/NED",
        "attribution": "Terrain tiles: Mapzen (Tilezen Joerd) via AWS Open Data; elevation data from USGS 3DEP/NED and the other sources listed in the Joerd attribution document",
        "attributionDocument": ATTRIBUTION_DOC,
        "registry": REGISTRY,
        "tileTemplate": TILE_TEMPLATE,
        "zoom": zoom,
        "fetchedAt": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
        "bounds": {"north": bounds["north"], "south": bounds["south"], "west": bounds["west"], "east": bounds["east"]},
        "width": width,
        "height": height,
        "encoding": "uint16-le-base64",
        "verticalScale": VERTICAL_SCALE,
        "cellSizeMeters": {"x": span_x / (width - 1), "y": span_y / (height - 1)},
        "rangeMeters": {"min": round(lo, 1), "max": round(hi, 1)},
        "resampling": "Bilinear from Web Mercator Terrarium pixels onto a regular WGS84 latitude/longitude grid with samples on both edges; row 0 is the north edge. Positional accuracy is that of the source tiles; no survey claim is made.",
        "tiles": tile_records,
        "data": base64.b64encode(payload).decode("ascii"),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(document, separators=(",", ":")))
    size = args.out.stat().st_size
    print(f"wrote {args.out} {width}×{height} cells, {size:,} bytes, elevation {lo:.1f}–{hi:.1f} m, "
          f"{len(tile_records)} tiles ({sum(t['bytes'] for t in tile_records):,} bytes, {downloaded:,} newly downloaded)", file=sys.stderr)


if __name__ == "__main__":
    main()
