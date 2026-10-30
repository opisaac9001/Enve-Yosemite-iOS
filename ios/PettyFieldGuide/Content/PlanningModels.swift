import Foundation

// MARK: Permits

struct PermitAction: Codable, Hashable, Sendable {
    var label: String
    var url: String
}

struct PermitLink: Codable, Hashable, Sendable {
    var label: String
    var url: String?
    var view: String?
    var regionId: String?
    var note: String?
}

struct EmailContact: Codable, Hashable, Sendable {
    var label: String
    var address: String
}

struct PermitGuide: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var group: String            // visitor | organizer | clarifications
    var title: String
    var plan: String
    var requirement: String      // permit | reservation | license | pass | optional | may-require | no-permit | prohibited | check
    var badgeNote: String?
    var summary: String
    var facts: [LabeledText]
    var sources: [SourceLink]
    var checked: String
    var keywords: [String]
    var phones: [PhoneNumber]?
    var emails: [EmailContact]?
    var places: [String]?
    var links: [PermitLink]?
    var action: PermitAction?
    var notices: [String]?
    var supersedesLink: String?
}

struct PermitGroup: Codable, Hashable, Sendable {
    var title: String
    var anchor: String
    var lede: String
}

struct PermitsPack: Codable, Sendable {
    var guides: [PermitGuide]
    var requirementLabels: [String: String]
    var groups: [String: PermitGroup]
    var sources: [String: SourceLink]
    var fireNotice: String
    var fireNoticeLink: PermitLink
}

// MARK: Contacts

struct ContactNumber: Codable, Hashable, Sendable {
    var label: String
    var number: String
    var note: String?
    var hours: String?
}

struct TextingSupport: Codable, Hashable, Sendable {
    var support: String
    var note: String
}

struct Contact: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var group: String
    var name: String
    var reaches: String
    var numbers: [ContactNumber]
    var hours: [String]
    var location: [String]
    var texting: TextingSupport
    var sources: [SourceLink]
    var placeId: String?
    var checked: String?
    var email: String?
}

struct ContactGroup: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var label: String
}

struct EmergencyShortcut: Codable, Hashable, Sendable {
    var label: String
    var number: String?
    var detail: String?
    var url: String?
    var checked: String?
}

struct EmergencyShortcuts: Codable, Hashable, Sendable {
    var emergency: String
    var conditions: EmergencyShortcut
    var switchboard: EmergencyShortcut
    var roadside: EmergencyShortcut
    var shuttle: EmergencyShortcut
    var fuel: EmergencyShortcut
}

struct ContactsPack: Codable, Sendable {
    var contacts: [Contact]
    var groups: [ContactGroup]
    var emergency: EmergencyShortcuts
}

// MARK: Documents

struct DocumentItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var url: String
    var bundledFile: String
    var bytes: Int
    var sha256: String
    var lastModified: String
    var reviewed: String
    var title: String
    var category: String
    var description: String
    var edition: String
    var validThrough: String?
    var sourcePage: String
    var note: String
    var publisher: String
    var pages: Int
}

// MARK: Changelog

struct ChangelogItem: Codable, Hashable, Sendable {
    var kind: String
    var text: String
    var href: String?
    var linkLabel: String?
}

struct ChangelogEntry: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var date: String
    var deployedAt: String
    var releaseId: String
    var commit: String
    var title: String
    var actionRequired: String?
    var items: [ChangelogItem]
}

// MARK: Regions

struct RegionPoint: Codable, Hashable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double
    var kind: String
    var note: String?
}

struct ParkRegion: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var tagline: String
    var elevationFt: Int
    var driveFromValley: String
    var season: String
    var summary: String
    var highlights: [String]
    var services: [String]
    var cautions: [String]
    var roads: [String]
    var points: [RegionPoint]
    var weatherPoint: String
    var sources: [SourceLink]
}

struct ApproachRoad: Codable, Identifiable, Hashable, Sendable {
    var key: String
    var name: String
    var caltransRoute: String
    var entrance: String
    var from: String
    var season: String
    var notes: [String]
    var id: String { key }
}

struct RegionsPack: Codable, Sendable {
    var regions: [ParkRegion]
    var approaches: [ApproachRoad]
    var gatewayTowns: [RegionPoint]
    var tripFacts: [LabeledDetail]
    var schematicBounds: GeoBounds
    var valleyLandmarks: [ValleyLandmark]
}

struct ValleyLandmark: Codable, Hashable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double
    var edge: String?
}

// MARK: Webcams

struct Webcam: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var group: String
    var provider: String
    var credit: String
    var url: String
    var shows: String
    var medium: String           // stream | still | ptz | map
    var providerStatus: String   // active | inactive | not-stated
    var caveats: [String]
    var checked: String
    var providerId: String?
    var origin: String?
    var sourceUpdated: String?
    var season: String?
    var regionId: String?
    var regionBasis: String?
}

struct WebcamGroup: Codable, Hashable, Sendable {
    var label: String
}

struct WebcamsPack: Codable, Sendable {
    var webcams: [Webcam]
    var providerNotes: [String: String]
    var groups: [String: WebcamGroup]
    var groupOrder: [String]
}

// MARK: Housekeeping

struct HousekeepingPack: Codable, Sendable {
    var details: [LabeledText]
    var sources: [SourceLink]
    var season: String
    var frontDeskPlaceId: String
}
