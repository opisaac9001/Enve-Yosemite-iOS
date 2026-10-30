#!/usr/bin/env python3
"""Render a quick PNG preview of the basemap relief shading (same lighting model as ReliefRenderer.swift).

Development aid only: lets the hillshade orientation and tints be checked without the simulator.

  python3 -I tools/preview_relief.py ios/PettyFieldGuide/Resources/Geo/elevation-basemap.json build/relief-light.png --step 3
"""
import argparse
import base64
import json
import math
import struct
import zlib
from pathlib import Path

LIGHTS = [(315, 45, 0.55), (270, 40, 0.25), (0, 40, 0.20)]
PALETTES = {
    "light": ((0.90, 0.88, 0.81), (0.76, 0.77, 0.78), 0.58, 1.14),
    "dark": ((0.125, 0.145, 0.165), (0.27, 0.285, 0.30), 0.45, 1.55),
}


def write_png(path, width, height, rgb):
    raw = bytearray()
    for row in range(height):
        raw.append(0)
        raw += rgb[row * width * 3:(row + 1) * width * 3]
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b"")
    Path(path).write_bytes(png)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("grid")
    parser.add_argument("out")
    parser.add_argument("--step", type=int, default=3)
    parser.add_argument("--palette", choices=PALETTES.keys(), default="light")
    args = parser.parse_args()
    doc = json.loads(Path(args.grid).read_text())
    w, h, step = doc["width"], doc["height"], args.step
    data = struct.unpack("<%dH" % (w * h), base64.b64decode(doc["data"]))
    scale = doc["verticalScale"]
    cw, ch = (w + step - 1) // step, (h + step - 1) // step
    cx, cy = doc["cellSizeMeters"]["x"] * step * 8, doc["cellSizeMeters"]["y"] * step * 8

    def e(c, r):
        c = min(max(c, 0), cw - 1) * step
        r = min(max(r, 0), ch - 1) * step
        return data[r * w + c] * scale

    lights = []
    for az, alt, wgt in LIGHTS:
        a, b = math.radians(az), math.radians(alt)
        lights.append((math.cos(b) * math.sin(a), math.cos(b) * math.cos(a), math.sin(b), wgt))
    flat = sum(l[2] * l[3] for l in lights)
    low, high, shadow_f, light_f = PALETTES[args.palette]
    lo = max(doc["rangeMeters"]["min"], 1000)
    hi = max(lo + 100, min(doc["rangeMeters"]["max"], 2900))
    out = bytearray(cw * ch * 3)
    for r in range(ch):
        for c in range(cw):
            a, b, cc = e(c - 1, r - 1), e(c, r - 1), e(c + 1, r - 1)
            d, f = e(c - 1, r), e(c + 1, r)
            g, hh, i = e(c - 1, r + 1), e(c, r + 1), e(c + 1, r + 1)
            dzdx = ((cc + 2 * f + i) - (a + 2 * d + g)) / cx
            dzdy = ((g + 2 * hh + i) - (a + 2 * b + cc)) / cy
            nx, ny, nz = -dzdx, dzdy, 1.0
            ln = math.sqrt(nx * nx + ny * ny + 1)
            illum = sum(max(0.0, (nx * lx + ny * ly + nz * lz) / ln) * wgt for lx, ly, lz, wgt in lights)
            v = illum / flat * 0.5
            v = 0.5 + (v - 0.5) * 1.35
            slope = min(1.73, math.sqrt(dzdx * dzdx + dzdy * dzdy)) / 1.73
            v = min(1.0, max(0.0, v - slope * 0.10))
            t = min(1.0, max(0.0, (e(c, r) - lo) / (hi - lo))) ** 0.85
            factor = shadow_f + (1 - shadow_f) * (v / 0.5) if v < 0.5 else 1 + (light_f - 1) * ((v - 0.5) / 0.5)
            o = (r * cw + c) * 3
            for k in range(3):
                out[o + k] = int(min(255, max(0, (low[k] + (high[k] - low[k]) * t) * factor * 255)))
    write_png(args.out, cw, ch, out)
    print(f"wrote {args.out} {cw}×{ch}")


if __name__ == "__main__":
    main()
