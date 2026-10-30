import Foundation
import CoreLocation

struct ForecastPoint: Codable, Identifiable, Hashable, Sendable {
    var key: String
    var label: String
    var region: String
    var latitude: Double
    var longitude: Double
    var uvZip: String
    var elevationFt: Double
    var id: String { key }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

struct FireRegion: Codable, Identifiable, Hashable, Sendable {
    var key: String
    var label: String
    var latitude: Double
    var longitude: Double
    var minor: Bool?
    var note: String?
    var mapLabel: String?
    var id: String { key }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

struct RiskCheck: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var leadMonths: [Int]
    var shoulderMonths: [Int]
    var action: String
    var linkView: String?
}

struct PatternSpec: Codable, Hashable, Sendable {
    var pattern: String
    var caseInsensitive: Bool
}

struct UpdateTopic: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    var view: String
    var href: String
    var cadence: String
}

struct VisitorCenterCuration: Codable, Hashable, Sendable {
    var text: String
    var source: String
    var checked: String
}

struct VisitorCenterConflict: Codable, Hashable, Sendable {
    var exceptionStartDate: String?
    var standardHours: String?
    var note: String
}

struct VisitorCenterLink: Codable, Hashable, Sendable {
    var npsId: String
    var npsName: String
    var placeId: String?
    var regionId: String?
    var curated: VisitorCenterCuration
    var conflicts: [VisitorCenterConflict]?
}

struct ShuttleFrequency: Codable, Hashable, Sendable {
    var source: String
    var valleywide: String
    var eastValley: String
}

struct YartsInfo: Codable, Hashable, Sendable {
    var summary: String
    var stops: [String]
    var phone: String
    var url: String
}

struct ShuttleInfo: Codable, Hashable, Sendable {
    var hours: String
    var fare: String
    var accessibility: String
    var frequency: [ShuttleFrequency]
    var caveat: String
    var yarts: YartsInfo
}

struct GuideEdition: Codable, Hashable, Sendable {
    var title: String
    var url: String
    var validThrough: String
}

struct StatusPack: Codable, Sendable {
    var forecastPoints: [ForecastPoint]
    var fireRegions: [FireRegion]
    var riskChecks: [RiskCheck]
    var riskPatterns: [String: PatternSpec]
    var updateTopics: [UpdateTopic]
    var links: [String: String]
    var fireLinks: [String: String]
    var visitorCenters: [VisitorCenterLink]
    var shuttleInfo: ShuttleInfo
    var guideEdition: GuideEdition
}

struct PlaceCategory: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    var glyph: String
    var color: String

    var symbol: String {
        switch id {
        case "parking": "parkingsign"
        case "charging": "bolt.car.fill"
        case "dump-stations": "arrow.down.to.line.compact"
        case "shuttle": "bus.fill"
        case "information": "info.circle.fill"
        case "food": "fork.knife"
        case "shopping": "bag.fill"
        case "services": "wrench.and.screwdriver.fill"
        case "lodging": "bed.double.fill"
        case "outdoors": "figure.hiking"
        case "bridges": "point.topleft.down.to.point.bottomright.curvepath.fill"
        case "waterfalls": "water.waves"
        case "facilities": "toilet.fill"
        case "water": "drop.fill"
        case "ice": "snowflake"
        default: "mappin"
        }
    }
}

struct CategoriesPack: Codable, Sendable {
    var categories: [PlaceCategory]
    var quickFilterNotes: [String: String]
}

struct NoticeTargets: Codable, Hashable, Sendable {
    var roads: [String]?
    var trails: [String]?
    var places: [String]?
    var regions: [String]?
}

struct NoticePattern: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var pattern: PatternSpec
    var area: PatternSpec?
    var targets: NoticeTargets
}

struct AreaRegionPattern: Codable, Hashable, Sendable {
    var pattern: PatternSpec
    var regions: [String]
}

struct ParkingWalk: Codable, Hashable, Sendable {
    var placeId: String
    var note: String
    var source: String
}

struct NoticesPack: Codable, Sendable {
    var patterns: [NoticePattern]
    var areaRegions: [AreaRegionPattern]
    var parkingSources: [String: SourceLink]
    var parkingWalks: [String: [ParkingWalk]]
}
