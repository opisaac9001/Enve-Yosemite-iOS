import XCTest
import CoreLocation
@testable import PettyFieldGuide

/// Park-wide hikes: sourced records, honest trace coverage, region crosslinks, filters and search.
final class ParkHikesTests: XCTestCase {
    private static let content = try! BundleContent.load()
    private var content: Content { Self.content }
    private var parkHikes: [Trail] { content.trails.trails.filter { !$0.isValley } }

    func testEveryParkHikeIsSourcedPlacedAndBelongsToARegion() {
        XCTAssertEqual(parkHikes.count, 40)
        XCTAssertEqual(Set(parkHikes.compactMap(\.regionId)), ["glacier-point", "wawona-mariposa-grove", "hetch-hetchy", "crane-flat-big-oak-flat", "tioga-tuolumne"])
        XCTAssertEqual(Set(content.trails.trails.map(\.id)).count, content.trails.trails.count, "park hike ids never collide with Valley hikes")
        for hike in parkHikes {
            XCTAssertNotNil(content.region(hike.regionId ?? ""), hike.id)
            XCTAssertTrue(YosemiteGeo.parkBounds.contains(latitude: hike.latitude, longitude: hike.longitude), hike.id)
            XCTAssertTrue(hike.trailheadSource?.hasPrefix("NPS POI ") == true, "\(hike.id): trailhead coordinate is an NPS GIS point")
            XCTAssertFalse(hike.sources.isEmpty, hike.id)
            XCTAssertTrue(hike.sources.allSatisfy { $0.url?.hasPrefix("https://www.nps.gov/yose/") == true && $0.checked == "2026-10-30" && $0.updated != nil }, hike.id)
            XCTAssertFalse(hike.routes.isEmpty, hike.id)
            XCTAssertTrue(hike.routes.allSatisfy { $0.distanceMi > 0 }, hike.id)
        }
        for region in ["glacier-point", "wawona-mariposa-grove", "hetch-hetchy", "crane-flat-big-oak-flat", "tioga-tuolumne"] {
            XCTAssertNotNil(content.hikeAdvice(forRegion: region), region)
            XCTAssertFalse(content.hikes(inRegion: region).isEmpty, region)
        }
    }

    func testOnlyHikesWithAReviewedCompleteChainAreTraced() throws {
        let traced = Set(parkHikes.filter { !content.hikeRoutes(for: $0.id).isEmpty }.map(\.id))
        XCTAssertEqual(traced.count, 23)
        XCTAssertTrue(traced.isSuperset(of: ["trail-taft-point", "trail-panorama", "trail-pohono", "trail-sentinel-dome", "trail-dewey-point", "trail-glen-aulin"]))
        for id in ["trail-cathedral-lakes", "trail-elizabeth-lake", "trail-soda-springs", "trail-harden-lake", "trail-young-lakes", "trail-wawona-meadow-loop", "trail-big-trees-loop"] {
            XCTAssertNil(content.defaultHikeRoute(for: id), "\(id): no complete reviewed chain, so nothing is drawn")
        }
        for id in traced {
            XCTAssertEqual(content.defaultHikeRoute(for: id)?.trailId, id)
            XCTAssertEqual(content.hikeRoutes(for: id).filter(\.isDefault).count, 1, id)
        }
        // Partly traced hikes keep their untraced published variants listed without a line.
        XCTAssertNotNil(content.hikeRoute("glen-aulin-rt"))
        XCTAssertNil(content.hikeRoute("waterwheel-falls-rt"))
        XCTAssertNil(content.hikeRoute("dog-lake-lembert-loop"))

        let pohono = try XCTUnwrap(content.hikeRoute("pohono-trail"))
        XCTAssertEqual(pohono.kind, .oneWay)
        XCTAssertEqual(pohono.destination.anchor, "pohono-trailhead-tunnel")
        XCTAssertTrue(content.hikeRoute("panorama-trail-mist")!.traceNote.contains("Mist Trail"), "the trace discloses which descent it follows")
        for route in content.hikeRoutes.routes where content.trail(route.trailId)?.isValley == false {
            XCTAssertTrue(route.start.source.hasPrefix("NPS POI") || route.start.isApproximate, "\(route.id): starts at an NPS point or says it does not")
            if route.destination.isApproximate {
                XCTAssertTrue(route.destination.name.contains("approximate") || route.destination.source.hasPrefix("derived"), route.id)
            }
            XCTAssertTrue((0.75...1.35).contains(route.traceToPublishedRatio), route.id)
        }
    }

    func testRegionHikesAndAreaFilter() {
        XCTAssertEqual(content.hikes(inRegion: "wawona-mariposa-grove").count, 8)
        XCTAssertTrue(HikeArea.valley.contains(content.trail("trail-half-dome")!))
        XCTAssertFalse(HikeArea.valley.contains(content.trail("trail-cathedral-lakes")!))
        XCTAssertTrue(HikeArea.region("tioga-tuolumne").contains(content.trail("trail-cathedral-lakes")!))
        XCTAssertEqual(content.areaName(of: content.trail("trail-wapama-falls")!), "Hetch Hetchy")
        XCTAssertEqual(content.areaName(of: content.trail("trail-mirror-lake")!), "Yosemite Valley")
    }

    func testUnratedHikesAreNotFiledAsStrenuous() {
        let strenuous = HikeFilters.apply(parkHikes, query: "", difficulty: .strenuous, distance: .any, savedOnly: false, savedIds: [], sort: .distance) { content.defaultHikeRoute(for: $0.id)?.id }
        XCTAssertEqual(Set(strenuous.map(\.trail.id)), ["trail-guardians-loop", "trail-wawona-point"], "only NPS-rated strenuous grove trails")
        let all = HikeFilters.apply(parkHikes, query: "lake", difficulty: .all, distance: .any, savedOnly: false, savedIds: [], sort: .difficulty) { content.defaultHikeRoute(for: $0.id)?.id }
        XCTAssertTrue(all.contains { $0.trail.id == "trail-cathedral-lakes" })
    }

    func testSearchSendsEveryHikeToTheOneMap() throws {
        let index = SearchIndex(content: content)
        let cathedral = try XCTUnwrap(index.search("cathedral lakes").first { $0.kind == .trail })
        XCTAssertEqual(cathedral.route, .trail("trail-cathedral-lakes"))
        XCTAssertEqual(cathedral.mapFocus, .trail("trail-cathedral-lakes"), "an untraced hike still opens at its trailhead")
        let taft = try XCTUnwrap(index.search("taft point").first { $0.kind == .trail })
        XCTAssertEqual(taft.mapFocus, .trail("trail-taft-point"))
        let dewey = try XCTUnwrap(index.search("dewey point").first { $0.kind == .trail })
        XCTAssertEqual(dewey.mapFocus, .trail("trail-dewey-point"))
        for focus in [cathedral.mapFocus, taft.mapFocus, dewey.mapFocus] { XCTAssertTrue(MapCoverage.canShow(try XCTUnwrap(focus), content: content)) }
        XCTAssertTrue(index.search("hetch hetchy hike").contains { $0.route == .trail("trail-wapama-falls") })
    }

    func testTrailheadPinsGroupHikesSharingOneNPSPoint() {
        let grove = content.trail("trail-grizzly-giant-loop")!
        let ids = ParkMapView.hikes(atMarker: ParkMapView.trailheadMarkerId(grove), content: content).map(\.id)
        XCTAssertEqual(Set(ids), ["trail-big-trees-loop", "trail-grizzly-giant-loop", "trail-guardians-loop", "trail-wawona-point"])
        XCTAssertTrue(ParkMapView.hikes(atMarker: "region-hetch-hetchy", content: content).isEmpty)
    }
}
