import XCTest
@testable import PettyFieldGuide

/// The park-wide NPS trail pack on the continuous map: every feature drawn once, every route resolving, park profiles on 3DEP.
final class ParkTrailsTests: XCTestCase {
    private static let content = try! BundleContent.load()
    private var scene: MapScene { SharedScene.map }

    func testEveryNPSFeatureIsOnTheMapAndTheValleyPackIsASubset() throws {
        let doc = try GeoJSON.parse(BundleContent.data("park-trails.geojson", subdirectory: "Geo"))
        XCTAssertEqual(doc.features.count, 1307)
        XCTAssertEqual(doc.metadata["fetchedAt"], .string("2026-10-30T08:46:57Z"))
        let ids = Set(scene.trails.map(\.id))
        XCTAssertTrue(doc.features.allSatisfy { ids.contains($0.id ?? "") || ids.contains("\($0.id ?? "")-0") })
        // The Valley pack is a subset of the same NPS ids, so manifests can cite one numbering.
        let valley = try GeoJSON.parse(BundleContent.data("trails.geojson", subdirectory: "Geo")).features.compactMap(\.id)
        XCTAssertTrue(Set(valley).isSubset(of: Set(doc.features.compactMap(\.id))))
        XCTAssertTrue(scene.sources.contains { $0.contains("park trail features") && $0.contains("2026-10-30") })
    }

    func testLongNamedTrailsAppearFromRegionalZoomAndShortPathsLater() throws {
        let major = try XCTUnwrap(scene.trails.first { $0.styleKey == "trail-major" && $0.name == "John Muir Trail" })
        let unnamed = try XCTUnwrap(scene.trails.first { $0.name == nil && $0.length < 400 })
        XCTAssertFalse(MapRenderer.trailVisible(major, scale: 0.004), "whole-park overview stays readable")
        XCTAssertTrue(MapRenderer.trailVisible(major, scale: 0.012))
        XCTAssertFalse(MapRenderer.trailVisible(unnamed, scale: 0.012))
        XCTAssertTrue(MapRenderer.trailVisible(unnamed, scale: 0.2))
        let minorWords = ["Path", "Footpath", "Boardwalk", "Loop Road", "Access", "Camp 4"]
        let minor = try XCTUnwrap(scene.trails.first { t in t.styleKey == "trail" && t.name.map { n in !minorWords.contains { n.contains($0) } } == true })
        XCTAssertFalse(MapRenderer.trailVisible(minor, scale: 0.012), "a short named path waits for closer zoom wherever it is")
        XCTAssertTrue(MapRenderer.trailVisible(minor, scale: 0.04))
    }

    func testEveryRouteResolvesOnTheOneMapAndJoinsWithoutGaps() throws {
        let routes = Self.content.hikeRoutes.routes
        XCTAssertFalse(routes.filter { $0.pack == .park }.isEmpty)
        for route in routes {
            let trace = try XCTUnwrap(scene.hikeRoutes[route.id], route.id)
            // The builder measured the same chain on the same vertices; a bridged or truncated join would change the length.
            XCTAssertEqual(trace.chainage.totalMetres / 1609.344, route.traceMiles, accuracy: max(0.02, route.traceMiles * 0.01), route.id)
        }
    }

    func testParkRouteProfilesUseThe3DEPParkGrid() throws {
        let grid = try TerrainGrid.load(file: TerrainGrid.parkFile)
        let dewey = try XCTUnwrap(scene.hikeRoutes["dewey-point-rt"])
        let profile = try XCTUnwrap(HikeRouteResolver.profile(for: dewey, grid: grid, projection: scene.projection))
        XCTAssertLessThan(profile.gridMetres, 36)
        XCTAssertEqual(profile.samples.first!.elevationMetres, profile.samples.last!.elevationMetres, accuracy: 1, "an out-and-back returns to its start elevation")
        let monoPass = try XCTUnwrap(scene.hikeRoutes["mono-pass-rt"])
        let mono = try XCTUnwrap(HikeRouteResolver.profile(for: monoPass, grid: grid, projection: scene.projection), "Mono Pass now lies inside the park grid")
        XCTAssertGreaterThan(mono.samples.map(\.elevationMetres).max()!, 3200, "Mono Pass is at about 3,240 m")
    }

    func testAStemWalkedTwiceGivesNoProgressGuess() throws {
        // Tuolumne Grove is drawn as one closed walk: down the old road, round the grove, back up the same road.
        let grove = try XCTUnwrap(scene.hikeRoutes["tuolumne-grove-rt"])
        let onStem = grove.chainage.point(at: 150)
        guard case .ambiguous = RouteProximity.evaluate(fix: onStem, accuracy: 10, stale: false, reducedAccuracy: false, line: grove.points) else {
            return XCTFail("the shared stem must not report a distance along the route")
        }
    }

    func testAParkRouteWithAMissingFeatureIsDroppedNotBridged() throws {
        let route = try XCTUnwrap(Self.content.hikeRoutes.routes.first { $0.pack == .park })
        let missing = try XCTUnwrap(route.segments.first { $0.part == nil }?.feature)
        let trails = scene.trails.filter { $0.id != String(missing) }
        XCTAssertNil(HikeRouteResolver.traces(for: [route], trails: trails, projection: scene.projection)[route.id])
    }
}
