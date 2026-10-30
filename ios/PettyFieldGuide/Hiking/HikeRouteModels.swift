import Foundation
import CoreLocation

/// How a route is travelled; the trace in the pack is one pass, the return of an out-and-back is implied.
enum HikeRouteKind: String, Codable, Sendable {
    case outAndBack, loop, oneWay

    var title: String {
        switch self {
        case .outAndBack: "Out and back"
        case .loop: "Loop"
        case .oneWay: "One way"
        }
    }
}

/// One stretch of an NPS trail feature in travel order; `from > to` walks it against its digitised direction.
struct HikeSegment: Codable, Hashable, Sendable {
    var feature: Int
    var name: String?
    var altName: String?
    var surface: String?
    var use: String?
    var from: Double
    var to: Double
    var metres: Double
}

struct HikeMilestone: Codable, Hashable, Sendable {
    var anchor: String
    var name: String
    var role: String            // start | waypoint | destination
    var lonlat: [Double]
    var chainageMiles: Double
    var offsetMetres: Double
    var source: String

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lonlat[1], longitude: lonlat[0]) }
    var isApproximate: Bool { source.hasPrefix("derived") || name.contains("approximate") }
}

/// A published hike variant resolved onto official geometry by `tools/build_hike_routes.py`.
struct HikeRoute: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var trailId: String
    var label: String
    var kind: HikeRouteKind
    var isDefault: Bool
    var publishedMiles: Double
    var traceMiles: Double
    var traceOneWayMiles: Double
    var traceToPublishedRatio: Double
    var bounds: GeoBounds
    var start: HikeMilestone
    var destination: HikeMilestone
    var milestones: [HikeMilestone]
    var segments: [HikeSegment]
    var metresByName: [String: Double]
    var unnamedFeatures: Int
    var sequence: String
    var traceNote: String

    /// Every milestone in travel order, start first.
    var orderedMilestones: [HikeMilestone] { [start] + milestones + [destination] }
    /// Rows for lists: a loop's start and destination share an anchor, so identity comes from the position.
    var milestoneRows: [HikeMilestoneRow] {
        orderedMilestones.enumerated().map { HikeMilestoneRow(id: "\($0.offset)-\($0.element.anchor)", milestone: $0.element) }
    }
    var featureIds: Set<Int> { Set(segments.map(\.feature)) }

    static func == (lhs: HikeRoute, rhs: HikeRoute) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct HikeMilestoneRow: Identifiable, Hashable, Sendable {
    let id: String
    let milestone: HikeMilestone
}

struct HikeRoutesPack: Codable, Sendable {
    struct Geometry: Codable, Sendable {
        var file: String
        var sha256: String
        var featureCount: Int
        var source: String
    }
    var schema: Int
    var generated: String
    var geometry: Geometry
    var derivation: String
    var routes: [HikeRoute]
}
