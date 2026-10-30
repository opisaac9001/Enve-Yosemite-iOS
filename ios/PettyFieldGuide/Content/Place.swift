import Foundation
import CoreLocation

struct SourceLink: Codable, Hashable, Sendable {
    var label: String
    var url: String?
    var publisher: String?
    var updated: String?
    var checked: String?
    var central: Bool?
}

struct PhoneNumber: Codable, Hashable, Sendable {
    var label: String
    var number: String
    var note: String?
    var hours: String?
}

struct LabeledText: Codable, Hashable, Sendable {
    var label: String
    var text: String
    var searchable: Bool?
}

struct MenuDocument: Codable, Hashable, Sendable {
    var id: String
    var label: String
    var url: String
    var publisher: String?
    var pdfCreated: String?
    var pages: Int?
    var bytes: Int?
    var checked: String?
}

struct PlaceReference: Codable, Hashable, Sendable {
    var label: String
    var placeId: String
}

struct MenuInfo: Codable, Hashable, Sendable {
    var status: String           // official-pdf | none-found
    var documents: [MenuDocument]
    var page: SourceLink?
    var checked: String?
    var keywords: [String]
    var note: String?
    var seeAlso: PlaceReference?
}

struct BridgeInfo: Codable, Hashable, Sendable {
    struct SourceId: Codable, Hashable, Sendable {
        var layer: String
        var id: Int
    }
    var sourceIds: [SourceId]
    var segments: [[[Double]]]   // [lat, lon] pairs per segment
    var locationBasis: String?
}

struct ChargingInfo: Codable, Hashable, Sendable {
    var count: Int
    var network: String?
    var connector: String?
    var maxKw: Double?
    var afdcId: Int?
}

struct DumpStationInfo: Codable, Hashable, Sendable {
    var status: String
    var npsFeatureId: String?
    var osmNodeId: Int?
}

struct WaterIceInfo: Codable, Hashable, Sendable {
    var kind: String             // water | ice
    var type: String?
    var directions: String?
    var locationBasis: String?
    var checked: String?
    var sources: [SourceLink]?
    var evidenceNote: String?    // community-mapped edit date / "source retrieval is not a field check"
    var communityMapped: Bool?
    var warning: String?         // dated, unverified reports carried verbatim from the dataset
}

struct WaterfallLink: Codable, Hashable, Sendable {
    var label: String
    var placeId: String?
    var url: String?
    var note: String?
}

struct WaterfallInfo: Codable, Hashable, Sendable {
    var researchId: String?
    var npsObjectId: Int?
    var npsFeatureId: String?
    var mapSource: String?
    var flowClass: String?       // seasonal | perennial | ephemeral
    var normalSeason: String?
    var height: String?
    var viewing: String?
    var links: [WaterfallLink]?
    var riverContext: Bool?
    var onNpsGuide: Bool?
    var closure: String?
    var closureAsOf: String?
}

enum PlaceKind: String, Codable, Sendable {
    case place, bridge, waterfall, charging, dumpStation = "dump-station", water, ice, facility, shuttleStop = "shuttle-stop", housekeepingUnit = "housekeeping-unit", trail
}

struct Place: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var kind: PlaceKind
    var listed: Bool
    var name: String
    var campus: String
    var categories: [String]
    var latitude: Double
    var longitude: Double
    var mapPriority: Int
    var summary: String
    var hours: [String]
    var accessScope: String?
    var nearbyStops: [Int]
    var phones: [PhoneNumber]
    var accessibility: String?
    var notice: String?
    var sources: [SourceLink]
    var sourceUrl: String?
    var sourceNote: String?
    var tags: [String]
    var checked: String?
    var details: [LabeledText]
    var menus: MenuInfo?
    var glyph: String?
    var facility: String?
    var bridge: BridgeInfo?
    var waterfall: WaterfallInfo?
    var charging: ChargingInfo?
    var dumpStation: DumpStationInfo?
    var waterIce: WaterIceInfo?
    var campgroundId: String?
    var npsBuildingId: Int?
    var stopNumber: Int?
    var routes: [String]?
    var trailId: String?
    var unitNumber: String?
    var guestArea: Bool?
    var npsIds: [Int]?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    var hasToilet: Bool { facility == "toilet" || categories.contains("facilities") && kind == .facility }
    var hasShower: Bool { facility == "shower" }
    var isWater: Bool { kind == .water || facility == "water" }
    var isIce: Bool { kind == .ice }
    var isAccessibleListed: Bool { facility == "accessible-parking" || accessibility != nil }

    static func == (lhs: Place, rhs: Place) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum AccessScope {
    static func title(_ scope: String?) -> String {
        switch scope {
        case "public-day-use": "Public · day use"
        case "registered-guest": "Registered guests"
        case "customer": "Customers"
        case "accessible-placard": "Accessible placard required"
        case "reservation": "Reservation required"
        case "wilderness-permit": "Wilderness permit holders"
        case "unknown", nil: "Access unverified · check posted signs"
        default: scope ?? "Access unverified"
        }
    }
}
