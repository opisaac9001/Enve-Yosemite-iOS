import Foundation
import CoreGraphics
import CoreLocation
import UIKit

/// Immutable CGPath wrapper; paths are built once off-main and only read afterwards.
struct PathBox: @unchecked Sendable {
    let path: CGPath
    let bounds: CGRect
    init(_ path: CGPath) { self.path = path; bounds = path.boundingBoxOfPath }
}

enum LevelOfDetail: Int, CaseIterable, Sendable {
    case coarse = 0, medium, fine, full

    var toleranceMeters: CGFloat {
        switch self {
        case .coarse: 30
        case .medium: 8
        case .fine: 2
        case .full: 0
        }
    }

    static func forScale(_ scale: CGFloat) -> LevelOfDetail {
        if scale < 0.06 { return .coarse }
        if scale < 0.25 { return .medium }
        if scale < 1.0 { return .fine }
        return .full
    }
}

/// A polyline feature with per-LOD paths.
struct LineFeature: Sendable {
    let id: String
    let name: String?
    let label: String?
    let points: [CGPoint]           // projected, full detail
    let lod: [PathBox]               // indexed by LevelOfDetail.rawValue
    let bounds: CGRect
    /// Projected length in metres, kept for label ranking and visibility rules.
    let length: CGFloat
    let attributes: [String: GeoValue]
    let styleKey: String             // renderer style selector (e.g. road class, "bike")
    let oneWay: Int                  // +1 along digitized direction, -1 against, 0 two-way
    let seasonal: String?

    func path(_ level: LevelOfDetail) -> CGPath { lod[level.rawValue].path }
}

/// A polygon feature (outer ring first, holes after) with per-LOD paths and a centroid.
struct AreaFeature: Sendable {
    let id: String
    let name: String?
    let label: String?
    let rings: [[CGPoint]]
    let lod: [PathBox]
    let bounds: CGRect
    let centroid: CGPoint
    let areaSquareMeters: CGFloat
    let attributes: [String: GeoValue]
    let styleKey: String
    let numericId: Int?

    func path(_ level: LevelOfDetail) -> CGPath { lod[level.rawValue].path }
    func contains(_ p: CGPoint) -> Bool {
        guard bounds.contains(p), let outer = rings.first, GeometryOps.pointInRing(p, outer) else { return false }
        for hole in rings.dropFirst() where GeometryOps.pointInRing(p, hole) { return false }
        return true
    }
}

struct PointFeature: Sendable {
    let id: String
    let name: String?
    let point: CGPoint
    let coordinate: CLLocationCoordinate2D
    let type: String?
    let attributes: [String: GeoValue]
}

/// A GNIS landform name or a park region name, labelled between `minScale` and `maxScale`; higher priority wins collisions.
struct SceneLabel: Sendable {
    let id: String
    let text: String
    let point: CGPoint
    let kind: LabelKind
    let priority: Int
    let minScale: CGFloat
    var maxScale: CGFloat = .infinity
}

/// Everything a map screen needs, projected once.
final class MapScene: Sendable {
    let projection: LocalProjection
    let extent: CGRect
    let roads: [LineFeature]
    let trails: [LineFeature]
    let waterLines: [LineFeature]
    let waterAreas: [AreaFeature]
    let buildings: [AreaFeature]
    let parking: [AreaFeature]
    let pois: [PointFeature]
    let boundary: [AreaFeature]
    let fireScars: [AreaFeature]
    let contours: [LineFeature]
    let sources: [String]
    let relief: MapRelief?
    let labels: [SceneLabel]
    /// Hike routes resolved onto this scene's trail geometry, by route id.
    let hikeRoutes: [String: MapRouteTrace]

    init(projection: LocalProjection, extent: CGRect, roads: [LineFeature], trails: [LineFeature],
         waterLines: [LineFeature], waterAreas: [AreaFeature], buildings: [AreaFeature], parking: [AreaFeature],
         pois: [PointFeature], boundary: [AreaFeature], fireScars: [AreaFeature], contours: [LineFeature], sources: [String],
         relief: MapRelief? = nil, labels: [SceneLabel] = [], hikeRoutes: [String: MapRouteTrace] = [:]) {
        self.projection = projection
        self.extent = extent
        self.roads = roads
        self.trails = trails
        self.waterLines = waterLines
        self.waterAreas = waterAreas
        self.buildings = buildings
        self.parking = parking
        self.pois = pois
        self.boundary = boundary
        self.fireScars = fireScars
        self.contours = contours
        self.sources = sources
        self.relief = relief
        self.labels = labels
        self.hikeRoutes = hikeRoutes
    }
}

enum SceneBuilder {
    static func lineFeature(id: String, coords: [CLLocationCoordinate2D], projection: LocalProjection, name: String?, label: String?,
                            attributes: [String: GeoValue], styleKey: String, oneWay: Int = 0, seasonal: String? = nil) -> LineFeature? {
        let points = projection.project(coords)
        guard points.count > 1 else { return nil }
        let lod = LevelOfDetail.allCases.map { level -> PathBox in
            let simplified = level == .full ? points : GeometryOps.simplify(points, tolerance: level.toleranceMeters)
            let path = CGMutablePath()
            path.addLines(between: simplified)
            return PathBox(path)
        }
        return LineFeature(id: id, name: name, label: label, points: points, lod: lod, bounds: GeometryOps.bounds(of: points), length: GeometryOps.length(points),
                           attributes: attributes, styleKey: styleKey, oneWay: oneWay, seasonal: seasonal)
    }

    static func areaFeature(id: String, rings: [[CLLocationCoordinate2D]], projection: LocalProjection, name: String?, label: String?,
                            attributes: [String: GeoValue], styleKey: String, numericId: Int? = nil) -> AreaFeature? {
        let projected = rings.map(projection.project).filter { $0.count > 2 }
        guard let outer = projected.first else { return nil }
        let lod = LevelOfDetail.allCases.map { level -> PathBox in
            let path = CGMutablePath()
            for ring in projected {
                let simplified = level == .full ? ring : GeometryOps.simplify(ring, tolerance: level.toleranceMeters)
                guard simplified.count > 2 else { continue }
                path.addLines(between: simplified)
                path.closeSubpath()
            }
            return PathBox(path)
        }
        return AreaFeature(id: id, name: name, label: label, rings: projected, lod: lod, bounds: GeometryOps.bounds(of: outer),
                           centroid: GeometryOps.centroid(outer), areaSquareMeters: GeometryOps.ringArea(outer),
                           attributes: attributes, styleKey: styleKey, numericId: numericId)
    }

    /// Expands Multi* geometries into individual features with suffixed ids.
    static func lineFeatures(from feature: GeoFeature, index: Int, projection: LocalProjection,
                             name: String?, label: String?, styleKey: String, oneWay: Int = 0, seasonal: String? = nil) -> [LineFeature] {
        let base = feature.id ?? "f\(index)"
        switch feature.geometry {
        case .lineString(let coords):
            return [lineFeature(id: base, coords: coords, projection: projection, name: name, label: label, attributes: feature.properties, styleKey: styleKey, oneWay: oneWay, seasonal: seasonal)].compactMap { $0 }
        case .multiLineString(let lines):
            return lines.enumerated().compactMap { lineFeature(id: "\(base)-\($0.offset)", coords: $0.element, projection: projection, name: name, label: label, attributes: feature.properties, styleKey: styleKey, oneWay: oneWay, seasonal: seasonal) }
        default:
            return []
        }
    }

    static func areaFeatures(from feature: GeoFeature, index: Int, projection: LocalProjection,
                             name: String?, label: String?, styleKey: String, numericId: Int? = nil) -> [AreaFeature] {
        let base = feature.id ?? "f\(index)"
        switch feature.geometry {
        case .polygon(let rings):
            return [areaFeature(id: base, rings: rings, projection: projection, name: name, label: label, attributes: feature.properties, styleKey: styleKey, numericId: numericId)].compactMap { $0 }
        case .multiPolygon(let polys):
            return polys.enumerated().compactMap { areaFeature(id: "\(base)-\($0.offset)", rings: $0.element, projection: projection, name: name, label: label, attributes: feature.properties, styleKey: styleKey, numericId: numericId) }
        default:
            return []
        }
    }
}
