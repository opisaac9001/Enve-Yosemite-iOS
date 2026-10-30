import Foundation
import CoreLocation
import CoreGraphics

/// Local equirectangular projection: metres east/north of a reference latitude/longitude.
/// Accurate to well under a metre across the Valley and a few metres park-wide, which is far
/// below the "orientation, not survey" accuracy of the NPS geometry.
struct LocalProjection: Sendable {
    let origin: CLLocationCoordinate2D
    let metersPerDegreeLat: Double
    let metersPerDegreeLon: Double

    init(origin: CLLocationCoordinate2D) {
        self.origin = origin
        metersPerDegreeLat = 111_132.954 - 559.822 * cos(2 * origin.latitude * .pi / 180) + 1.175 * cos(4 * origin.latitude * .pi / 180)
        metersPerDegreeLon = (.pi / 180) * 6_378_137 * cos(origin.latitude * .pi / 180)
    }

    /// Projected point in metres; y grows northward.
    func project(_ c: CLLocationCoordinate2D) -> CGPoint {
        CGPoint(x: (c.longitude - origin.longitude) * metersPerDegreeLon,
                y: (c.latitude - origin.latitude) * metersPerDegreeLat)
    }

    func unproject(_ p: CGPoint) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: origin.latitude + p.y / metersPerDegreeLat,
                               longitude: origin.longitude + p.x / metersPerDegreeLon)
    }

    func project(_ coords: [CLLocationCoordinate2D]) -> [CGPoint] { coords.map(project) }
}

enum GeometryOps {
    /// Ramer–Douglas–Peucker simplification with a tolerance in projected metres.
    static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2, tolerance > 0 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        let tol2 = tolerance * tolerance
        while let (a, b) = stack.popLast() {
            guard b - a > 1 else { continue }
            var maxDist: CGFloat = 0
            var index = a
            for i in (a + 1)..<b {
                let d = distanceSquared(points[i], toSegment: points[a], points[b])
                if d > maxDist { maxDist = d; index = i }
            }
            if maxDist > tol2 {
                keep[index] = true
                stack.append((a, index))
                stack.append((index, b))
            }
        }
        return points.enumerated().filter { keep[$0.offset] }.map(\.element)
    }

    static func distanceSquared(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        var t: CGFloat = 0
        if len2 > 0 { t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) }
        let px = a.x + t * dx - p.x, py = a.y + t * dy - p.y
        return px * px + py * py
    }

    static func distance(_ p: CGPoint, toPolyline line: [CGPoint]) -> CGFloat {
        guard line.count > 1 else { return line.first.map { hypot($0.x - p.x, $0.y - p.y) } ?? .infinity }
        var best = CGFloat.infinity
        for i in 1..<line.count {
            best = min(best, distanceSquared(p, toSegment: line[i - 1], line[i]))
        }
        return sqrt(best)
    }

    static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func pointInRing(_ p: CGPoint, _ ring: [CGPoint]) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    static func centroid(_ ring: [CGPoint]) -> CGPoint {
        guard ring.count > 2 else { return ring.first ?? .zero }
        var area: CGFloat = 0, cx: CGFloat = 0, cy: CGFloat = 0
        for i in 0..<ring.count {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            let cross = a.x * b.y - b.x * a.y
            area += cross
            cx += (a.x + b.x) * cross
            cy += (a.y + b.y) * cross
        }
        guard abs(area) > 1e-9 else {
            let sum = ring.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return CGPoint(x: sum.x / CGFloat(ring.count), y: sum.y / CGFloat(ring.count))
        }
        area *= 0.5
        return CGPoint(x: cx / (6 * area), y: cy / (6 * area))
    }

    static func ringArea(_ ring: [CGPoint]) -> CGFloat {
        guard ring.count > 2 else { return 0 }
        var area: CGFloat = 0
        for i in 0..<ring.count {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            area += a.x * b.y - b.x * a.y
        }
        return abs(area) / 2
    }

    static func length(_ line: [CGPoint]) -> CGFloat {
        guard line.count > 1 else { return 0 }
        var total: CGFloat = 0
        for i in 1..<line.count { total += hypot(line[i].x - line[i - 1].x, line[i].y - line[i - 1].y) }
        return total
    }
}
