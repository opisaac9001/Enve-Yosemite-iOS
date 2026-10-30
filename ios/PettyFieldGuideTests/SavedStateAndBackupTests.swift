import XCTest
@testable import PettyFieldGuide

@MainActor
final class SavedStateAndBackupTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pfg-saved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(_ name: String = "state.json") -> SavedStore { SavedStore(fileURL: directory.appendingPathComponent(name)) }

    func testRapidEditsPersistInOrderAndReloadIntact() async throws {
        let first = store()
        for i in 0..<60 {
            first.toggleSaved("place-\(i)")
            first.setNote("note \(i)", for: "place-\(i)")
            if i % 3 == 0 { first.toggleSaved("place-\(i - (i % 6))") }
        }
        first.setCar(SavedCar(latitude: 37.7, longitude: -119.6, note: "lot B", basis: .manual, updatedAt: .stamp))
        let expected = first.state
        await first.flush()
        XCTAssertNil(first.storageError)

        let reloaded = store()
        XCTAssertEqual(reloaded.state, expected, "the newest state must be what lands on disk, never an earlier write")
        XCTAssertEqual(reloaded.state.car?.note, "lot B")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains(".tmp-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testTimestampsRoundTripExactlyThroughTheRealEncoding() throws {
        let stamp = Date.stamp
        var state = SavedState()
        state.places["p"] = SavedPlace(placeId: "p", savedAt: stamp, note: "n", noteUpdatedAt: stamp)
        let data = try SavedStore.encoder.encode(state)
        XCTAssertEqual(try SavedStore.decoder.decode(SavedState.self, from: data), state)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(DateText.isoString(stamp)), "dates are stored as readable ISO 8601 with milliseconds")
        // Whole-second dates written by earlier builds still read.
        let legacy = Data(#"{"version":1,"places":{"x":{"placeId":"x","savedAt":"2026-01-01T00:00:00Z"}}}"#.utf8)
        XCTAssertEqual(try SavedStore.decoder.decode(SavedState.self, from: legacy).places["x"]?.savedAt, DateText.parse("2026-01-01T00:00:00Z"))
    }

    func testClearedNoteIsNotResurrectedByAnOlderBackup() async {
        let local = store()
        local.setNote("remember the bear box", for: "a")
        var backup = SavedState()
        backup.places["a"] = local.state.places["a"]           // taken while the note still existed
        local.setNote(nil, for: "a")                             // deliberately cleared later
        XCTAssertNil(local.state.places["a"]?.note)
        local.merge(backup)
        XCTAssertNil(local.state.places["a"]?.note, "an older backup must not bring back text the user removed")

        // The reverse: a newer deliberate clear in the backup removes the local text.
        let other = store("other.json")
        other.setNote("stale", for: "b")
        var newerClear = other.state.places["b"]!
        newerClear.note = nil
        newerClear.noteUpdatedAt = Date.stamp.addingTimeInterval(60)
        var clearing = SavedState(); clearing.places["b"] = newerClear
        other.merge(clearing)
        XCTAssertNil(other.state.places["b"]?.note)
        XCTAssertEqual(other.state.places["b"]?.noteUpdatedAt, newerClear.noteUpdatedAt)
        await local.flush(); await other.flush()
    }

    func testMergeUnionsPlacesAndNewerNoteWins() async {
        let local = store()
        local.update { s in
            s.places = [
                "a": SavedPlace(placeId: "a", savedAt: Date(timeIntervalSince1970: 100), note: "mine", noteUpdatedAt: Date(timeIntervalSince1970: 900)),
                "c": SavedPlace(placeId: "c", savedAt: Date(timeIntervalSince1970: 100), note: "old", noteUpdatedAt: Date(timeIntervalSince1970: 200)),
            ]
            s.car = SavedCar(latitude: 1, longitude: 1, note: nil, basis: .manual, updatedAt: Date(timeIntervalSince1970: 500))
            s.trackedTopics = ["fire": TopicPreference(track: true, push: false)]
            s.eventViews = [SavedEventView(id: "v1", name: "Mine", encodedFilter: EventFilter().encoded()!, isDefault: true, savedAt: .stamp)]
        }
        // Fixtures use whole seconds or `.stamp`, the same millisecond precision production writes, so the reload comparison is exact.
        var incoming = SavedState()
        incoming.places = [
            "a": SavedPlace(placeId: "a", savedAt: Date(timeIntervalSince1970: 50), note: "theirs", noteUpdatedAt: Date(timeIntervalSince1970: 300)),
            "b": SavedPlace(placeId: "b", savedAt: .stamp, note: "new"),
            "c": SavedPlace(placeId: "c", savedAt: Date(timeIntervalSince1970: 100), note: "newer", noteUpdatedAt: Date(timeIntervalSince1970: 400)),
        ]
        incoming.car = SavedCar(latitude: 2, longitude: 2, note: nil, basis: .location, updatedAt: Date(timeIntervalSince1970: 100))
        incoming.campsite = SavedCampsite(campgroundId: "cg-upper-pines", siteId: "76", label: "Upper Pines · site 18", placeId: nil, latitude: nil, longitude: nil, updatedAt: .stamp)
        incoming.trackedTopics = ["fire": TopicPreference(track: false, push: false), "weather": TopicPreference(track: true, push: true)]
        incoming.eventViews = [SavedEventView(id: "v2", name: "Theirs", encodedFilter: EventFilter().encoded()!, isDefault: true, savedAt: .stamp)]
        incoming.introGuideSeen = true

        let summary = local.merge(incoming)
        XCTAssertEqual(summary.placesAdded, 1)
        XCTAssertEqual(summary.notesUpdated, 1)
        XCTAssertEqual(summary.campsite, .tookBackup)
        XCTAssertEqual(summary.car, .keptLocal)
        XCTAssertEqual(summary.eventViewsAdded, 1)
        XCTAssertEqual(summary.topicsAdded, 1)
        XCTAssertEqual(local.state.places["a"]?.note, "mine", "the locally newer note stays")
        XCTAssertEqual(local.state.places["c"]?.note, "newer", "the backup's newer note wins")
        XCTAssertEqual(local.state.places["a"]?.savedAt, Date(timeIntervalSince1970: 50), "first save time is kept")
        XCTAssertEqual(local.state.car?.latitude, 1)
        XCTAssertEqual(local.state.campsite?.siteId, "76")
        XCTAssertEqual(local.state.trackedTopics["fire"]?.track, true, "local topic preference is not overwritten")
        XCTAssertEqual(local.state.trackedTopics["weather"]?.push, true)
        XCTAssertEqual(local.state.eventViews.filter(\.isDefault).count, 1, "only one default view survives a merge")
        XCTAssertTrue(local.state.introGuideSeen)
        await local.flush()
        XCTAssertEqual(store().state, local.state)
    }

    func testBackupPackageValidation() throws {
        XCTAssertThrowsError(try BackupPackage.decode(Data("not json".utf8))) { XCTAssertEqual($0 as? BackupPackage.ImportError, .unreadable) }
        XCTAssertThrowsError(try BackupPackage.decode(Data("{\"hello\":1}".utf8))) { XCTAssertEqual($0 as? BackupPackage.ImportError, .wrongFormat) }
        let newer = "{\"format\":\"petty-field-guide-backup\",\"version\":99,\"exportedAt\":\"2026-01-01T00:00:00Z\",\"appVersion\":\"x\",\"state\":{\"version\":1}}"
        XCTAssertThrowsError(try BackupPackage.decode(Data(newer.utf8))) { XCTAssertEqual($0 as? BackupPackage.ImportError, .newerVersion(99)) }

        // Version 1 files (state only, as the first build's exporter wrote them) still import …
        let v1 = """
        {"appVersion":"0.1.0","exportedAt":"2026-10-26T20:11:05Z","format":"petty-field-guide-backup","state":{"campsite":{"campgroundId":"cg-upper-pines","label":"Upper Pines · site 18","siteId":"76","updatedAt":"2026-10-26T19:58:00Z"},"changelogSeenId":"0.1.0","customEventCategories":[],"eventViews":[],"introGuideSeen":true,"places":{"ahwahnee":{"placeId":"ahwahnee","savedAt":"2026-10-26T19:57:12Z","note":"dinner 7pm"}},"seenRevisions":{},"trackedTopics":{"app":{"push":false,"track":true}},"version":1},"version":1}
        """
        let old = try BackupPackage.decode(Data(v1.utf8))
        XCTAssertEqual(old.state.places["ahwahnee"]?.note, "dinner 7pm")
        XCTAssertEqual(old.state.campsite?.siteId, "76")
        XCTAssertTrue(old.state.introGuideSeen)
        XCTAssertNil(old.preferences)
        // … and a hand-trimmed state that omits keys later versions always write takes defaults instead of failing.
        let minimal = "{\"format\":\"petty-field-guide-backup\",\"version\":1,\"exportedAt\":\"2026-01-01T00:00:00Z\",\"appVersion\":\"0.1\",\"state\":{\"version\":1,\"places\":{\"x\":{\"placeId\":\"x\",\"savedAt\":\"2026-01-01T00:00:00Z\"}}}}"
        XCTAssertEqual(try BackupPackage.decode(Data(minimal.utf8)).state.places.count, 1)

        var state = SavedState()
        state.places["p"] = SavedPlace(placeId: "p", savedAt: Date(timeIntervalSince1970: 1), note: "n", noteUpdatedAt: Date(timeIntervalSince1970: 2))
        state.trackedTopics = ["fire": TopicPreference(track: true, push: true)]
        let prefs = BackupPreferences(appearance: "dark", textSize: "larger", boldText: true, mapElementSize: "large", mapLayers: MapLayerToggles(contours: true), mapCategories: ["food"],
                                      conditionsPoints: ["valley", "tuolumne"], serverBaseURL: "http://192.168.1.5:8787", eventFilter: EventFilter(regions: ["Yosemite Valley"]),
                                      customEventCategories: [CustomEventCategory(id: "k", name: "Kids", keywords: ["junior"])], planner: PlannerPreferences(feedId: "valley", from: "shuttle-2", to: "shuttle-7"))
        let package = BackupPackage(exportedAt: Date(timeIntervalSince1970: 10), appVersion: "test", state: state, preferences: prefs,
                                    suggestionDraft: SuggestionDraft(name: "Pat", title: "", text: "draft", includeLayout: false),
                                    suggestionReceipts: [SuggestionRecord(receipt: "r1", name: "Pat", title: "t", text: "x", createdAt: "a", updatedAt: "a", status: "received", reply: nil, closed: false, readAt: "a")])
        let decoded = try BackupPackage.decode(try package.encoded())
        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.preferences, prefs)
        XCTAssertEqual(decoded.state, state)
        XCTAssertEqual(decoded.suggestionDraft?.text, "draft")
        XCTAssertEqual(decoded.suggestionReceipts?.first?.receipt, "r1")
    }

    func testBackupFormatMarkerSurvivedTheRename() throws {
        // Files written under the old app name and files written now share one marker, so either imports on either build.
        XCTAssertEqual(BackupPackage.format, "petty-field-guide-backup")
        let written = try BackupPackage(exportedAt: Date(timeIntervalSince1970: 10), appVersion: "test", state: SavedState()).encoded()
        XCTAssertTrue(String(decoding: written, as: UTF8.self).contains("\"format\":\"petty-field-guide-backup\""))
        let preRename = "{\"format\":\"petty-field-guide-backup\",\"version\":2,\"exportedAt\":\"2026-10-26T20:11:05Z\",\"appVersion\":\"0.1.0\",\"state\":{\"version\":1,\"places\":{\"ahwahnee\":{\"placeId\":\"ahwahnee\",\"savedAt\":\"2026-10-26T19:57:12Z\"}}},\"preferences\":{\"appearance\":\"dark\"}}"
        let imported = try BackupPackage.decode(Data(preRename.utf8))
        XCTAssertEqual(imported.state.places.count, 1)
        XCTAssertEqual(imported.preferences?.appearance, "dark")
        let renamedMarker = "{\"format\":\"enve-yosemite-backup\",\"version\":2,\"exportedAt\":\"2026-10-26T20:11:05Z\",\"appVersion\":\"0.1.0\",\"state\":{\"version\":1}}"
        XCTAssertThrowsError(try BackupPackage.decode(Data(renamedMarker.utf8))) { XCTAssertEqual($0 as? BackupPackage.ImportError, .wrongFormat) }
        XCTAssertEqual(BackupPackage.ImportError.wrongFormat.errorDescription, "That file is not an Enve Yosemite backup.")
    }

    func testDefaultEventViewAppliesAtLaunch() {
        let defaults = UserDefaults(suiteName: "pfg-events-\(UUID().uuidString)")!
        var lastUsed = EventFilter(); lastUsed.costs = ["free"]
        defaults.set(try? JSONEncoder().encode(lastUsed), forKey: EventsState.filterKey)

        var withDefault = EventFilter(); withDefault.regions = ["Yosemite Valley"]; withDefault.showEnded = true
        var saved = SavedState()
        saved.eventViews = [SavedEventView(id: "v", name: "Valley", encodedFilter: withDefault.encoded()!, isDefault: true, savedAt: Date())]
        XCTAssertEqual(EventsState(defaults: defaults, saved: saved).filter, withDefault)

        saved.eventViews[0].isDefault = false
        XCTAssertEqual(EventsState(defaults: defaults, saved: saved).filter, lastUsed, "without a default view the last-used filter returns")
    }
}
