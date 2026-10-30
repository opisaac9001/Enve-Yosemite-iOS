import Foundation
import CoreLocation

struct TrailRoute: Codable, Hashable, Sendable {
    var id: String
    var label: String
    var distanceMi: Double
    var kind: String             // round trip | loop | one way
    var gainFt: Int?
    var timeHours: String?
    /// Difficulty the NPS page publishes for this variant, with its dated source.
    var difficulty: String?
    var difficultySource: SourceLink?

    // The pack writes the published time estimate under `time`.
    enum CodingKeys: String, CodingKey {
        case id, label, distanceMi, kind, gainFt, difficulty, difficultySource
        case timeHours = "time"
    }

    var difficultyRank: Int? { difficulty.map(Trail.difficultyRank) }
}

/// Sourced planning information from the hike's NPS page; dated descriptions, never live status.
struct HikeGuide: Codable, Hashable, Sendable {
    var terrain: String
    var access: String
    var parking: String
    var seasons: String
    var water: String
    var toilets: String
    var etiquette: String?
    var source: SourceLink
}

struct TrailLink: Codable, Hashable, Sendable {
    var label: String
    var url: String?
    var regionId: String?
    var note: String?
}

struct Trail: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var difficulty: String
    var routes: [TrailRoute]
    var summary: String
    var start: String
    var latitude: Double
    var longitude: Double
    var shuttleStops: [Int]
    var gisNames: [String]
    var notes: [String]
    var accessibility: String?
    var pets: String?
    var mapPriority: Int?
    var sources: [SourceLink]
    var extraSources: [SourceLink]?
    var links: [TrailLink]?
    var warnings: [String]?
    var discrepancies: [String]?
    var permits: [String]?
    var estimatedTime: String?
    var guide: HikeGuide?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var longestDistanceMi: Double { routes.map(\.distanceMi).max() ?? 0 }
    var shortestDistanceMi: Double { routes.map(\.distanceMi).min() ?? 0 }
    var maxGainFt: Int { routes.compactMap(\.gainFt).max() ?? 0 }
    func route(_ id: String) -> TrailRoute? { routes.first { $0.id == id } }
    /// The variant's own published difficulty, or the hike's when the page does not split it.
    func difficulty(for route: TrailRoute) -> String { route.difficulty ?? difficulty }

    var difficultyRank: Int { Self.difficultyRank(difficulty) }

    static func difficultyRank(_ text: String) -> Int {
        let d = text.lowercased()
        if d.hasPrefix("easy to") { return 1 }
        if d.hasPrefix("easy") { return 0 }
        if d.hasPrefix("moderate to") { return 3 }
        if d.hasPrefix("moderate") { return 2 }
        if d.hasPrefix("strenuous") { return 4 }
        return 5
    }
}

struct TrailsPack: Codable, Sendable {
    var trails: [Trail]
    var corridorRepairNotice: String
    var iceClosureNotice: String
    var mistTrailIds: [String]
    var johnMuirValleyIds: [String]
    var preparationTips: [String]
}

struct LoopClosure: Codable, Hashable, Sendable {
    var loops: [String]
    var closes: String
    var source: String
}

struct Campground: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var area: String
    var latitude: Double
    var longitude: Double
    var sites: Int
    var accessibleSites: Int
    var elevationFt: Double
    var season: String
    var reservation: String
    var fee: String
    var rvLimit: String
    var water: String
    var notes: [String]
    var placeId: String?
    var gisRoadNames: [String]?
    var loopClosures: [LoopClosure]?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var isValley: Bool { area == "Yosemite Valley" }
}

struct CampgroundsPack: Codable, Sendable {
    var campgrounds: [Campground]
    var guidance: [LabeledDetail]
    var source: SourceLink
    var checked: String
}

struct LabeledDetail: Codable, Hashable, Sendable {
    var label: String
    var detail: String
    var url: String?
    var onlyYear: Int?
    var otherYears: String?
}

/// One Recreation.gov inventory point.
struct Campsite: Identifiable, Hashable, Sendable {
    var ridbId: String
    var campground: String
    var site: String
    var loop: String?
    var type: String
    var accessible: Bool
    var maxPeople: Int?
    var maxVehicleFt: Int?
    var latitude: Double
    var longitude: Double

    var id: String { ridbId }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    /// "003" → "3" for display and matching.
    var displayNumber: String {
        let trimmed = site.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? site : String(trimmed)
    }

    var typeTitle: String {
        type.lowercased().split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    var recreationGovURL: URL? { URL(string: "https://www.recreation.gov/camping/campsites/\(ridbId)") }
}
