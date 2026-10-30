import Foundation

/// Offline GTFS-based planning over the bundled timetable. Everything is scheduled time:
/// no live arrivals, no walking times.
struct PlannedTrip: Identifiable, Hashable, Sendable {
    struct Leg: Hashable, Sendable {
        let routeId: String
        let routeName: String
        let colorHex: String
        let boardStop: TransitStopTime
        let alightStop: TransitStopTime
        let departure: Date
        let arrival: Date
        let stopSequence: [TransitStopTime]   // directed order from board to alight
        let passesOrigin: Bool                // ride continues through the loop origin
    }

    let legs: [Leg]
    let transferMinutes: Int?
    var id: String { legs.map { "\($0.routeId)-\($0.departure.timeIntervalSince1970)" }.joined(separator: "+") }
    var departure: Date { legs.first!.departure }
    var arrival: Date { legs.last!.arrival }
    var totalMinutes: Int { Int(arrival.timeIntervalSince(departure) / 60) }
}

/// A route's stops in travel order. `closesLoop` is true only when the feed itself publishes the
/// return to the first stop; a route that ends elsewhere keeps its terminus and never wraps.
struct StopOrder: Sendable {
    let stops: [TransitStopTime]
    let closesLoop: Bool
    let cycleMinutes: Double
}

enum ShuttlePlanner {
    static let transferAllowanceMinutes = 5

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = YosemiteGeo.calendar
        f.timeZone = YosemiteGeo.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// Whether a service runs on the given Pacific day.
    static func serviceRuns(_ service: TransitService, on day: String) -> Bool {
        if let exceptions = service.exceptions, let e = exceptions.first(where: { $0.date == day }) { return e.type == 1 }
        guard day >= service.from && day <= service.to, let date = EventCalendar.date(day) else { return false }
        let weekday = YosemiteGeo.calendar.component(.weekday, from: date)   // 1 = Sunday
        let index = (weekday + 5) % 7                                         // GTFS: 0 = Monday
        let chars = Array(service.days)
        return index < chars.count && chars[index] == "1"
    }

    /// Origin departures on a day as absolute dates.
    static func departures(route: TransitRoute, day: String) -> [Date] {
        route.services.filter { serviceRuns($0, on: day) }.flatMap { service in
            service.departures.compactMap { timeFormatter.date(from: "\(day) \($0)") }
        }.sorted()
    }

    static func stopOrder(_ route: TransitRoute) -> StopOrder {
        guard route.stops.count > 1, let first = route.stops.first, let last = route.stops.last else {
            return StopOrder(stops: route.stops, closesLoop: false, cycleMinutes: route.loopMinutes)
        }
        let returnsToOrigin = last.gtfsId == first.gtfsId || (last.placeId != nil && last.placeId == first.placeId)
        guard returnsToOrigin else { return StopOrder(stops: route.stops, closesLoop: false, cycleMinutes: route.loopMinutes) }
        return StopOrder(stops: Array(route.stops.dropLast()), closesLoop: true, cycleMinutes: last.offsetMin)
    }

    private static func index(of placeId: String, in seq: [TransitStopTime]) -> Int? {
        seq.firstIndex { $0.placeId == placeId }
    }

    /// Direct legs from one stop place to another on a route, for departures at or after `after`.
    static func directLegs(route: TransitRoute, from: String, to: String, day: String, after: Date, limit: Int = 3) -> [PlannedTrip.Leg] {
        let order = stopOrder(route)
        let seq = order.stops
        guard let a = index(of: from, in: seq), let b = index(of: to, in: seq), a != b else { return [] }
        let wraps = b < a
        if wraps && !order.closesLoop { return [] }
        let rideMinutes = wraps ? (order.cycleMinutes - seq[a].offsetMin + seq[b].offsetMin) : (seq[b].offsetMin - seq[a].offsetMin)
        let stops: [TransitStopTime] = wraps ? Array(seq[a...]) + Array(seq[...b]) : Array(seq[a...b])
        var legs: [PlannedTrip.Leg] = []
        for origin in departures(route: route, day: day) {
            let boardTime = origin.addingTimeInterval(seq[a].offsetMin * 60)
            guard boardTime >= after else { continue }
            legs.append(PlannedTrip.Leg(routeId: route.id, routeName: route.name, colorHex: route.color, boardStop: seq[a], alightStop: seq[b],
                                        departure: boardTime, arrival: boardTime.addingTimeInterval(rideMinutes * 60), stopSequence: stops, passesOrigin: wraps))
            if legs.count >= limit { break }
        }
        return legs
    }

    /// Earliest-arrival plans (direct first, then one-transfer) sorted by arrival.
    static func plan(feed: TransitFeed, from: String, to: String, at time: Date, limit: Int = 4) -> [PlannedTrip] {
        let day = EventCalendar.day(time)
        var trips: [PlannedTrip] = []
        for route in feed.routes {
            for leg in directLegs(route: route, from: from, to: to, day: day, after: time, limit: 2) {
                trips.append(PlannedTrip(legs: [leg], transferMinutes: nil))
            }
        }
        // One transfer at any stop shared by two routes.
        for first in feed.routes {
            let seq1 = stopOrder(first).stops
            guard index(of: from, in: seq1) != nil, index(of: to, in: seq1) == nil else { continue }
            for second in feed.routes where second.id != first.id {
                let seq2 = stopOrder(second).stops
                guard index(of: to, in: seq2) != nil else { continue }
                let shared = seq1.compactMap(\.placeId).filter { pid in seq2.contains { $0.placeId == pid } && pid != from && pid != to }
                for transfer in Set(shared) {
                    for leg1 in directLegs(route: first, from: from, to: transfer, day: day, after: time, limit: 1) {
                        let earliest = leg1.arrival.addingTimeInterval(Double(transferAllowanceMinutes) * 60)
                        for leg2 in directLegs(route: second, from: transfer, to: to, day: day, after: earliest, limit: 1) {
                            trips.append(PlannedTrip(legs: [leg1, leg2], transferMinutes: Int(leg2.departure.timeIntervalSince(leg1.arrival) / 60)))
                        }
                    }
                }
            }
        }
        var seen = Set<String>()
        return trips.sorted { ($0.arrival, $0.legs.count) < ($1.arrival, $1.legs.count) }.filter { seen.insert($0.id).inserted }.prefix(limit).map { $0 }
    }

    /// Scheduled times at one stop on one route for a day.
    static func timetable(route: TransitRoute, placeId: String, day: String) -> [Date] {
        let seq = stopOrder(route).stops
        guard let i = index(of: placeId, in: seq) else { return [] }
        return departures(route: route, day: day).map { $0.addingTimeInterval(seq[i].offsetMin * 60) }
    }
}
