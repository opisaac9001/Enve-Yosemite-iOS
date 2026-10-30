import CoreGraphics
import Foundation

/// One shaded-relief raster in both appearances; `rect` is its footprint in the scene projection, row 0 north.
struct ReliefTier: @unchecked Sendable {
    let rect: CGRect
    let bounds: GeoBounds
    let width: Int
    let height: Int
    let light: CGImage
    let dark: CGImage
    let cellSizeMeters: (x: Double, y: Double)

    func image(dark: Bool) -> CGImage { dark ? self.dark : light }
}

/// Relief for a scene, coarse tier first so the detail tier draws on top.
struct MapRelief: @unchecked Sendable {
    let tiers: [ReliefTier]
}

enum ReliefRenderer {
    struct Palette {
        var lowTint: (r: Float, g: Float, b: Float)
        var highTint: (r: Float, g: Float, b: Float)
        var shadowFactor: Float
        var lightFactor: Float

        static let light = Palette(lowTint: (0.90, 0.88, 0.81), highTint: (0.76, 0.77, 0.78), shadowFactor: 0.58, lightFactor: 1.14)
        static let dark = Palette(lowTint: (0.125, 0.145, 0.165), highTint: (0.27, 0.285, 0.30), shadowFactor: 0.45, lightFactor: 1.55)
    }

    // Unit light vectors (east, north, up): north-west dominant, west and north soften it.
    private static let lights: [(x: Float, y: Float, z: Float, weight: Float)] = {
        func unit(azimuthDeg: Float, altitudeDeg: Float, weight: Float) -> (Float, Float, Float, Float) {
            let az = azimuthDeg * .pi / 180, alt = altitudeDeg * .pi / 180
            return (cos(alt) * sin(az), cos(alt) * cos(az), sin(alt), weight)
        }
        return [unit(azimuthDeg: 315, altitudeDeg: 45, weight: 0.55), unit(azimuthDeg: 270, altitudeDeg: 40, weight: 0.25), unit(azimuthDeg: 0, altitudeDeg: 40, weight: 0.20)]
    }()

    private static let flatIllumination: Float = lights.reduce(0) { $0 + $1.z * $1.weight }

    /// Illumination per cell in 0…1 with flat ground at 0.5 (Horn derivatives in metres, slope-darkened).
    static func shade(grid: TerrainGrid) -> [Float] {
        let w = grid.width, h = grid.height
        var out = [Float](repeating: 0.5, count: w * h)
        guard w > 1, h > 1 else { return out }
        let cx = Float(8 * grid.cellSizeMeters.x), cy = Float(8 * grid.cellSizeMeters.y)
        let contrast: Float = 1.35
        let maxSlope: Float = 1.73
        let lights = lights
        let flat = flatIllumination
        grid.elevations.withUnsafeBufferPointer { e in
            out.withUnsafeMutableBufferPointer { out in
                @inline(__always) func at(_ c: Int, _ r: Int) -> Float { e[min(max(r, 0), h - 1) * w + min(max(c, 0), w - 1)] }
                for r in 0..<h {
                    for c in 0..<w {
                        let a = at(c - 1, r - 1), b = at(c, r - 1), cc = at(c + 1, r - 1)
                        let d = at(c - 1, r), f = at(c + 1, r)
                        let g = at(c - 1, r + 1), hh = at(c, r + 1), i = at(c + 1, r + 1)
                        let dzdx = ((cc + 2 * f + i) - (a + 2 * d + g)) / cx
                        let dzdySouth = ((g + 2 * hh + i) - (a + 2 * b + cc)) / cy
                        let nx = -dzdx, ny = dzdySouth
                        let len = (nx * nx + ny * ny + 1).squareRoot()
                        var illum: Float = 0
                        for l in lights { illum += max(0, (nx * l.x + ny * l.y + l.z) / len) * l.weight }
                        var v = 0.5 + (illum / flat * 0.5 - 0.5) * contrast
                        let slope = min(maxSlope, (dzdx * dzdx + dzdySouth * dzdySouth).squareRoot()) / maxSlope
                        v -= slope * 0.10
                        out[r * w + c] = min(1, max(0, v))
                    }
                }
            }
        }
        return out
    }

    /// Tint × shade as a premultiplied RGBA image; `feather` cells at the border fade to transparent.
    static func image(grid: TerrainGrid, shade: [Float], palette: Palette, feather: Int = 0) -> CGImage? {
        let w = grid.width, h = grid.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let lo = Float(max(grid.minElevation, 1000))
        let hi = max(lo + 100, Float(min(grid.maxElevation, 2900)))
        let feather = Float(max(0, feather))
        grid.elevations.withUnsafeBufferPointer { e in
            shade.withUnsafeBufferPointer { s in
                pixels.withUnsafeMutableBufferPointer { p in
                    for r in 0..<h {
                        for c in 0..<w {
                            let idx = r * w + c
                            let t = powf(min(1, max(0, (e[idx] - lo) / (hi - lo))), 0.85)
                            let v = s[idx]
                            let factor = v < 0.5 ? palette.shadowFactor + (1 - palette.shadowFactor) * (v / 0.5) : 1 + (palette.lightFactor - 1) * ((v - 0.5) / 0.5)
                            var alpha: Float = 1
                            if feather > 0 {
                                let edge = Float(min(min(c, w - 1 - c), min(r, h - 1 - r)))
                                alpha = min(1, edge / feather)
                            }
                            let o = idx * 4
                            p[o] = UInt8(min(255, max(0, (palette.lowTint.r + (palette.highTint.r - palette.lowTint.r) * t) * factor * alpha * 255)))
                            p[o + 1] = UInt8(min(255, max(0, (palette.lowTint.g + (palette.highTint.g - palette.lowTint.g) * t) * factor * alpha * 255)))
                            p[o + 2] = UInt8(min(255, max(0, (palette.lowTint.b + (palette.highTint.b - palette.lowTint.b) * t) * factor * alpha * 255)))
                            p[o + 3] = UInt8(alpha * 255)
                        }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    static func tier(grid: TerrainGrid, projection: LocalProjection, feather: Int) -> ReliefTier? {
        let shade = shade(grid: grid)
        guard let light = image(grid: grid, shade: shade, palette: .light, feather: feather),
              let dark = image(grid: grid, shade: shade, palette: .dark, feather: feather) else { return nil }
        return ReliefTier(rect: projection.projectedRect(grid.bounds), bounds: grid.bounds, width: grid.width, height: grid.height,
                          light: light, dark: dark, cellSizeMeters: grid.cellSizeMeters)
    }
}
