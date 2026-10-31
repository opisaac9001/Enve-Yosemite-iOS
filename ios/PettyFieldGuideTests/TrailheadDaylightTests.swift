import XCTest
import CoreLocation
@testable import PettyFieldGuide

/// Offline trailhead sun times: Pacific calendar days across daylight-saving changes, and figures that
/// move the right way with season and longitude.
final class TrailheadDaylightTests: XCTestCase {
    private let calendar = YosemiteGeo.calendar
    private let tuolumne = CLLocationCoordinate2D(latitude: 37.877417, longitude: -119.353701)
    private let wawona = CLLocationCoordinate2D(latitude: 37.535055, longitude: -119.657715)
    private let gaylor = CLLocationCoordinate2D(latitude: 37.910225, longitude: -119.258284)

    private func pacific(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func times(_ date: Date, _ c: CLLocationCoordinate2D) -> SolarCalculator.DayTimes {
        SolarCalculator.dayTimes(on: date, at: c, timeZone: YosemiteGeo.timeZone)
    }

    private func wallClockMinutes(_ date: Date) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return parts.hour! * 60 + parts.minute!
    }

    func testDayStepsLandOnWholePacificDaysAcrossTheFallClockChange() {
        // 23:30 on October 31, 2026 (PDT); the clocks fall back at 02:00 on November 1.
        let lateEvening = pacific(2026, 10, 31, 23).addingTimeInterval(30 * 60)
        for (offset, day) in [(0, 31), (1, 1), (2, 2), (-1, 30)] {
            let date = TrailheadDaylight.day(offset: offset, from: lateEvening)
            let parts = calendar.dateComponents([.month, .day, .hour], from: date)
            XCTAssertEqual(parts.day, day, "offset \(offset)")
            XCTAssertEqual(parts.hour, 12, "offset \(offset) stays at local midday")
        }
        XCTAssertEqual(TrailheadDaylight.day(offset: 1, from: lateEvening).timeIntervalSince(TrailheadDaylight.day(offset: 0, from: lateEvening)), 25 * 3600)
    }

    func testSunEventsAreOrderedAndShiftAnHourOnTheWallClockWhenDaylightTimeEnds() throws {
        let saturday = times(pacific(2026, 10, 31), tuolumne)
        let sunday = times(pacific(2026, 11, 1), tuolumne)
        for t in [saturday, sunday] {
            let dawn = try XCTUnwrap(t.civilDawn), rise = try XCTUnwrap(t.sunrise), set = try XCTUnwrap(t.sunset), dusk = try XCTUnwrap(t.civilDusk)
            XCTAssertTrue(dawn < rise && rise < t.solarNoon && t.solarNoon < set && set < dusk)
        }
        let shift = wallClockMinutes(try XCTUnwrap(saturday.sunrise)) - wallClockMinutes(try XCTUnwrap(sunday.sunrise))
        XCTAssertTrue((58...61).contains(shift), "sunrise moves about an hour earlier on the clock, not in the sky (\(shift) min)")
    }

    func testDayLengthFollowsTheSeasonAtTuolumneMeadows() throws {
        func minutes(_ t: SolarCalculator.DayTimes) throws -> Double { try XCTUnwrap(t.sunset).timeIntervalSince(try XCTUnwrap(t.sunrise)) / 60 }
        let june = try minutes(times(pacific(2026, 6, 21), tuolumne))
        let december = try minutes(times(pacific(2026, 12, 21), tuolumne))
        let march = try minutes(times(pacific(2026, 3, 20), tuolumne))
        XCTAssertTrue((14 * 60 + 25...14 * 60 + 50).contains(june), "\(june)")
        XCTAssertTrue((9 * 60 + 30...9 * 60 + 55).contains(december), "\(december)")
        XCTAssertTrue((12 * 60...12 * 60 + 15).contains(march), "refraction makes the equinox day slightly over 12 h (\(march))")
        XCTAssertEqual(TrailheadDaylight.length(times(pacific(2026, 6, 21), tuolumne)), "\(Int(june.rounded()) / 60) h \(Int(june.rounded()) % 60) min")
    }

    func testEasternTrailheadsSeeSolarNoonEarlierByFourMinutesPerDegree() {
        let east = times(pacific(2026, 8, 15), gaylor).solarNoon
        let west = times(pacific(2026, 8, 15), wawona).solarNoon
        let expected = (gaylor.longitude - wawona.longitude) * 4 * 60
        XCTAssertEqual(west.timeIntervalSince(east), expected, accuracy: 1)
    }
}
