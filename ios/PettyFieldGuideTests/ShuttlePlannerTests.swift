import XCTest
@testable import PettyFieldGuide

final class ShuttlePlannerTests: XCTestCase {
    private func feed() throws -> TransitFeedPack {
        try BundleContent.decode(TransitFeedPack.self, "transit.json", subdirectory: "Geo")
    }

    private func valley() throws -> TransitFeed { try XCTUnwrap(feed().feeds.first { $0.id == "valley" }) }

    private func pacific(_ day: String, _ hhmm: String) -> Date {
        let f = DateFormatter()
        f.calendar = YosemiteGeo.calendar
        f.timeZone = YosemiteGeo.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(day) \(hhmm)")!
    }

    func testDefaultTripStop1ToStop16At9am() throws {
        let plans = ShuttlePlanner.plan(feed: try valley(), from: "shuttle-1", to: "shuttle-16", at: pacific("2026-10-27", "09:00"))
        let first = try XCTUnwrap(plans.first)
        XCTAssertEqual(first.legs.count, 1)
        XCTAssertEqual(DateText.time(first.departure), DateText.time(pacific("2026-10-27", "09:00")))
        XCTAssertGreaterThan(first.arrival, first.departure)
        // Both Valleywide and East Valley serve stop 1 and stop 16; the alternative should use the other route.
        XCTAssertTrue(plans.count >= 2)
        XCTAssertNotEqual(plans[0].legs[0].routeId, plans.first { $0.legs[0].routeId != plans[0].legs[0].routeId }?.legs[0].routeId ?? plans[0].legs[0].routeId)
    }

    func testValleywidePublishesItsReturnAndWrapsThroughOrigin() throws {
        let route = try XCTUnwrap(try valley().routes.first { $0.id == "valleywide" })
        let order = ShuttlePlanner.stopOrder(route)
        XCTAssertTrue(order.closesLoop)
        XCTAssertEqual(order.stops.count, route.stops.count - 1)
        XCTAssertEqual(order.stops.last?.placeId, "shuttle-19")
        XCTAssertEqual(order.cycleMinutes, route.stops.last?.offsetMin)
        // Stop 16 (Happy Isles) is after stop 7 (Lodge) in the loop; the reverse direction must wrap.
        let forward = ShuttlePlanner.directLegs(route: route, from: "shuttle-7", to: "shuttle-16", day: "2026-10-27", after: pacific("2026-10-27", "10:00"), limit: 1)
        let backward = ShuttlePlanner.directLegs(route: route, from: "shuttle-16", to: "shuttle-7", day: "2026-10-27", after: pacific("2026-10-27", "10:00"), limit: 1)
        XCTAssertFalse(forward[0].passesOrigin)
        XCTAssertTrue(backward[0].passesOrigin)
        XCTAssertEqual(forward[0].stopSequence.first?.placeId, "shuttle-7")
        XCTAssertEqual(forward[0].stopSequence.last?.placeId, "shuttle-16")
        // Published offsets: stop 7 at 20.3 min, stop 16 at 74.2 min, cycle 90 min.
        let forwardRide = forward[0].arrival.timeIntervalSince(forward[0].departure)
        let backwardRide = backward[0].arrival.timeIntervalSince(backward[0].departure)
        XCTAssertEqual(forwardRide, (74.2 - 20.3) * 60, accuracy: 1)
        XCTAssertEqual(backwardRide, (90 - 74.2 + 20.3) * 60, accuracy: 1)
        XCTAssertEqual(forwardRide + backwardRide, order.cycleMinutes * 60, accuracy: 1, "both directions together make exactly one published cycle")
        XCTAssertEqual(backward[0].stopSequence.map(\.placeId), ["shuttle-16", "shuttle-17", "shuttle-18", "shuttle-19", "shuttle-1", "shuttle-2", "shuttle-3", "shuttle-4", "shuttle-5", "shuttle-6", "shuttle-7"])
    }

    func testEastValleyKeepsItsTerminusAndNeverInventsAReturn() throws {
        let route = try XCTUnwrap(try valley().routes.first { $0.id == "eastvalley" })
        let order = ShuttlePlanner.stopOrder(route)
        XCTAssertFalse(order.closesLoop)
        XCTAssertEqual(order.stops.count, route.stops.count)
        XCTAssertEqual(order.stops.last?.placeId, "shuttle-19")

        let toTerminus = ShuttlePlanner.directLegs(route: route, from: "shuttle-1", to: "shuttle-19", day: "2026-10-27", after: pacific("2026-10-27", "09:00"), limit: 1)
        XCTAssertEqual(toTerminus.count, 1)
        XCTAssertFalse(toTerminus[0].passesOrigin)
        XCTAssertEqual(toTerminus[0].arrival.timeIntervalSince(toTerminus[0].departure), 50 * 60, accuracy: 1)
        XCTAssertEqual(toTerminus[0].stopSequence.last?.placeId, "shuttle-19")

        XCTAssertTrue(ShuttlePlanner.directLegs(route: route, from: "shuttle-18", to: "shuttle-1", day: "2026-10-27", after: pacific("2026-10-27", "09:00")).isEmpty,
                      "stop 18 → 1 is not published on East Valley and must not be synthesized")
        XCTAssertFalse(ShuttlePlanner.timetable(route: route, placeId: "shuttle-19", day: "2026-10-27").isEmpty)

        // Going back from 18 to 1 is only possible on Valleywide (which does publish its return) or via a transfer.
        let plans = ShuttlePlanner.plan(feed: try valley(), from: "shuttle-18", to: "shuttle-1", at: pacific("2026-10-27", "09:00"), limit: 6)
        XCTAssertFalse(plans.isEmpty)
        for plan in plans {
            for leg in plan.legs where leg.routeId == "eastvalley" {
                XCTAssertFalse(leg.passesOrigin, "East Valley legs must not wrap")
            }
        }
    }

    func testServiceCalendarRespectsValidityAndWeekdays() throws {
        let service = TransitService(serviceId: "weekend", days: "0000011", from: "2026-06-01", to: "2026-06-30", departures: ["08:00"], headwayMin: .init(min: 15, max: 15), exceptions: [.init(date: "2026-06-06", type: 2), .init(date: "2026-06-08", type: 1)])
        XCTAssertTrue(ShuttlePlanner.serviceRuns(service, on: "2026-06-07"))   // Sunday
        XCTAssertFalse(ShuttlePlanner.serviceRuns(service, on: "2026-06-09"))  // Tuesday
        XCTAssertFalse(ShuttlePlanner.serviceRuns(service, on: "2026-06-06"))  // removed Saturday
        XCTAssertTrue(ShuttlePlanner.serviceRuns(service, on: "2026-06-08"))   // added Monday
        XCTAssertFalse(ShuttlePlanner.serviceRuns(service, on: "2026-07-04"))  // outside validity
    }

    func testTransferAllowance() throws {
        // Stop 9 (El Capitan Meadow) is Valleywide-only; stop 17 is shared. A forced transfer plan must respect the allowance.
        let plans = ShuttlePlanner.plan(feed: try valley(), from: "shuttle-9", to: "shuttle-17", at: pacific("2026-10-27", "09:00"), limit: 6)
        XCTAssertFalse(plans.isEmpty)
        for plan in plans where plan.legs.count == 2 {
            XCTAssertGreaterThanOrEqual(plan.transferMinutes ?? 0, ShuttlePlanner.transferAllowanceMinutes)
        }
    }

    func testNoServiceAfterLastDeparture() throws {
        let plans = ShuttlePlanner.plan(feed: try valley(), from: "shuttle-1", to: "shuttle-16", at: pacific("2026-10-27", "23:30"))
        XCTAssertTrue(plans.isEmpty)
    }

    func testNoServiceOutsideFeedValidity() throws {
        let plans = ShuttlePlanner.plan(feed: try valley(), from: "shuttle-1", to: "shuttle-16", at: pacific("2027-03-01", "09:00"))
        XCTAssertTrue(plans.isEmpty)
    }
}
