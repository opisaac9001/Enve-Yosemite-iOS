import XCTest
@testable import PettyFieldGuide

final class PersistenceAndNoticeTests: XCTestCase {
    func testAtomicWriteCreatesThenReplaces() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pfg-atomic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("state.json")
        try AtomicFile.write(Data("one".utf8), to: target)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "one")
        try AtomicFile.write(Data("two".utf8), to: target)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "two")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".tmp-") }
        XCTAssertTrue(leftovers.isEmpty, "temp files must not be left behind")
    }

    func testNoticePatternsCrosslinkRoadsTrailsAndPlaces() throws {
        let content = try BundleContent.load()
        let item = NoticeItem(id: "test:1", kind: "road", title: "Wawona Road", statusText: "Open", status: "open",
                              text: "Chain controls on Highway 41 near the Wawona Tunnel; Mist Trail work above the footbridge; El Capitan Bridge delays.",
                              area: "Road Status", subjects: ["Wawona Road"], url: nil, sourceDate: "2026-10-23")
        let targets = NoticeMatcher.targets(of: item, content: content)
        XCTAssertTrue((targets.roads ?? []).contains("SR-41"))
        XCTAssertTrue((targets.trails ?? []).contains("trail-vernal-fall"))
        XCTAssertTrue((targets.places ?? []).contains("bridge-el-capitan-bridge"))

        let feed = ConditionsFeed(kind: "conditions", version: 1, fetchedAt: "2026-10-27T03:31:10.418Z",
                                  page: NoticeList(state: "ready", checkedAt: "2026-10-27T03:31:10.418Z", items: [item]),
                                  roadEvents: NoticeList(state: "ready", checkedAt: "2026-10-27T03:31:10.418Z", items: []),
                                  alerts: NoticeList(state: "ready", checkedAt: "2026-10-27T03:31:10.418Z", items: []),
                                  wilderness: NoticeList(state: "ready", checkedAt: "2026-10-27T03:31:10.418Z", items: []),
                                  statuses: [])
        let fresh = Snapshot(payload: feed, acquiredAt: Date(), retrievedAt: Date())
        XCTAssertEqual(NoticeMatcher.notices(forTrail: "trail-vernal-fall", content: content, snapshot: fresh).count, 1)
        XCTAssertEqual(NoticeMatcher.notices(forRoad: "SR-41", content: content, snapshot: fresh).count, 1)
        let expired = Snapshot(payload: feed, acquiredAt: Date().addingTimeInterval(-50 * 3600), retrievedAt: Date())
        XCTAssertTrue(NoticeMatcher.notices(forTrail: "trail-vernal-fall", content: content, snapshot: expired).isEmpty, "expired snapshots must not surface notices as current")
    }

    func testEveryBundledPackDecodesWithItsRealDecoder() throws {
        _ = try BundleContent.load()
        _ = try TerrainGrid.load()
        _ = try CampgroundSceneBuilder.frames()
        _ = try BundleContent.decode(ExplorerCatalog.self, "explorer-catalog.json", subdirectory: "Geo")
        _ = try BundleContent.decode(OfflinePackStatus.Manifest.self, "pack-manifest.json")
        _ = try TerrainGrid.load(file: TerrainGrid.surroundFile)
        for file in ["roads", "trails", "buildings", "parking", "pois", "waterways", "park-roads", "park-pois", "park-buildings", "park-parking", "park-water", "park-names",
                     "park-trails", "park-boundary", "fire-scars", "campground-context", "campsites"] {
            XCTAssertFalse(try GeoJSON.parse(BundleContent.data("\(file).geojson", subdirectory: "Geo")).features.isEmpty, file)
        }
        for doc in try BundleContent.decode([DocumentItem].self, "documents.json") {
            XCTAssertNotNil(BundleContent.resourceURL(doc.bundledFile, subdirectory: "Documents"), doc.bundledFile)
        }
    }

    func testDecodeFailuresNamePackAndCodingPath() {
        struct Probe: Decodable { var menus: Menus; struct Menus: Decodable { var seeAlso: String } }
        let data = Data(#"[{"menus":{"seeAlso":{"label":"x","placeId":"y"}}}]"#.utf8)
        XCTAssertThrowsError(try BundleContent.decode([Probe].self, from: data, pack: "probe.json")) { error in
            guard case BundleContent.LoadError.decoding(let pack, let path, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(pack, "probe.json")
            XCTAssertEqual(path, "$[0].menus.seeAlso")
        }
    }

    func testGeoJSONParsesBundledValleyRoadsWithOneWayDirections() throws {
        let doc = try GeoJSON.parse(BundleContent.data("roads.geojson", subdirectory: "Geo"))
        XCTAssertEqual(doc.features.count, 299)
        let oneWay = doc.features.filter { $0.string("RDONEWAY") != nil }
        XCTAssertEqual(oneWay.count, 84)
        let projection = LocalProjection(origin: YosemiteGeo.valleyCenter)
        let back = projection.unproject(projection.project(YosemiteGeo.valleyCenter))
        XCTAssertEqual(back.latitude, YosemiteGeo.valleyCenter.latitude, accuracy: 1e-9)
        XCTAssertEqual(back.longitude, YosemiteGeo.valleyCenter.longitude, accuracy: 1e-9)
    }

    func testTerrainGridLoadsAndSamples() throws {
        let grid = try TerrainGrid.load()
        XCTAssertEqual(grid.width, 320)
        XCTAssertEqual(grid.height, 152)
        let valleyFloor = try XCTUnwrap(grid.elevation(at: YosemiteGeo.valleyCenter))
        XCTAssertGreaterThan(valleyFloor, 1150)
        XCTAssertLessThan(valleyFloor, 1300)
        XCTAssertNil(grid.elevation(at: .init(latitude: 37.9, longitude: -119.0)))
    }
}
