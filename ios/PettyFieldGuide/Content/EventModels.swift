import Foundation

struct EventRule: Codable, Hashable, Sendable {
    var from: String             // yyyy-MM-dd (Pacific civil date)
    var through: String
    var weekdays: [Int]          // 0 = Sunday … 6 = Saturday
    var dates: [String]?         // explicit occurrence dates when published
    var excluded: [String]?
    var time: String
    var minutes: Int?            // start minute of day when a clock time is published
    var durationMinutes: Int?
}

struct CuratedEvent: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var category: String
    var recurring: Bool
    var dateLabel: String
    var start: String            // ISO 8601 with offset
    var end: String
    var summary: String
    var schedule: String
    var location: String
    var cost: String
    var registration: String
    var host: String
    var sourceUrl: String
    var checked: String
    var area: String
    var admission: String        // free | paid | restricted | unknown
    var rules: [EventRule]
    var placeId: String?
    var sourceDate: String?
    var preparation: String?
    var preparationUrl: String?
    var registrationUrl: String?
    var admissionLabel: String?
    var featured: Bool?
}

struct NPSEventMapping: Codable, Hashable, Sendable {
    var npsId: String
    var eventId: String
    var npsTitle: String
    var curatedId: String
}

struct EventsPack: Codable, Sendable {
    var events: [CuratedEvent]
    var npsMapping: [NPSEventMapping]
    var npsAreaRegions: [String: String]
}
