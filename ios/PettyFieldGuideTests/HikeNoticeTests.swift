import XCTest
@testable import PettyFieldGuide

/// Notices attached to hikes: by curated pattern, by a distinctive name on the route, or by the road the
/// trailhead is on, each in its most specific group; nothing from an expired snapshot.
final class HikeNoticeTests: XCTestCase {
    private static let content = try! BundleContent.load()
    private var content: Content { Self.content }

    private func item(_ id: String, _ title: String, kind: String = "alert", status: String? = nil, text: String) -> NoticeItem {
        NoticeItem(id: id, kind: kind, title: title, statusText: status?.capitalized, status: status, text: text, area: nil, subjects: nil, url: nil, sourceDate: "2026-10-29")
    }

    private func snapshot(_ items: [NoticeItem], age: TimeInterval = 3600) -> Snapshot<ConditionsFeed> {
        let list = { (items: [NoticeItem]) in NoticeList(state: "ready", checkedAt: "2026-10-30T08:00:00Z", items: items) }
        let feed = ConditionsFeed(kind: "conditions", version: 1, fetchedAt: "2026-10-30T08:00:00Z", page: list(items), roadEvents: list([]), alerts: list([]),
                                  wilderness: list([]), statuses: [])
        return Snapshot(payload: feed, acquiredAt: Date().addingTimeInterval(-age), retrievedAt: Date())
    }

    private lazy var items = [
        item("road", "Glacier Point Road", kind: "road", status: "closed", text: "Closed for the season beyond Badger Pass."),
        item("wapama", "Wapama Falls footbridges closed", text: "High water over the bridges below the falls."),
        item("dam", "Tunnel closure", text: "The tunnel at O’Shaughnessy Dam is closed for repairs."),
        item("cooks", "Cook’s Meadow Loop boardwalk work", text: "Expect short delays on the boardwalk."),
    ]

    func testNoticesGroupByHikeRoadAndRegion() throws {
        let snap = snapshot(items)
        let sentinel = try XCTUnwrap(content.trail("trail-sentinel-dome"))
        let s = NoticeMatcher.hikeNotices(sentinel, content: content, snapshot: snap)
        XCTAssertTrue(s.hike.isEmpty)
        XCTAssertEqual(s.roads.map(\.road.name), ["Glacier Point Road"])
        XCTAssertEqual(s.roads.first?.items.map(\.id), ["road"])
        XCTAssertTrue(s.region.isEmpty, "the road notice also names the Glacier Point region but appears only once, under the road")
        XCTAssertEqual(s.specificCount, 1)

        let rancheria = NoticeMatcher.hikeNotices(try XCTUnwrap(content.trail("trail-rancheria-falls")), content: content, snapshot: snap)
        XCTAssertEqual(Set(rancheria.hike.map(\.id)), ["wapama", "dam"], "the route passes Wapama Falls and crosses the dam; curly apostrophes still match")
        let lookout = NoticeMatcher.hikeNotices(try XCTUnwrap(content.trail("trail-lookout-point")), content: content, snapshot: snap)
        XCTAssertTrue(lookout.hike.isEmpty)
        XCTAssertEqual(Set(lookout.region.map(\.id)), ["wapama", "dam"], "elsewhere in Hetch Hetchy these are regional context only")
        XCTAssertEqual(lookout.specificCount, 0, "regional items do not badge the hike in the list")
    }

    func testNamesMatchWholeWordsOnly() throws {
        let wawonaMeadow = NoticeMatcher.hikeNotices(try XCTUnwrap(content.trail("trail-wawona-meadow-loop")), content: content, snapshot: snapshot(items))
        XCTAssertFalse((wawonaMeadow.hike + wawonaMeadow.region).contains { $0.id == "cooks" }, "a Valley meadow loop notice is not about Wawona")
        XCTAssertFalse(NoticeMatcher.mentions(item("x", "Mono Meadows Road", text: ""), term: "Mono Meadow"))
        XCTAssertTrue(NoticeMatcher.mentions(item("x", "mono meadow trail washout", text: ""), term: "Mono Meadow"))
    }

    func testAFeedUpdateThatOnlyChangesSubjectsOrAreaIsRematched() throws {
        var before = item("update", "Seasonal update", kind: "road", text: "Conditions have changed.")
        before.subjects = ["Glacier Point Road"]
        XCTAssertEqual(NoticeMatcher.targets(of: before, content: content).roads, ["Glacier Point Road"])

        var after = before
        after.subjects = ["Tioga Road"]
        XCTAssertEqual(NoticeMatcher.targets(of: after, content: content).roads, ["Tioga"], "same id, title and body; the new subject must be matched, not the cached one")
        let sentinel = try XCTUnwrap(content.trail("trail-sentinel-dome"))
        XCTAssertTrue(NoticeMatcher.hikeNotices(sentinel, content: content, snapshot: snapshot([after])).isEmpty, "the Glacier Point Road association is gone")
        let mayLake = NoticeMatcher.hikeNotices(try XCTUnwrap(content.trail("trail-may-lake")), content: content, snapshot: snapshot([after]))
        XCTAssertEqual(mayLake.roads.map(\.road.name), ["Tioga Road"])

        var areaOnly = before
        areaOnly.subjects = nil
        areaOnly.area = "Hetch Hetchy"
        XCTAssertEqual(NoticeMatcher.targets(of: areaOnly, content: content).regions, ["hetch-hetchy"])
        areaOnly.area = "Tuolumne Meadows"
        XCTAssertEqual(NoticeMatcher.targets(of: areaOnly, content: content).regions, ["tioga-tuolumne"], "area-to-region mapping is re-evaluated too")
    }

    func testExpiredOrMissingConditionsShowNothingAsCurrent() throws {
        let sentinel = try XCTUnwrap(content.trail("trail-sentinel-dome"))
        XCTAssertTrue(NoticeMatcher.hikeNotices(sentinel, content: content, snapshot: snapshot(items, age: 49 * 3600)).isEmpty)
        XCTAssertTrue(NoticeMatcher.hikeNotices(sentinel, content: content, snapshot: nil).isEmpty)
    }

    func testValleyHikesKeepTheirCuratedPatterns() throws {
        let mist = item("mist", "Mist Trail closed above the footbridge", kind: "trail", status: "closed", text: "Ice on the granite steps.")
        let vernal = NoticeMatcher.hikeNotices(try XCTUnwrap(content.trail("trail-vernal-fall")), content: content, snapshot: snapshot([mist]))
        XCTAssertEqual(vernal.hike.map(\.id), ["mist"])
        XCTAssertTrue(vernal.roads.isEmpty)
        let panorama = NoticeMatcher.hikeNotices(try XCTUnwrap(content.trail("trail-panorama")), content: content, snapshot: snapshot([mist]))
        XCTAssertEqual(panorama.hike.map(\.id), ["mist"], "the Panorama Trail descends the Mist Trail")
    }

    func testEveryParkHikeNamesNoticeRoadsThePatternsKnowAndSourcedPetRules() {
        let roadKeys = Set(content.notices.patterns.flatMap { $0.targets.roads ?? [] })
        for hike in content.trails.trails where !hike.isValley {
            let roads = hike.accessRoads ?? []
            XCTAssertFalse(roads.isEmpty, hike.id)
            XCTAssertTrue(roads.allSatisfy { roadKeys.contains($0.key) }, "\(hike.id): \(roads.map(\.key))")
            XCTAssertNotNil(hike.pets, "\(hike.id): no unsourced fallback pet text")
            if hike.pets?.contains("NPS pets page") == true {
                XCTAssertTrue((hike.extraSources ?? []).contains { $0.url == "https://www.nps.gov/yose/planyourvisit/pets.htm" && $0.updated == "2026-06-24" }, hike.id)
            }
            for line in (hike.access ?? []) + [hike.accessibility].compactMap({ $0 }).filter({ $0.contains("Accessibility Guide") }) {
                XCTAssertTrue(line.contains("2026") || line.contains("2022"), "\(hike.id): added statements carry their date")
            }
        }
    }
}
