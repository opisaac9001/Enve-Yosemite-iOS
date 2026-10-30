import Foundation
import CoreGraphics
import CoreLocation

/// Terrain self-shadowing on the bundled grid: for each cell, march toward the sun and test
/// whether the terrain rises above the sun ray. Cells outside the grid are unknown, not lit.
enum ShadowRenderer {
    struct Result: @unchecked Sendable {
        let image: CGImage
        let rect: CGRect            // projected metres in the Valley projection
        let litFraction: Double
    }

    static func render(grid: TerrainGrid, altitudeDeg: Double, azimuthDeg: Double, projection: LocalProjection) -> Result? {
        let w = grid.width, h = grid.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let altitude = altitudeDeg * .pi / 180
        let azimuth = azimuthDeg * .pi / 180
        // Direction toward the sun in grid units (col east, row south).
        let dirX = sin(azimuth) / grid.cellSizeMeters.x
        let dirY = -cos(azimuth) / grid.cellSizeMeters.y
        let tanAlt = tan(altitude)
        let night = altitudeDeg <= -0.833
        var lit = 0
        let stepMeters = 25.0
        let maxSteps = 260
        for row in 0..<h {
            for col in 0..<w {
                var shadowed = night
                if !night {
                    let base = Double(grid.elevation(col: col, row: row))
                    var x = Double(col), y = Double(row)
                    var distance = 0.0
                    for _ in 0..<maxSteps {
                        x += dirX * stepMeters
                        y += dirY * stepMeters
                        distance += stepMeters
                        if x < 0 || y < 0 || x >= Double(w - 1) || y >= Double(h - 1) { break }
                        let terrain = Double(grid.elevation(col: Int(x), row: Int(y)))
                        if terrain - base > distance * tanAlt + 2 { shadowed = true; break }
                    }
                }
                if !shadowed { lit += 1 }
                let i = (row * w + col) * 4
                let alpha: UInt8 = shadowed ? (night ? 150 : 110) : 0
                pixels[i] = 10; pixels[i + 1] = 18; pixels[i + 2] = 40; pixels[i + 3] = alpha
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let rect = projection.projectedRect(grid.bounds)
        return Result(image: image, rect: rect, litFraction: Double(lit) / Double(w * h))
    }
}
