import CoreGraphics
import Foundation

/// Shaded relief for one terrain grid: per-cell shade and elevation-tint bytes with a 2× pyramid. Each level is
/// shaded from its own averaged elevations, with a little more vertical exaggeration per level, so whole-park
/// views keep their ridges and canyons instead of averaging fine shading into grey. Tiles are coloured for the
/// current appearance the first time they are drawn and then cached, so panning and zooming never reshade
/// terrain and memory stays bounded however large the grid is.
final class ReliefLayer: @unchecked Sendable {
    struct Level: Sendable {
        let width: Int
        let height: Int
        let shade: [UInt8]
        let tint: [UInt8]
        /// Share of each pixel with source data (255 = all), only for grids with gaps.
        let coverage: [UInt8]?
    }

    static let tileSize = 256

    /// Projected footprint covering the outer edges of the edge cells; maxY is the north edge (image row 0).
    let footprint: CGRect
    /// Sample-centre bounds of the source grid.
    let bounds: GeoBounds
    let cellSizeMeters: (x: Double, y: Double)
    /// Level-0 cells over which the border fades to transparent.
    let feather: Int
    let levels: [Level]
    private let tiles = NSCache<NSString, CGImage>()

    init(grid: TerrainGrid, projection: LocalProjection, feather: Int) {
        let centres = projection.projectedRect(grid.bounds)
        let cellW = centres.width / CGFloat(max(1, grid.width - 1)), cellH = centres.height / CGFloat(max(1, grid.height - 1))
        footprint = centres.insetBy(dx: -cellW / 2, dy: -cellH / 2)
        bounds = grid.bounds
        cellSizeMeters = grid.cellSizeMeters
        self.feather = max(0, feather)
        var levels: [Level] = []
        var elevations = grid.elevations, w = grid.width, h = grid.height
        // Gaps (open ocean beyond 3DEP) shade as sea level, which is what borders them, and draw transparent.
        var coverage: [Float]?
        if elevations.contains(where: \.isNaN) {
            coverage = elevations.map { $0.isNaN ? 0 : 1 }
            elevations = elevations.map { $0.isNaN ? 0 : $0 }
        }
        while true {
            let n = levels.count
            let cell = (x: Float(grid.cellSizeMeters.x) * Float(1 << n), y: Float(grid.cellSizeMeters.y) * Float(1 << n))
            levels.append(Level(width: w, height: h,
                                shade: ReliefRenderer.shade(elevations, width: w, height: h, cell: cell, exaggeration: min(2.2, 1 + 0.3 * Float(n))),
                                tint: ReliefRenderer.tint(elevations), coverage: coverage?.map { UInt8($0 * 255 + 0.5) }))
            guard max(w, h) > Self.tileSize else { break }
            coverage = coverage.map { Self.halved($0, width: w, height: h).0 }
            (elevations, w, h) = Self.halved(elevations, width: w, height: h)
        }
        self.levels = levels
        tiles.totalCostLimit = 40 * 1024 * 1024
    }

    var width: Int { levels[0].width }
    var height: Int { levels[0].height }

    /// The coarsest level whose pixels are still under half a screen point, so tiles are never magnified much.
    func level(forScale scale: CGFloat) -> Int {
        let pointsPerCell = scale * CGFloat(min(cellSizeMeters.x, cellSizeMeters.y))
        var level = 0
        while level + 1 < levels.count, pointsPerCell * CGFloat(1 << (level + 1)) <= 0.5 { level += 1 }
        return level
    }

    func tileCount(level: Int) -> (cols: Int, rows: Int) {
        let l = levels[level]
        return ((l.width + Self.tileSize - 1) / Self.tileSize, (l.height + Self.tileSize - 1) / Self.tileSize)
    }

    /// Projected rectangle a tile covers. A level-n pixel spans 2ⁿ level-0 cells, so the last column and row
    /// of a coarse level can reach a little past the footprint; the feather keeps that overhang transparent.
    func tileRect(level: Int, col: Int, row: Int) -> CGRect {
        let l = levels[level]
        let span = CGFloat(1 << level)
        let cellW = footprint.width / CGFloat(width), cellH = footprint.height / CGFloat(height)
        let c0 = col * Self.tileSize, r0 = row * Self.tileSize
        let cols = min(Self.tileSize, l.width - c0), rows = min(Self.tileSize, l.height - r0)
        let north = footprint.maxY - CGFloat(r0) * span * cellH
        let h = CGFloat(rows) * span * cellH
        return CGRect(x: footprint.minX + CGFloat(c0) * span * cellW, y: north - h, width: CGFloat(cols) * span * cellW, height: h)
    }

    func tile(level: Int, col: Int, row: Int, dark: Bool) -> CGImage? {
        let key = "\(level)/\(col)/\(row)/\(dark ? 1 : 0)" as NSString
        if let cached = tiles.object(forKey: key) { return cached }
        guard let image = makeTile(level: level, col: col, row: row, dark: dark) else { return nil }
        tiles.setObject(image, forKey: key, cost: image.width * image.height * 4)
        return image
    }

    /// Premultiplied RGBA, row 0 north; border pixels fade over `feather` level-0 cells.
    private func makeTile(level: Int, col: Int, row: Int, dark: Bool) -> CGImage? {
        let l = levels[level]
        let c0 = col * Self.tileSize, r0 = row * Self.tileSize
        let w = min(Self.tileSize, l.width - c0), h = min(Self.tileSize, l.height - r0)
        guard w > 0, h > 0 else { return nil }
        let lut = dark ? ReliefRenderer.darkTable : ReliefRenderer.lightTable
        let span = Float(1 << level)
        let feather = Float(feather)
        let maxCol = Float(width - 1), maxRow = Float(height - 1)
        var pixels = [UInt32](repeating: 0, count: w * h)
        l.shade.withUnsafeBufferPointer { shade in
            l.tint.withUnsafeBufferPointer { tint in
                lut.withUnsafeBufferPointer { lut in
                    pixels.withUnsafeMutableBufferPointer { out in
                        for y in 0..<h {
                            let src = (r0 + y) * l.width + c0
                            let cy = (Float(r0 + y) + 0.5) * span - 0.5
                            let rowEdge = cy < maxRow - cy ? cy : maxRow - cy
                            for x in 0..<w {
                                let rgba = lut[Int(tint[src + x]) << 8 | Int(shade[src + x])]
                                let cx = (Float(c0 + x) + 0.5) * span - 0.5
                                var edge = cx < maxCol - cx ? cx : maxCol - cx
                                if rowEdge < edge { edge = rowEdge }
                                if edge >= feather {
                                    out[y * w + x] = rgba
                                } else {
                                    out[y * w + x] = edge <= 0 ? 0 : ReliefRenderer.scaled(rgba, by: edge / feather)
                                }
                            }
                        }
                    }
                }
            }
        }
        if let coverage = l.coverage {
            for y in 0..<h {
                for x in 0..<w {
                    let share = coverage[(r0 + y) * l.width + c0 + x]
                    if share < 255 { pixels[y * w + x] = ReliefRenderer.scaled(pixels[y * w + x], by: Float(share) / 255) }
                }
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func halved(_ elevations: [Float], width: Int, height: Int) -> ([Float], Int, Int) {
        let w = (width + 1) / 2, h = (height + 1) / 2
        var out = [Float](repeating: 0, count: w * h)
        elevations.withUnsafeBufferPointer { e in
            out.withUnsafeMutableBufferPointer { out in
                for y in 0..<h {
                    let y0 = 2 * y * width, y1 = (2 * y + 1 < height ? 2 * y + 1 : height - 1) * width
                    for x in 0..<w {
                        let x0 = 2 * x, x1 = 2 * x + 1 < width ? 2 * x + 1 : width - 1
                        out[y * w + x] = (e[y0 + x0] + e[y0 + x1] + e[y1 + x0] + e[y1 + x1]) / 4
                    }
                }
            }
        }
        return (out, w, h)
    }
}

/// Relief for a scene, coarsest layer first so finer layers draw on top.
struct MapRelief: Sendable {
    let layers: [ReliefLayer]
}

enum ReliefRenderer {
    struct Palette {
        var lowTint: (r: Float, g: Float, b: Float)
        var highTint: (r: Float, g: Float, b: Float)
        var shadowFactor: Float
        var lightFactor: Float

        static let light = Palette(lowTint: (0.91, 0.88, 0.80), highTint: (0.74, 0.76, 0.79), shadowFactor: 0.52, lightFactor: 1.12)
        static let dark = Palette(lowTint: (0.125, 0.145, 0.165), highTint: (0.28, 0.295, 0.315), shadowFactor: 0.42, lightFactor: 1.6)
    }

    /// One elevation ramp for every layer, so tiers from different grids meet without a tint seam.
    static let tintRange: (low: Float, high: Float) = (900, 3600)

    // Unit light vectors (east, north, up): north-west dominant, west and north soften it.
    private static let lights: [(x: Float, y: Float, z: Float, weight: Float)] = {
        func unit(azimuthDeg: Float, altitudeDeg: Float, weight: Float) -> (Float, Float, Float, Float) {
            let az = azimuthDeg * .pi / 180, alt = altitudeDeg * .pi / 180
            return (cos(alt) * sin(az), cos(alt) * cos(az), sin(alt), weight)
        }
        return [unit(azimuthDeg: 315, altitudeDeg: 45, weight: 0.55), unit(azimuthDeg: 270, altitudeDeg: 40, weight: 0.25), unit(azimuthDeg: 0, altitudeDeg: 40, weight: 0.20)]
    }()

    private static let flatIllumination: Float = lights.reduce(0) { $0 + $1.z * $1.weight }

    static func shade(grid: TerrainGrid) -> [UInt8] {
        shade(grid.elevations, width: grid.width, height: grid.height, cell: (Float(grid.cellSizeMeters.x), Float(grid.cellSizeMeters.y)), exaggeration: 1)
    }

    /// Illumination per cell as a byte, flat ground at 128 (Horn derivatives in metres, slope-darkened).
    /// Written with plain arithmetic on raw buffers so unoptimised builds can still shade a park-sized grid.
    static func shade(_ elevations: [Float], width w: Int, height h: Int, cell: (x: Float, y: Float), exaggeration: Float) -> [UInt8] {
        var out = [UInt8](repeating: 128, count: w * h)
        guard w > 1, h > 1 else { return out }
        let cx = 8 * cell.x / exaggeration, cy = 8 * cell.y / exaggeration
        let contrast: Float = 1.5
        let maxSlope: Float = 1.73
        let (a0, a1, a2) = (lights[0], lights[1], lights[2])
        let flat = flatIllumination
        elevations.withUnsafeBufferPointer { e in
            out.withUnsafeMutableBufferPointer { out in
                for r in 0..<h {
                    let up = (r > 0 ? r - 1 : 0) * w, mid = r * w, down = (r + 1 < h ? r + 1 : h - 1) * w
                    for c in 0..<w {
                        let left = c > 0 ? c - 1 : 0, right = c + 1 < w ? c + 1 : w - 1
                        let a = e[up + left], b = e[up + c], cc = e[up + right]
                        let d = e[mid + left], f = e[mid + right]
                        let g = e[down + left], hh = e[down + c], i = e[down + right]
                        let dzdx = ((cc + 2 * f + i) - (a + 2 * d + g)) / cx
                        let dzdySouth = ((g + 2 * hh + i) - (a + 2 * b + cc)) / cy
                        let nx = -dzdx, ny = dzdySouth
                        let len = (nx * nx + ny * ny + 1).squareRoot()
                        let i0 = (nx * a0.x + ny * a0.y + a0.z) / len, i1 = (nx * a1.x + ny * a1.y + a1.z) / len, i2 = (nx * a2.x + ny * a2.y + a2.z) / len
                        let illum = (i0 > 0 ? i0 * a0.weight : 0) + (i1 > 0 ? i1 * a1.weight : 0) + (i2 > 0 ? i2 * a2.weight : 0)
                        let steep = (dzdx * dzdx + dzdySouth * dzdySouth).squareRoot()
                        var v = 0.5 + (illum / flat * 0.5 - 0.5) * contrast - (steep < maxSlope ? steep : maxSlope) / maxSlope * 0.10
                        v = v < 0 ? 0 : v > 1 ? 1 : v
                        out[mid + c] = UInt8(v * 255 + 0.5)
                    }
                }
            }
        }
        return out
    }

    /// Position on the shared elevation ramp per cell, 0 at the low end and 255 at the high end.
    static func tint(_ elevations: [Float]) -> [UInt8] {
        let lo = tintRange.low, steps = Float(curve.count - 1) / (tintRange.high - tintRange.low)
        var out = [UInt8](repeating: 0, count: elevations.count)
        elevations.withUnsafeBufferPointer { e in
            curve.withUnsafeBufferPointer { curve in
                out.withUnsafeMutableBufferPointer { out in
                    for i in 0..<e.count {
                        let t = (e[i] - lo) * steps
                        out[i] = curve[t <= 0 ? 0 : t >= Float(curve.count - 1) ? curve.count - 1 : Int(t)]
                    }
                }
            }
        }
        return out
    }

    /// The tint ramp's gentle curve sampled finely enough that a cell never steps by more than one byte.
    private static let curve: [UInt8] = (0..<4096).map { UInt8(powf(Float($0) / 4095, 0.85) * 255 + 0.5) }

    static let lightTable = table(.light)
    static let darkTable = table(.dark)

    /// Opaque premultiplied RGBA (little-endian R first) for every tint × shade byte pair.
    private static func table(_ palette: Palette) -> [UInt32] {
        var table = [UInt32](repeating: 0, count: 256 * 256)
        for t in 0..<256 {
            let tf = Float(t) / 255
            let base = (palette.lowTint.r + (palette.highTint.r - palette.lowTint.r) * tf,
                        palette.lowTint.g + (palette.highTint.g - palette.lowTint.g) * tf,
                        palette.lowTint.b + (palette.highTint.b - palette.lowTint.b) * tf)
            for s in 0..<256 {
                let v = Float(s) / 255
                let factor = v < 0.5 ? palette.shadowFactor + (1 - palette.shadowFactor) * (v / 0.5) : 1 + (palette.lightFactor - 1) * ((v - 0.5) / 0.5)
                func byte(_ x: Float) -> UInt32 { UInt32(min(255, max(0, x * factor * 255))) }
                table[t << 8 | s] = byte(base.0) | byte(base.1) << 8 | byte(base.2) << 16 | 0xFF << 24
            }
        }
        return table
    }

    static func scaled(_ rgba: UInt32, by alpha: Float) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 { UInt32(Float((rgba >> shift) & 0xFF) * alpha) << shift }
        return channel(0) | channel(8) | channel(16) | channel(24)
    }
}
