import Foundation
import CoreGraphics
import CoreLocation

/// A hike route resolved onto the projected scene geometry: one pass of the trace plus its named points.
struct MapRouteTrace: Sendable {
    struct Point: Sendable {
        let point: CGPoint
        let name: String
        let role: String
        let approximate: Bool
    }

    let id: String
    let trailId: String
    let kind: HikeRouteKind
    let points: [CGPoint]           // projected, travel order, one pass
    let lod: [PathBox]              // indexed by LevelOfDetail.rawValue, like LineFeature
    let bounds: CGRect
    let start: Point
    let destination: Point
    let milestones: [Point]
    /// The line as actually walked, with its cumulative lengths: an out-and-back returns along the same points.
    let chainage: HikeChainage

    func path(_ level: LevelOfDetail) -> CGPath { lod[level.rawValue].path }

    var travelled: [CGPoint] { chainage.points }
    /// Where the walk turns (out-and-back) or simply ends (loop, one way), in metres along the travelled line.
    var turnaroundMetres: Double { kind == .outAndBack ? chainage.cumulative[points.count - 1] : chainage.totalMetres }
}

struct HikeChainage: Sendable, Equatable {
    let points: [CGPoint]
    let cumulative: [Double]

    init(points: [CGPoint]) {
        self.points = points
        var cumulative = [0.0]
        cumulative.reserveCapacity(points.count)
        for i in 1..<max(points.count, 1) {
            cumulative.append(cumulative[i - 1] + Double(hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)))
        }
        self.cumulative = points.isEmpty ? [] : cumulative
    }

    var totalMetres: Double { cumulative.last ?? 0 }

    func point(at metres: Double) -> CGPoint {
        guard points.count > 1 else { return points.first ?? .zero }
        let target = min(max(metres, 0), totalMetres)
        var low = 1, high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if cumulative[mid] < target { low = mid + 1 } else { high = mid }
        }
        let span = cumulative[low] - cumulative[low - 1]
        let t = span > 0 ? CGFloat((target - cumulative[low - 1]) / span) : 0
        let a = points[low - 1], b = points[low]
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}

/// Terrain elevations sampled along a travelled route from the bundled relief grid.
struct HikeProfile: Sendable, Equatable {
    struct Sample: Sendable, Equatable {
        let distanceMetres: Double
        let elevationMetres: Double
    }
    let samples: [Sample]
    let stepMetres: Double
    let minMetres: Double
    let maxMetres: Double
    let approxGainMetres: Double
    let approxLossMetres: Double
    let source: String

    var totalMetres: Double { samples.last?.distanceMetres ?? 0 }
}

enum HikeRouteResolver {
    /// Slices each referenced feature by arc-length fraction and joins the pieces in travel order. A route
    /// whose feature is missing from the scene is left out entirely rather than bridged with a straight line.
    static func traces(for routes: [HikeRoute], trails: [LineFeature], projection: LocalProjection) -> [String: MapRouteTrace] {
        let byId = Dictionary(trails.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String: MapRouteTrace] = [:]
        for route in routes {
            guard let points = join(route.segments, features: byId), points.count > 1 else { continue }
            func mark(_ m: HikeMilestone) -> MapRouteTrace.Point {
                MapRouteTrace.Point(point: projection.project(m.coordinate), name: m.name, role: m.role, approximate: m.isApproximate)
            }
            let lod = LevelOfDetail.allCases.map { level -> PathBox in
                let path = CGMutablePath()
                path.addLines(between: level == .full ? points : GeometryOps.simplify(points, tolerance: level.toleranceMeters))
                return PathBox(path)
            }
            let travelled = route.kind == .outAndBack ? points + points.dropLast().reversed() : points
            out[route.id] = MapRouteTrace(id: route.id, trailId: route.trailId, kind: route.kind, points: points, lod: lod, bounds: GeometryOps.bounds(of: points),
                                          start: mark(route.start), destination: mark(route.destination), milestones: route.milestones.map(mark),
                                          chainage: HikeChainage(points: travelled))
        }
        return out
    }

    /// Joined points for a segment chain, or nil when any segment references a feature the scene lacks.
    static func join(_ segments: [HikeSegment], features: [String: LineFeature]) -> [CGPoint]? {
        var points: [CGPoint] = []
        for segment in segments {
            guard let feature = features[String(segment.feature)] else { return nil }
            var piece = slice(feature.points, from: segment.from, to: segment.to)
            if let last = points.last, let first = piece.first, hypot(last.x - first.x, last.y - first.y) < 0.5 {
                piece.removeFirst()
            }
            points += piece
        }
        return points
    }

    /// Points of a polyline between two arc-length fractions, reversed when `to < from`.
    static func slice(_ points: [CGPoint], from: Double, to: Double) -> [CGPoint] {
        guard points.count > 1 else { return points }
        var cumulative: [CGFloat] = [0]
        for i in 1..<points.count { cumulative.append(cumulative[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)) }
        let total = cumulative[points.count - 1]
        guard total > 0 else { return [points[0]] }
        func at(_ fraction: Double) -> CGPoint {
            let target = CGFloat(fraction) * total
            for i in 1..<points.count where target <= cumulative[i] || i == points.count - 1 {
                let span = cumulative[i] - cumulative[i - 1]
                let t = span > 0 ? max(0, min(1, (target - cumulative[i - 1]) / span)) : 0
                return CGPoint(x: points[i - 1].x + (points[i].x - points[i - 1].x) * t, y: points[i - 1].y + (points[i].y - points[i - 1].y) * t)
            }
            return points[points.count - 1]
        }
        let lo = min(from, to), hi = max(from, to)
        var out = [at(lo)]
        for i in 0..<points.count {
            let f = Double(cumulative[i] / total)
            if f > lo && f < hi { out.append(points[i]) }
        }
        out.append(at(hi))
        return to < from ? out.reversed() : out
    }

    /// Elevation every `step` metres along the travelled line; nil when any sample leaves the grid.
    static func profile(for trace: MapRouteTrace, grid: TerrainGrid, projection: LocalProjection, step: Double = 40, hysteresis: Double = 10) -> HikeProfile? {
        let line = trace.chainage
        guard line.points.count > 1 else { return nil }
        let total = line.totalMetres
        var samples: [HikeProfile.Sample] = []
        var distance = 0.0
        while true {
            guard let elevation = grid.elevation(at: projection.unproject(line.point(at: distance))) else { return nil }
            samples.append(HikeProfile.Sample(distanceMetres: distance, elevationMetres: elevation))
            if distance >= total { break }
            distance = min(distance + step, total)
        }
        guard samples.count > 1 else { return nil }
        var gain = 0.0, loss = 0.0, reference = samples[0].elevationMetres
        for s in samples.dropFirst() {
            if s.elevationMetres - reference >= hysteresis { gain += s.elevationMetres - reference; reference = s.elevationMetres }
            else if reference - s.elevationMetres >= hysteresis { loss += reference - s.elevationMetres; reference = s.elevationMetres }
        }
        let elevations = samples.map(\.elevationMetres)
        return HikeProfile(samples: samples, stepMetres: step, minMetres: elevations.min()!, maxMetres: elevations.max()!,
                           approxGainMetres: gain, approxLossMetres: loss, source: grid.source)
    }
}

extension MapMarker {
    /// A loop ends where it starts, so it gets only the start badge; compact labels keep the full names for VoiceOver.
    static func routeMarkers(for route: MapRouteTrace, compactLabels: Bool = false) -> [MapMarker] {
        let start = "Start · \(route.start.name)"
        var markers = [MapMarker(id: routeStartId, point: route.start.point, title: compactLabels ? "Start" : start,
                                 symbol: "figure.walk", colorHex: "#1F4D3F", priority: 66, shape: .badge, clusterable: false, labelMinScale: 0,
                                 accessibilityTitle: compactLabels ? start : nil)]
        if route.kind != .loop {
            let full = "\(route.destination.approximate ? "Approximate destination" : "Destination") · \(route.destination.name)"
            markers.append(MapMarker(id: routeDestinationId, point: route.destination.point,
                                     title: compactLabels ? (route.kind == .outAndBack ? "Turnaround" : "Finish") : full,
                                     symbol: "flag.fill", colorHex: "#C93B2E", priority: 67, shape: .badge, clusterable: false, labelMinScale: 0,
                                     accessibilityTitle: compactLabels ? full : nil))
        }
        return markers
    }

    static let routeMilestonePrefix = "route-milestone-"

    /// Outward-pass waypoints only; VoiceOver gets the full name and distance.
    static func milestoneMarkers(for landmarks: [HikeLandmark], labelled: Bool) -> [MapMarker] {
        landmarks.filter { $0.role == "waypoint" && $0.leg != .back }.map { landmark in
            MapMarker(id: routeMilestonePrefix + landmark.id, point: landmark.point, title: landmark.compactName, colorHex: "#3B7EA8", priority: 64,
                      shape: .dot, clusterable: false, labelMinScale: labelled ? 0.03 : nil,
                      accessibilityTitle: "Waypoint · \(landmark.name) · \(HikeFormat.inspectionMiles(landmark.metres)) along the route")
        }
    }
}
