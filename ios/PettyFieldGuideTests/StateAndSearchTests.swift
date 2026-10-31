import XCTest
@testable import PettyFieldGuide

final class StateAndSearchTests: XCTestCase {
    func testSnapshotExpiry() {
        let fresh = Snapshot(payload: ["a": 1], acquiredAt: Date().addingTimeInterval(-600), retrievedAt: Date())
        XCTAssertEqual(fresh.freshness(staleAfter: 3600), .ready)
        let stale = Snapshot(payload: ["a": 1], acquiredAt: Date().addingTimeInterval(-2 * 3600), retrievedAt: Date())
        XCTAssertEqual(stale.freshness(staleAfter: 3600), .stale)
        let expired = Snapshot(payload: ["a": 1], acquiredAt: Date().addingTimeInterval(-49 * 3600), retrievedAt: Date())
        XCTAssertTrue(expired.isExpired)
        XCTAssertEqual(expired.freshness(staleAfter: 3600), .expired)
    }

    private func conditionsFeed(fetchedAt: String) -> ConditionsFeed {
        let empty = NoticeList(state: "ready", checkedAt: fetchedAt, items: [])
        return ConditionsFeed(kind: "conditions", version: 1, fetchedAt: fetchedAt, page: empty, roadEvents: empty, alerts: empty, wilderness: empty, statuses: [])
    }

    func testOldPayloadOverFreshResponseStaysExpired() throws {
        let now = Date()
        let old = conditionsFeed(fetchedAt: DateText.isoString(now.addingTimeInterval(-50 * 3600)))
        let snapshot = try Snapshot.received(old, at: now)
        XCTAssertTrue(snapshot.isExpired, "a 50-hour-old payload must not get a new 48-hour clock just because the HTTP response is new")
        XCTAssertTrue(snapshot.servedFromServerCache)
        XCTAssertEqual(snapshot.retrievedAt, now)

        let current = try Snapshot.received(conditionsFeed(fetchedAt: DateText.isoString(now.addingTimeInterval(-30))), at: now)
        XCTAssertEqual(current.freshness(staleAfter: 3600), .ready)
        XCTAssertFalse(current.servedFromServerCache)
    }

    func testPayloadsWithUnusableAcquisitionTimesAreRejected() {
        XCTAssertThrowsError(try Snapshot.received(conditionsFeed(fetchedAt: "yesterday"))) { error in
            XCTAssertEqual(error as? SnapshotError, .unreadableAcquisitionTime("yesterday"))
        }
        let future = DateText.isoString(Date().addingTimeInterval(3 * 3600))
        XCTAssertThrowsError(try Snapshot.received(conditionsFeed(fetchedAt: future))) { error in
            XCTAssertEqual(error as? SnapshotError, .acquisitionTimeInFuture(future))
        }
    }

    func testSearchParsesCampsiteQueries() throws {
        let content = try BundleContent.load()
        let index = SearchIndex(content: content)
        let hit = try XCTUnwrap(index.search("Upper Pines site 18").first)
        XCTAssertEqual(hit.kind, .campsite)
        XCTAssertEqual(hit.siteScope, "cg-upper-pines")
        XCTAssertEqual(hit.siteNumber, "18")
        if case .site(let cg, let ridb)? = hit.mapFocus {
            XCTAssertEqual(cg, "cg-upper-pines")
            XCTAssertEqual(ridb, content.campsites.first { $0.campground == "cg-upper-pines" && $0.displayNumber == "18" }?.ridbId)
        } else {
            XCTFail("campsite query should focus the map on the site")
        }
        let housekeeping = try XCTUnwrap(index.search("Housekeeping site 179").first)
        XCTAssertEqual(housekeeping.kind, .campsite)
        XCTAssertEqual(housekeeping.siteNumber, "179")
    }

    func testSearchMatchesPhoneDigits() throws {
        let content = try BundleContent.load()
        let index = SearchIndex(content: content)
        let hits = index.search("209-372-0200")
        XCTAssertTrue(hits.contains { $0.phoneDigits?.contains("2093720200") == true })
    }

    func testContentPacksDecodeWithExpectedCoverage() throws {
        let content = try BundleContent.load()
        XCTAssertGreaterThanOrEqual(content.places.filter(\.listed).count, 240)
        XCTAssertEqual(content.trails.trails.filter(\.isValley).count, 12)
        XCTAssertEqual(content.trails.trails.filter { !$0.isValley }.count, 40)
        XCTAssertEqual(content.campgrounds.campgrounds.count, 13)
        XCTAssertGreaterThanOrEqual(content.events.events.count, 140)
        XCTAssertEqual(content.documents.count, 5)
        XCTAssertEqual(content.status.forecastPoints.count, 7)
        XCTAssertEqual(content.status.fireRegions.count, 15)
        XCTAssertEqual(content.webcams.webcams.count, 12)
        XCTAssertEqual(content.campsites.count, 1471)
    }

    func testSolarTimesForValleyOnKnownDate() {
        let day = DateText.parse("2026-06-21T12:00:00-07:00")!
        let times = SolarCalculator.dayTimes(on: day, at: YosemiteGeo.valleyCenter, timeZone: YosemiteGeo.timeZone)
        // NOAA: sunrise about 05:38, sunset about 20:26 PDT on the June solstice at 37.75°N, 119.59°W.
        let rise = YosemiteGeo.calendar.dateComponents([.hour, .minute], from: times.sunrise!)
        let set = YosemiteGeo.calendar.dateComponents([.hour, .minute], from: times.sunset!)
        XCTAssertEqual(rise.hour, 5); XCTAssertTrue((35...42).contains(rise.minute!))
        XCTAssertEqual(set.hour, 20); XCTAssertTrue((22...30).contains(set.minute!))
        let noon = SolarCalculator.position(at: times.solarNoon, coordinate: YosemiteGeo.valleyCenter)
        XCTAssertGreaterThan(noon.altitude, 75)
    }
}
