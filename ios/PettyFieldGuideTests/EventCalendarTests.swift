import XCTest
@testable import PettyFieldGuide

final class EventCalendarTests: XCTestCase {
    private func event(rules: [EventRule], end: String = "2026-12-31T23:59:59-08:00") -> CuratedEvent {
        CuratedEvent(id: "t", title: "Test", category: "Talk", recurring: true, dateLabel: "", start: "2026-10-01T00:00:00-07:00", end: end, summary: "", schedule: "", location: "", cost: "", registration: "", host: "", sourceUrl: "", checked: "2026-10-01", area: "Yosemite Valley", admission: "free", rules: rules)
    }

    func testWeekdayRecurrenceAcrossDSTChange() {
        // Pacific DST ends 2026-11-01. Sundays from Oct 25 through Nov 15 must be exactly four days.
        let rule = EventRule(from: "2026-10-25", through: "2026-11-15", weekdays: [0], dates: nil, excluded: nil, time: "9 am", minutes: 540, durationMinutes: nil)
        let days = EventCalendar.occurrences(of: event(rules: [rule])).map(\.day)
        XCTAssertEqual(days, ["2026-10-25", "2026-11-01", "2026-11-08", "2026-11-15"])
    }

    func testExplicitDatesAndExclusions() {
        let rule = EventRule(from: "2026-12-01", through: "2026-12-31", weekdays: [0, 1, 2, 3, 4, 5, 6], dates: ["2026-12-08", "2026-12-10", "2027-01-05"], excluded: nil, time: "evening", minutes: nil, durationMinutes: nil)
        XCTAssertEqual(EventCalendar.occurrences(of: event(rules: [rule])).map(\.day), ["2026-12-08", "2026-12-10"])
        let excluded = EventRule(from: "2026-12-01", through: "2026-12-03", weekdays: [0, 1, 2, 3, 4, 5, 6], dates: nil, excluded: ["2026-12-02"], time: "", minutes: nil, durationMinutes: nil)
        XCTAssertEqual(EventCalendar.occurrences(of: event(rules: [excluded])).map(\.day), ["2026-12-01", "2026-12-03"])
    }

    func testMultipleSessionsOnOneDayKeepDistinctRowsAndExactDuplicatesCollapse() {
        let morning = EventRule(from: "2026-11-07", through: "2026-11-07", weekdays: [6], dates: nil, excluded: nil, time: "9 am", minutes: 540, durationMinutes: nil)
        let afternoon = EventRule(from: "2026-11-07", through: "2026-11-07", weekdays: [6], dates: nil, excluded: nil, time: "2 pm", minutes: 840, durationMinutes: nil)
        let occurrences = EventCalendar.occurrences(of: event(rules: [afternoon, morning, morning]))
        XCTAssertEqual(occurrences.map(\.startMinutes), [540, 840], "both published sessions survive, in time order; the repeated rule collapses")
        XCTAssertEqual(occurrences.map(\.timeLabel), ["9 am", "2 pm"])
        XCTAssertEqual(Set(occurrences.map(\.id)).count, 2, "rows on the same day need distinct ids")
    }

    func testSameStartMinuteWithDifferentPublishedLabelsStaysDistinct() {
        let english = EventRule(from: "2026-11-07", through: "2026-11-07", weekdays: [6], dates: nil, excluded: nil, time: "9 am · English", minutes: 540, durationMinutes: nil)
        let spanish = EventRule(from: "2026-11-07", through: "2026-11-07", weekdays: [6], dates: nil, excluded: nil, time: "9 am · Spanish", minutes: 540, durationMinutes: nil)
        let occurrences = EventCalendar.occurrences(of: event(rules: [english, spanish, english]))
        XCTAssertEqual(occurrences.map(\.timeLabel), ["9 am · English", "9 am · Spanish"], "same minute, different published details: both survive; the exact repeat collapses")
        XCTAssertEqual(Set(occurrences.map(\.id)).count, 2)
        XCTAssertNotEqual(EventOccurrence.slotKey(startMinutes: 540, timeLabel: "9 am · English"), EventOccurrence.slotKey(startMinutes: 540, timeLabel: "9 am · Spanish"))
        XCTAssertEqual(EventOccurrence.slotKey(startMinutes: nil, timeLabel: "evening"), EventOccurrence.slotKey(startMinutes: nil, timeLabel: "evening"))
    }

    func testExplicitDatesHonourExclusions() {
        let rule = EventRule(from: "2026-12-01", through: "2026-12-31", weekdays: [], dates: ["2026-12-08", "2026-12-10", "2026-12-15"], excluded: ["2026-12-10"], time: "", minutes: nil, durationMinutes: nil)
        XCTAssertEqual(EventCalendar.occurrences(of: event(rules: [rule])).map(\.day), ["2026-12-08", "2026-12-15"])
    }

    func testListingThatEndedEarlierTodayStaysOnTodaysAgendaOnly() {
        func occurrence(_ day: String) -> EventOccurrence {
            EventOccurrence(source: .curated("t"), day: day, startMinutes: 540, timeLabel: "9 am", title: "Class", category: "Talk", area: "Yosemite Valley", admission: "free", regionId: nil, ended: true)
        }
        let today = "2026-10-26"
        XCTAssertTrue(EventCalendar.matches(occurrence(today), filter: EventFilter(), custom: [], today: today), "ended at 1 pm, still today's civil date")
        XCTAssertFalse(EventCalendar.matches(occurrence("2026-10-25"), filter: EventFilter(), custom: [], today: today))
        var showEnded = EventFilter(); showEnded.showEnded = true
        XCTAssertTrue(EventCalendar.matches(occurrence("2026-10-25"), filter: showEnded, custom: [], today: today))
    }

    func testBundledMultiRuleProgramsKeepEverySession() throws {
        let content = try BundleContent.load()
        let snowGlobe = try XCTUnwrap(content.event("tenaya-snowglobe-2026"))
        let snow = EventCalendar.occurrences(of: snowGlobe)
        XCTAssertEqual(snow.count, snowGlobe.rules.flatMap { $0.dates ?? [] }.count, "every explicit date from both rules is a session")
        XCTAssertEqual(Set(snow.map(\.startMinutes)), [600, 840])
        XCTAssertEqual(Set(snow.map(\.id)).count, snow.count)

        let photo = try XCTUnwrap(content.event("smartphone-photo-2026"))
        let sessions = EventCalendar.occurrences(of: photo)
        XCTAssertEqual(Set(sessions.map(\.id)).count, sessions.count)
        for s in sessions {
            let weekday = EventCalendar.calendar.component(.weekday, from: EventCalendar.date(s.day)!) - 1
            XCTAssertEqual(s.startMinutes, weekday == 3 ? 540 : 780, "\(s.day): Wednesdays run at 9 am, Saturdays at 1 pm")
        }
        XCTAssertTrue(sessions.contains { $0.startMinutes == 540 } && sessions.contains { $0.startMinutes == 780 })
    }

    func testEndedFlagUsesPacificEnd() {
        let rule = EventRule(from: "2026-01-05", through: "2026-01-05", weekdays: [1], dates: nil, excluded: nil, time: "", minutes: nil, durationMinutes: nil)
        let past = event(rules: [rule], end: "2026-01-05T23:59:59-08:00")
        XCTAssertTrue(EventCalendar.occurrences(of: past, now: DateText.parse("2026-01-06T12:00:00-08:00")!).first!.ended)
        XCTAssertFalse(EventCalendar.occurrences(of: past, now: DateText.parse("2026-01-05T12:00:00-08:00")!).first!.ended)
    }

    func testFilterEncodingRoundTrip() {
        var f = EventFilter()
        f.regions = ["Yosemite Valley"]
        f.excludeTitles = ["Karaoke"]
        f.showEnded = true
        let encoded = f.encoded()!
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(EventFilter.decode(encoded), f)
        XCTAssertNil(EventFilter.decode("not base64!!"))
    }

    func testMonthGridStartsOnSundayWithSixWeeks() {
        let month = EventCalendar.date("2026-11-10")!
        let days = EventCalendar.gridDays(for: month)
        XCTAssertEqual(days.count, 42)
        XCTAssertEqual(EventCalendar.calendar.component(.weekday, from: days[0]), 1)
        XCTAssertEqual(EventCalendar.day(days[0]), "2026-11-01")
    }
}
