import XCTest
@testable import PettyFieldGuide

final class DeepGuideTests: XCTestCase {
    // MARK: Water & ice guide

    private func waterGuide() throws -> (pack: WaterIcePack, records: [WaterIceRecord], content: Content) {
        let content = try BundleContent.load()
        let pack = try WaterIcePack.load()
        return (pack, WaterIceGuide.records(from: pack, content: content), content)
    }

    func testBundledWaterPackKeepsEveryRecordSubtypeAndLicence() throws {
        let (pack, records, content) = try waterGuide()
        XCTAssertEqual(records.count, 46)
        XCTAssertEqual(Set(records.map(\.id)).count, 46)
        XCTAssertEqual(records.filter { $0.type == .faucet }.count, 19)
        XCTAssertEqual(records.filter { $0.type == .drinkingWater }.count, 14)
        XCTAssertEqual(records.filter { $0.type == .bottleFiller }.count, 6)
        XCTAssertEqual(records.filter { $0.type == .iceMachine }.count, 7)
        XCTAssertEqual(WaterIceGuide.filtered(records, filter: .all, query: "").count, 46)
        XCTAssertEqual(WaterIceGuide.filtered(records, filter: .allWater, query: "").count, 39, "drinking-water points stay inside All water")
        XCTAssertEqual(WaterIceGuide.filtered(records, filter: .faucets, query: "").count, 19)
        XCTAssertEqual(WaterIceGuide.filtered(records, filter: .bottleFillers, query: "").count, 6)
        XCTAssertEqual(WaterIceGuide.filtered(records, filter: .iceMachines, query: "").count, 7)

        XCTAssertEqual(pack.license, "ODbL 1.0")
        XCTAssertTrue(pack.attribution.contains("OpenStreetMap"))
        XCTAssertEqual(pack.checked, "2026-09-25")
        XCTAssertNotNil(URL(string: pack.licenseUrl))
        XCTAssertNotNil(WaterIcePack.bundledURL, "export shares the bundled file, so it must exist in the bundle")

        for r in records {
            let place = try XCTUnwrap(content.place(r.id), r.id)
            XCTAssertEqual(r.summary, place.summary, "directory wording is used for the summary")
            XCTAssertFalse(r.sources.isEmpty, r.id)
            XCTAssertFalse(r.area.isEmpty, r.id)
            XCTAssertNotNil(r.directions, r.id)
            XCTAssertNotNil(r.locationBasis, r.id)
        }
    }

    func testWaterGuideQueryMatchesNamesAreasDirectionsAndEvidence() throws {
        let records = try waterGuide().records
        XCTAssertEqual(WaterIceGuide.filtered(records, filter: .all, query: "HEMLOCK").map(\.id), ["ice-lodge-hemlock"])
        XCTAssertEqual(WaterIceGuide.filtered(records, filter: .all, query: "Mariposa Grove").count, 2)
        XCTAssertEqual(WaterIceGuide.filtered(records, filter: .iceMachines, query: "mariposa").count, 0, "type filter and query combine")
        XCTAssertEqual(WaterIceGuide.filtered(records, filter: .faucets, query: "   ").count, 19, "blank queries do not filter")
        XCTAssertTrue(WaterIceGuide.filtered(records, filter: .all, query: "zzzz-nothing").isEmpty)

        let pines = WaterIceGuide.filtered(records, filter: .all, query: "upper pines bathroom")
        XCTAssertFalse(pines.isEmpty)
        XCTAssertTrue(pines.allSatisfy { $0.searchText.contains("upper pines") }, "every token must match")

        let evidence = WaterIceGuide.filtered(records, filter: .all, query: "community mapped")
        XCTAssertEqual(evidence.count, records.filter(\.communityMapped).count, "evidence text is searchable")
        XCTAssertFalse(WaterIceGuide.filtered(records, filter: .all, query: "registered guests").isEmpty, "access wording is searchable")
    }

    func testWaterPointsBeyondTheValleyFocusTheirPinAndExternalLinksKeepCoordinates() throws {
        let (pack, records, _) = try waterGuide()
        let beyondValley = records.filter { !YosemiteGeo.valleyBounds.contains(latitude: $0.latitude, longitude: $0.longitude) }
        XCTAssertEqual(Set(beyondValley.map(\.id)), ["fac-water-mariposa-grove-trailhead-drinking-water", "fac-water-mariposa-grove-welcome-plaza-drinking-water"])
        XCTAssertTrue(records.allSatisfy(\.isOnMap), "every record lies on the continuous park map")
        for r in beyondValley {
            XCTAssertEqual(WaterIceGuide.action(for: r), .focusMap(placeId: r.id), "Mariposa Grove is on the map, so its own pin is focused")
            let raw = try XCTUnwrap(pack.places.first { $0.id == r.id })
            let url = try XCTUnwrap(WaterIceGuide.externalMapURL(for: r))
            XCTAssertEqual(url.host, "maps.apple.com")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items.first { $0.name == "ll" }?.value, "\(raw.latitude),\(raw.longitude)", "coordinates pass through unchanged")
            XCTAssertEqual(items.first { $0.name == "q" }?.value, r.name)
        }
        let inside = try XCTUnwrap(records.first { $0.id == "ice-lodge-hemlock" })
        XCTAssertEqual(WaterIceGuide.action(for: inside), .focusMap(placeId: "ice-lodge-hemlock"))
    }

    func testOldRepairReportStaysOldAndUnverified() throws {
        let records = try waterGuide().records
        let tap = try XCTUnwrap(records.first { $0.id == "water-osm-3453503953" })
        XCTAssertTrue(tap.communityMapped)
        XCTAssertEqual(tap.evidenceNote?.contains("2015-04-13"), true)
        let warning = try XCTUnwrap(tap.warning)
        XCTAssertTrue(warning.contains("2015"))
        XCTAssertNil(tap.caveat, "the dated warning replaces the generic caveat rather than stacking with it")
        XCTAssertEqual(records.filter { $0.warning != nil }.count, 1, "only the dataset's one flagged record carries a warning")
        XCTAssertEqual(records.filter(\.communityMapped).count, 13)
        XCTAssertTrue(WaterIceGuide.oldReportLabel.contains("not a current status"))
        for r in records where r.warning == nil {
            XCTAssertNotNil(r.caveat, "\(r.id) keeps the recorded-not-live caveat")
        }
    }

    // MARK: Program catalog

    private func at(_ iso: String) -> Date { DateText.parse(iso)! }

    private func rule(from: String, through: String, weekdays: [Int], dates: [String]? = nil, excluded: [String]? = nil, minutes: Int? = nil) -> EventRule {
        EventRule(from: from, through: through, weekdays: weekdays, dates: dates, excluded: excluded, time: "", minutes: minutes, durationMinutes: nil)
    }

    private func program(id: String, title: String, area: String = "Yosemite Valley", end: String, rules: [EventRule]) -> CuratedEvent {
        CuratedEvent(id: id, title: title, category: "Talk", recurring: rules.count > 1, dateLabel: "", start: "2026-10-01T00:00:00-07:00", end: end,
                     summary: "", schedule: "", location: "", cost: "", registration: "", host: "", sourceUrl: "", checked: "2026-10-01",
                     area: area, admission: "free", rules: rules)
    }

    func testProgramEndedEarlierTodayStaysVisibleWithEndedStatus() {
        // 9 am–1 pm class on Monday 2026-10-26.
        let entries = ProgramCatalog.entries(for: [program(id: "p", title: "Class", end: "2026-10-26T13:00:00-07:00",
                                                           rules: [rule(from: "2026-10-26", through: "2026-10-26", weekdays: [1], minutes: 540)])])
        let entry = entries[0]
        XCTAssertEqual(entry.lastDay, "2026-10-26")

        XCTAssertEqual(ProgramCatalog.status(of: entry, now: at("2026-10-26T08:00:00-07:00")), .inProgress(next: "2026-10-26"))
        XCTAssertEqual(ProgramCatalog.status(of: entry, now: at("2026-10-26T10:00:00-07:00")), .inProgress(next: nil))
        XCTAssertEqual(ProgramCatalog.status(of: entry, now: at("2026-10-26T15:00:00-07:00")), .ended)

        let afternoon = ProgramCatalog.cards(from: entries, filter: EventFilter(), custom: [], now: at("2026-10-26T15:00:00-07:00"))
        XCTAssertEqual(afternoon.visible.map(\.id), ["p"], "ended earlier today but still today's civil date")
        XCTAssertEqual(afternoon.visible.first?.status, .ended)
        XCTAssertEqual(afternoon.hiddenEnded, 0)
        XCTAssertEqual(afternoon.visible.first?.statusLabel(today: "2026-10-26").hasPrefix("Ended"), true)

        let tomorrow = ProgramCatalog.cards(from: entries, filter: EventFilter(), custom: [], now: at("2026-10-27T09:00:00-07:00"))
        XCTAssertTrue(tomorrow.visible.isEmpty)
        XCTAssertEqual(tomorrow.hiddenEnded, 1)
        var showEnded = EventFilter()
        showEnded.showEnded = true
        let shown = ProgramCatalog.cards(from: entries, filter: showEnded, custom: [], now: at("2026-10-27T09:00:00-07:00"))
        XCTAssertEqual(shown.visible.first?.status, .ended)
        XCTAssertEqual(shown.hiddenEnded, 0)
    }

    func testEndOfDayListingHiddenOnlyAfterPacificMidnight() {
        // Thursday 2026-12-31, no clock time, listing ends 23:59:59 Pacific.
        let lastDay = ProgramCatalog.entries(for: [program(id: "nye", title: "Year end", end: "2026-12-31T23:59:59-08:00",
                                                           rules: [rule(from: "2026-12-31", through: "2026-12-31", weekdays: [4])])])[0]
        let lateEvening = at("2026-12-31T23:30:00-08:00")   // already 2027-01-01 in UTC
        XCTAssertEqual(EventCalendar.day(lateEvening), "2026-12-31")
        XCTAssertEqual(ProgramCatalog.status(of: lastDay, now: lateEvening), .inProgress(next: "2026-12-31"))
        XCTAssertEqual(ProgramCatalog.cards(from: [lastDay], filter: EventFilter(), custom: [], now: lateEvening).visible.count, 1)

        let justAfter = at("2027-01-01T00:30:00-08:00")
        XCTAssertEqual(ProgramCatalog.status(of: lastDay, now: justAfter), .ended)
        let hidden = ProgramCatalog.cards(from: [lastDay], filter: EventFilter(), custom: [], now: justAfter)
        XCTAssertTrue(hidden.visible.isEmpty)
        XCTAssertEqual(hidden.hiddenEnded, 1)

        // Friday 2027-01-01 at 10 am is still upcoming late on New Year's Eve.
        let newYear = ProgramCatalog.entries(for: [program(id: "ny", title: "First day", end: "2027-01-01T23:59:59-08:00",
                                                           rules: [rule(from: "2027-01-01", through: "2027-01-01", weekdays: [5], minutes: 600)])])[0]
        XCTAssertEqual(ProgramCatalog.status(of: newYear, now: lateEvening), .upcoming(next: "2027-01-01"))

        // Sunday 2026-11-01 (DST ends at 2 am) is the same civil day before and after the clock change.
        let fallBack = ProgramCatalog.entries(for: [program(id: "dst", title: "Fall back", end: "2026-11-01T23:59:59-08:00",
                                                            rules: [rule(from: "2026-11-01", through: "2026-11-01", weekdays: [0], minutes: 840)])])[0]
        XCTAssertEqual(ProgramCatalog.status(of: fallBack, now: at("2026-10-31T23:30:00-07:00")), .upcoming(next: "2026-11-01"))
        XCTAssertEqual(ProgramCatalog.status(of: fallBack, now: at("2026-11-01T01:30:00-08:00")), .inProgress(next: "2026-11-01"))
    }

    func testRecurrenceExclusionsAndExplicitDatesDriveNextDate() {
        // Tuesdays 9 am, Oct 6 – Nov 24 2026, skipping Oct 27; the listing ends when the last session starts to finish.
        let weekly = ProgramCatalog.entries(for: [program(id: "tue", title: "Tuesday walk", end: "2026-11-24T10:00:00-08:00",
                                                          rules: [rule(from: "2026-10-06", through: "2026-11-24", weekdays: [2], excluded: ["2026-10-27"], minutes: 540)])])[0]
        XCTAssertEqual(weekly.sessions.map(\.day), ["2026-10-06", "2026-10-13", "2026-10-20", "2026-11-03", "2026-11-10", "2026-11-17", "2026-11-24"])
        XCTAssertEqual(weekly.lastDay, "2026-11-24")
        XCTAssertEqual(ProgramCatalog.status(of: weekly, now: at("2026-10-26T12:00:00-07:00")), .inProgress(next: "2026-11-03"), "the excluded Tuesday is skipped")
        XCTAssertEqual(ProgramCatalog.status(of: weekly, now: at("2026-11-03T08:00:00-08:00")), .inProgress(next: "2026-11-03"))
        XCTAssertEqual(ProgramCatalog.status(of: weekly, now: at("2026-11-03T10:00:00-08:00")), .inProgress(next: "2026-11-10"), "a session that has started no longer counts as next")
        XCTAssertEqual(ProgramCatalog.status(of: weekly, now: at("2026-11-24T09:30:00-08:00")), .inProgress(next: nil), "final session under way")
        XCTAssertEqual(ProgramCatalog.status(of: weekly, now: at("2026-11-24T10:00:00-08:00")), .ended)
        XCTAssertEqual(ProgramCatalog.status(of: weekly, now: at("2026-10-01T12:00:00-07:00")), .upcoming(next: "2026-10-06"))

        // Explicit dates across two rules sort together; the end day extends lastDay past the final session.
        let explicit = ProgramCatalog.entries(for: [program(id: "x", title: "Two dates", end: "2026-12-11T23:59:59-08:00", rules: [
            rule(from: "2026-12-01", through: "2026-12-31", weekdays: [], dates: ["2026-12-10", "2027-01-05"]),
            rule(from: "2026-11-01", through: "2026-11-30", weekdays: [], dates: ["2026-11-20"]),
        ])])[0]
        XCTAssertEqual(explicit.sessions.map(\.day), ["2026-11-20", "2026-12-10"], "dates outside their rule window are dropped")
        XCTAssertEqual(explicit.lastDay, "2026-12-11")
        XCTAssertEqual(ProgramCatalog.status(of: explicit, now: at("2026-10-26T12:00:00-07:00")), .upcoming(next: "2026-11-20"))
        XCTAssertEqual(ProgramCatalog.status(of: explicit, now: at("2026-11-21T12:00:00-08:00")), .inProgress(next: "2026-12-10"))
    }

    func testTwoSessionsOnOneDayHandOffWithinTheDay() {
        let entry = ProgramCatalog.entries(for: [program(id: "two", title: "Two sessions", end: "2026-11-07T16:00:00-08:00", rules: [
            rule(from: "2026-11-07", through: "2026-11-07", weekdays: [6], minutes: 840),
            rule(from: "2026-11-07", through: "2026-11-07", weekdays: [6], minutes: 540),
        ])])[0]
        XCTAssertEqual(entry.sessions.map(\.startMinutes), [540, 840], "both sessions kept, earliest first")
        XCTAssertEqual(ProgramCatalog.status(of: entry, now: at("2026-11-07T08:00:00-08:00")), .inProgress(next: "2026-11-07"))
        XCTAssertEqual(ProgramCatalog.status(of: entry, now: at("2026-11-07T10:00:00-08:00")), .inProgress(next: "2026-11-07"), "the afternoon session is still ahead")
        XCTAssertEqual(ProgramCatalog.status(of: entry, now: at("2026-11-07T15:00:00-08:00")), .inProgress(next: nil), "final session under way")
        XCTAssertEqual(ProgramCatalog.status(of: entry, now: at("2026-11-07T16:00:00-08:00")), .ended)
    }

    func testCatalogOrderIsDeterministicAndReusesSharedFilters() {
        let events = [
            program(id: "a", title: "Alpha talk", area: "Tuolumne Meadows", end: "2026-11-05T23:59:59-08:00", rules: [rule(from: "2026-11-05", through: "2026-11-05", weekdays: [4], minutes: 1050)]),
            program(id: "b", title: "Beta walk", end: "2026-11-03T23:59:59-08:00", rules: [rule(from: "2026-11-03", through: "2026-11-03", weekdays: [2])]),
            program(id: "c", title: "Gamma", end: "2026-10-25T23:59:59-07:00", rules: [rule(from: "2026-10-25", through: "2026-10-25", weekdays: [0])]),
            program(id: "d", title: "Delta class", end: "2026-10-26T13:00:00-07:00", rules: [rule(from: "2026-10-26", through: "2026-10-26", weekdays: [1], minutes: 540)]),
            program(id: "e", title: "Epsilon", end: "2026-10-26T23:59:59-07:00", rules: [rule(from: "2026-10-26", through: "2026-10-26", weekdays: [1], minutes: 840)]),
        ]
        let entries = ProgramCatalog.entries(for: events)
        let now = at("2026-10-26T15:00:00-07:00")

        let plain = ProgramCatalog.cards(from: entries, filter: EventFilter(), custom: [], now: now)
        XCTAssertEqual(plain.visible.map(\.id), ["e", "b", "a", "d"], "under way today, then by next date, ended-today last; yesterday hidden")
        XCTAssertEqual(plain.hiddenEnded, 1)
        XCTAssertEqual(plain.visible.map(\.id), ProgramCatalog.cards(from: entries.reversed(), filter: EventFilter(), custom: [], now: now).visible.map(\.id), "input order does not matter")

        var showEnded = EventFilter()
        showEnded.showEnded = true
        XCTAssertEqual(ProgramCatalog.cards(from: entries, filter: showEnded, custom: [], now: now).visible.map(\.id), ["e", "b", "a", "d", "c"], "ended programs newest first")

        var exclude = EventFilter()
        exclude.excludeTitles = ["beta"]
        XCTAssertEqual(ProgramCatalog.cards(from: entries, filter: exclude, custom: [], now: now).visible.map(\.id), ["e", "a", "d"])

        var region = EventFilter()
        region.regions = ["Tuolumne Meadows"]
        XCTAssertEqual(ProgramCatalog.cards(from: entries, filter: region, custom: [], now: now).visible.map(\.id), ["a"])

        var custom = EventFilter()
        custom.customCategories = ["mine"]
        let categories = [CustomEventCategory(id: "mine", name: "Mine", keywords: ["delta", "gamma"])]
        let customResult = ProgramCatalog.cards(from: entries, filter: custom, custom: categories, now: now)
        XCTAssertEqual(customResult.visible.map(\.id), ["d"])
        XCTAssertEqual(customResult.hiddenEnded, 1, "hidden count only reflects programs that pass the other filters")
    }

    func testBundledCatalogCoversEveryCuratedProgram() throws {
        let content = try BundleContent.load()
        let entries = ProgramCatalog.entries(for: content.events.events)
        XCTAssertEqual(entries.count, content.events.events.count)
        for e in entries {
            XCTAssertFalse(e.sessions.isEmpty, e.id)
            XCTAssertNotNil(e.endInstant, e.id)
            XCTAssertGreaterThanOrEqual(e.lastDay, e.sessions.last?.day ?? "", e.id)
        }
        let now = at("2026-10-26T12:00:00-07:00")
        let today = EventCalendar.day(now)
        let result = ProgramCatalog.cards(from: entries, filter: EventFilter(), custom: [], now: now)
        XCTAssertEqual(result.visible.count + result.hiddenEnded, entries.count)
        XCTAssertEqual(result.hiddenEnded, entries.filter { $0.lastDay < today }.count)
        XCTAssertTrue(result.visible.allSatisfy { $0.entry.lastDay >= today })
        XCTAssertEqual(result.visible.map(\.id), ProgramCatalog.cards(from: entries, filter: EventFilter(), custom: [], now: now).visible.map(\.id))
        XCTAssertEqual(Set(result.visible.map(\.id)).count, result.visible.count)
    }
}
