import Foundation
import CoreGraphics
import CoreLocation

/// A bundled elevation grid (metres); samples sit on both edges, row 0 is north.
struct TerrainGrid: Sendable {
    static let sunFile = "elevation-valley.json"        // 320×152 crop the sun preview marches
    static let basemapFile = "elevation-basemap.json"   // 20 m detail relief over the Valley extent
    static let parkFile = "elevation-park.json"         // ≈30 m USGS 3DEP over parkBounds: park relief, contours and park hike profiles
    static let surroundFile = "elevation-surround.json" // ≈250 m USGS 3DEP context around the park for regional zooms near its edge
    static let outerFile = "elevation-outer.json"       // ≈800 m USGS 3DEP far context for the map's zoom floor; open-ocean gaps are NaN

    let width: Int
    let height: Int
    let bounds: GeoBounds
    let cellSizeMeters: (x: Double, y: Double)
    let minElevation: Double
    let maxElevation: Double
    let elevations: [Float]      // row-major, row 0 = north edge; NaN where the source has no value
    let source: String
    let fetchedAt: String

    private struct Raw: Decodable {
        struct Bounds: Decodable { var north: Double; var south: Double; var west: Double; var east: Double }
        struct Cell: Decodable { var x: Double; var y: Double }
        struct Range: Decodable { var min: Double; var max: Double }
        var version: String
        var source: String
        var fetchedAt: String
        var bounds: Bounds
        var width: Int
        var height: Int
        var encoding: String
        var verticalScale: Double
        var cellSizeMeters: Cell
        var rangeMeters: Range
        var data: String?
        var dataFile: String?
        var offsetMeters: Double?
        var noDataUnits: Int?
    }

    static func load(file: String = sunFile) throws -> TerrainGrid {
        let raw = try JSONDecoder().decode(Raw.self, from: BundleContent.data(file, subdirectory: "Geo"))
        let count = raw.width * raw.height
        let values: [Float]
        switch raw.encoding {
        case "uint16-le-base64":
            guard let bytes = raw.data.flatMap({ Data(base64Encoded: $0) }), bytes.count == count * 2 else { throw CocoaError(.fileReadCorruptFile) }
            values = bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                (0..<count).map { i -> Float in
                    let lo = UInt16(buffer[i * 2]), hi = UInt16(buffer[i * 2 + 1])
                    return Float(Double(lo | hi << 8) * raw.verticalScale)
                }
            }
        case "uint16-le-planar-deflate":
            guard let name = raw.dataFile else { throw CocoaError(.fileReadCorruptFile) }
            let packed = try BundleContent.data(name, subdirectory: "Geo")
            let bytes = try (packed as NSData).decompressed(using: .zlib) as Data
            guard bytes.count == count * 2 else { throw CocoaError(.fileReadCorruptFile) }
            values = Self.planarDecode(bytes, width: raw.width, height: raw.height, scale: Float(raw.verticalScale),
                                       offset: Float(raw.offsetMeters ?? 0), noData: raw.noDataUnits.map(Int32.init))
        default:
            throw CocoaError(.fileReadCorruptFile)
        }
        return TerrainGrid(width: raw.width, height: raw.height,
                           bounds: GeoBounds(west: raw.bounds.west, south: raw.bounds.south, east: raw.bounds.east, north: raw.bounds.north),
                           cellSizeMeters: (raw.cellSizeMeters.x, raw.cellSizeMeters.y),
                           minElevation: raw.rangeMeters.min, maxElevation: raw.rangeMeters.max,
                           elevations: values, source: raw.source, fetchedAt: raw.fetchedAt)
    }

    /// Inverts tools/prepare_park_relief.py: each sample is its 16-bit residual plus left + above − above-left, modulo 2^16,
    /// in `scale` metres above `offset`; the `noData` unit value decodes to NaN.
    static func planarDecode(_ bytes: Data, width: Int, height: Int, scale: Float, offset: Float = 0, noData: Int32? = nil) -> [Float] {
        let noData = noData ?? -1
        var values = [Float](repeating: 0, count: width * height)
        var rows = [Int32](repeating: 0, count: 2 * width)
        bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            values.withUnsafeMutableBufferPointer { out in
                rows.withUnsafeMutableBufferPointer { rows in
                    var above = rows.baseAddress!, current = rows.baseAddress! + width
                    for row in 0..<height {
                        let base = row * width
                        @inline(__always) func residual(_ col: Int) -> Int32 { Int32(buffer[(base + col) * 2]) | Int32(buffer[(base + col) * 2 + 1]) << 8 }
                        current[0] = ((row == 0 ? 0 : above[0]) + residual(0)) & 0xFFFF
                        out[base] = current[0] == noData ? .nan : Float(current[0]) * scale + offset
                        if width > 1 {
                            for col in 1..<width {
                                let prediction = row == 0 ? current[col - 1] : current[col - 1] + above[col] - above[col - 1]
                                current[col] = (prediction + residual(col)) & 0xFFFF
                                out[base + col] = current[col] == noData ? .nan : Float(current[col]) * scale + offset
                            }
                        }
                        swap(&above, &current)
                    }
                }
            }
        }
        return values
    }

    func elevation(col: Int, row: Int) -> Float {
        elevations[min(max(row, 0), height - 1) * width + min(max(col, 0), width - 1)]
    }

    /// Bilinear sample at a coordinate; nil outside the grid.
    func elevation(at c: CLLocationCoordinate2D) -> Double? {
        guard bounds.contains(latitude: c.latitude, longitude: c.longitude) else { return nil }
        let fx = (c.longitude - bounds.west) / (bounds.east - bounds.west) * Double(width - 1)
        let fy = (bounds.north - c.latitude) / (bounds.north - bounds.south) * Double(height - 1)
        let x0 = Int(fx), y0 = Int(fy)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        let a = Double(elevation(col: x0, row: y0)), b = Double(elevation(col: x0 + 1, row: y0))
        let c0 = Double(elevation(col: x0, row: y0 + 1)), d = Double(elevation(col: x0 + 1, row: y0 + 1))
        return (a * (1 - tx) + b * tx) * (1 - ty) + (c0 * (1 - tx) + d * tx) * ty
    }

    func coordinate(col: Double, row: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: bounds.north - row / Double(height - 1) * (bounds.north - bounds.south),
                               longitude: bounds.west + col / Double(width - 1) * (bounds.east - bounds.west))
    }

    /// Every `step`-th sample from the north-west corner. The east/south bounds shrink to the last
    /// sample actually taken, so the coarse grid's coordinates stay aligned with this one's.
    func subsampled(by step: Int) -> TerrainGrid {
        guard step > 1 else { return self }
        let w = (width - 1) / step + 1, h = (height - 1) / step + 1
        var values = [Float](repeating: 0, count: w * h)
        for r in 0..<h { for c in 0..<w { values[r * w + c] = elevation(col: c * step, row: r * step) } }
        let last = coordinate(col: Double((w - 1) * step), row: Double((h - 1) * step))
        return TerrainGrid(width: w, height: h, bounds: GeoBounds(west: bounds.west, south: last.latitude, east: last.longitude, north: bounds.north),
                           cellSizeMeters: (cellSizeMeters.x * Double(step), cellSizeMeters.y * Double(step)),
                           minElevation: minElevation, maxElevation: maxElevation, elevations: values, source: source, fetchedAt: fetchedAt)
    }
}

/// Marching-squares contour lines from the grid, projected.
enum ContourBuilder {
    /// Lines every `intervalMeters`, named and styled as index lines every `indexEvery`. Cells whose north-west
    /// sample lies inside `excluding` are skipped, so a finer grid can contour that area instead.
    static func contours(from grid: TerrainGrid, projection: LocalProjection, intervalMeters: Double, indexEvery: Double,
                         excluding: GeoBounds? = nil, idPrefix: String = "contour") -> [LineFeature] {
        var features: [LineFeature] = []
        var level = (grid.minElevation / intervalMeters).rounded(.up) * intervalMeters
        var index = 0
        while level < grid.maxElevation {
            let segments = marchingSquares(grid: grid, level: Float(level), excluding: excluding)
            for chain in joinSegments(segments) {
                let coords = chain.map { grid.coordinate(col: Double($0.x), row: Double($0.y)) }
                let isIndex = level.truncatingRemainder(dividingBy: indexEvery) == 0
                if let f = SceneBuilder.lineFeature(id: "\(idPrefix)-\(index)", coords: coords, projection: projection, name: isIndex ? "\(Int(level)) m" : nil,
                                                    label: isIndex ? "\(Int(level)) m" : nil, attributes: ["elevation": .number(level)],
                                                    styleKey: isIndex ? "contour-index" : "contour") {
                    features.append(f)
                    index += 1
                }
            }
            level += intervalMeters
        }
        return features
    }

    private static func marchingSquares(grid: TerrainGrid, level: Float, excluding: GeoBounds?) -> [(CGPoint, CGPoint)] {
        var segments: [(CGPoint, CGPoint)] = []
        func interp(_ a: CGPoint, _ va: Float, _ b: CGPoint, _ vb: Float) -> CGPoint {
            let t = vb == va ? 0.5 : CGFloat((level - va) / (vb - va))
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        let skip = excluding.map { b -> (cols: ClosedRange<Int>, rows: ClosedRange<Int>) in
            let x = { (lon: Double) in Int(((lon - grid.bounds.west) / (grid.bounds.east - grid.bounds.west) * Double(grid.width - 1)).rounded(.down)) }
            let y = { (lat: Double) in Int(((grid.bounds.north - lat) / (grid.bounds.north - grid.bounds.south) * Double(grid.height - 1)).rounded(.down)) }
            return (min(x(b.west) + 1, x(b.east))...x(b.east), min(y(b.north) + 1, y(b.south))...y(b.south))
        }
        for row in 0..<(grid.height - 1) {
            for col in 0..<(grid.width - 1) {
                if let skip, skip.rows.contains(row), skip.cols.contains(col) { continue }
                let v0 = grid.elevation(col: col, row: row), v1 = grid.elevation(col: col + 1, row: row)
                let v2 = grid.elevation(col: col + 1, row: row + 1), v3 = grid.elevation(col: col, row: row + 1)
                let p0 = CGPoint(x: col, y: row), p1 = CGPoint(x: col + 1, y: row), p2 = CGPoint(x: col + 1, y: row + 1), p3 = CGPoint(x: col, y: row + 1)
                var code = 0
                if v0 >= level { code |= 1 }
                if v1 >= level { code |= 2 }
                if v2 >= level { code |= 4 }
                if v3 >= level { code |= 8 }
                if code == 0 || code == 15 { continue }
                let top = interp(p0, v0, p1, v1), right = interp(p1, v1, p2, v2), bottom = interp(p3, v3, p2, v2), left = interp(p0, v0, p3, v3)
                switch code {
                case 1, 14: segments.append((left, top))
                case 2, 13: segments.append((top, right))
                case 3, 12: segments.append((left, right))
                case 4, 11: segments.append((right, bottom))
                case 5: segments.append((left, top)); segments.append((right, bottom))
                case 6, 9: segments.append((top, bottom))
                case 7, 8: segments.append((left, bottom))
                case 10: segments.append((top, right)); segments.append((left, bottom))
                default: break
                }
            }
        }
        return segments
    }

    private static func joinSegments(_ segments: [(CGPoint, CGPoint)]) -> [[CGPoint]] {
        func key(_ p: CGPoint) -> Int { Int((p.x * 64).rounded()) &* 1_000_003 &+ Int((p.y * 64).rounded()) }
        var byStart: [Int: [Int]] = [:]
        for (i, s) in segments.enumerated() {
            byStart[key(s.0), default: []].append(i)
            byStart[key(s.1), default: []].append(i)
        }
        var used = [Bool](repeating: false, count: segments.count)
        var chains: [[CGPoint]] = []
        for i in 0..<segments.count where !used[i] {
            used[i] = true
            var chain = [segments[i].0, segments[i].1]
            var extended = true
            while extended {
                extended = false
                let end = chain[chain.count - 1]
                for j in byStart[key(end)] ?? [] where !used[j] {
                    let s = segments[j]
                    if key(s.0) == key(end) { chain.append(s.1); used[j] = true; extended = true; break }
                    if key(s.1) == key(end) { chain.append(s.0); used[j] = true; extended = true; break }
                }
            }
            if chain.count > 2 { chains.append(chain) }
        }
        return chains
    }
}
