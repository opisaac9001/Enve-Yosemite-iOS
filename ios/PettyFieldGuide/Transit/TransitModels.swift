import Foundation

/// Static NPS GTFS timetable pack. Times at intermediate stops are interpolated by the feed
/// builder; nothing here is a live prediction.
struct TransitFeedPack: Codable, Sendable {
    var version: String
    var fetchedAt: String
    var note: String
    var feeds: [TransitFeed]
}

struct TransitFeed: Codable, Identifiable, Sendable {
    var id: String
    var label: String
    var source: String
    var feedVersion: String
    var validFrom: String
    var validTo: String
    var routes: [TransitRoute]
}

struct TransitRoute: Codable, Identifiable, Sendable {
    var id: String
    var appRoute: String?
    var name: String
    var color: String
    var loopMinutes: Double
    var origin: String
    var wheelchairAccessible: Bool
    var stops: [TransitStopTime]
    var services: [TransitService]
    var shape: [[Double]]        // [lat, lon]
}

struct TransitStopTime: Codable, Hashable, Sendable {
    var gtfsId: String
    var name: String
    var placeId: String?
    var latitude: Double
    var longitude: Double
    var offsetMin: Double
    var published: Bool
}

struct TransitService: Codable, Sendable {
    var serviceId: String
    var days: String             // seven chars Monday…Sunday, "1" = runs
    var from: String
    var to: String
    var departures: [String]     // HH:mm at origin
    var headwayMin: Headway
    var exceptions: [ServiceException]?

    struct Headway: Codable, Sendable {
        var min: Double
        var max: Double
    }

    struct ServiceException: Codable, Sendable {
        var date: String
        var type: Int            // GTFS calendar_dates: 1 added, 2 removed
    }
}
