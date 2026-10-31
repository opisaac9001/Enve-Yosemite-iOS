"""Minimal ESRI shapefile (.shp + .dbf) reader for the NHD staged products, standard library only.

Reads polyline and polygon records (with or without Z/M) as lists of XY parts, and dBASE attributes
as strings, ints or floats. Files are parsed as data; nothing in them is executed.
"""
import struct

POLYLINE_TYPES = {3, 13, 23}
POLYGON_TYPES = {5, 15, 25}


def read_dbf(data):
    count, header_len, record_len = struct.unpack("<IHH", data[4:12])
    fields = []
    pos = 32
    while data[pos] != 0x0D:
        name = data[pos:pos + 11].split(b"\x00")[0].decode("ascii").lower()
        kind = chr(data[pos + 11])
        length, decimals = data[pos + 16], data[pos + 17]
        fields.append((name, kind, length, decimals))
        pos += 32
    rows = []
    for i in range(count):
        start = header_len + i * record_len
        record = data[start:start + record_len]
        if record[:1] == b"*":
            rows.append(None)
            continue
        offset = 1
        row = {}
        for name, kind, length, decimals in fields:
            raw = record[offset:offset + length].decode("utf-8", errors="replace").strip()
            offset += length
            if kind in "NF" and raw:
                try:
                    row[name] = float(raw) if decimals or kind == "F" or "." in raw else int(raw)
                except ValueError:
                    row[name] = None
            else:
                row[name] = raw or None
        rows.append(row)
    return rows


def read_shp(data):
    """Yields (shape_type, parts) per record in file order; parts are lists of (x, y)."""
    pos = 100
    while pos + 8 <= len(data):
        _, words = struct.unpack(">ii", data[pos:pos + 8])
        content = data[pos + 8:pos + 8 + words * 2]
        pos += 8 + words * 2
        shape_type = struct.unpack("<i", content[:4])[0]
        if shape_type not in POLYLINE_TYPES | POLYGON_TYPES:
            yield shape_type, []
            continue
        num_parts, num_points = struct.unpack("<ii", content[36:44])
        starts = list(struct.unpack(f"<{num_parts}i", content[44:44 + 4 * num_parts]))
        base = 44 + 4 * num_parts
        coords = struct.unpack(f"<{2 * num_points}d", content[base:base + 16 * num_points])
        points = list(zip(coords[0::2], coords[1::2]))
        parts = [points[s:e] for s, e in zip(starts, starts[1:] + [num_points])]
        yield shape_type, parts


def records(shp_bytes, dbf_bytes):
    attributes = read_dbf(dbf_bytes)
    for (shape_type, parts), row in zip(read_shp(shp_bytes), attributes):
        if row is not None and parts:
            yield shape_type, parts, row
