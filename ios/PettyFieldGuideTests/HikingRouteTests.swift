import XCTest
import CoreLocation
@testable import PettyFieldGuide

/// The bundled hike routes against the real NPS geometry: membership, continuity, endpoints and semantics.
final class HikingRouteTests: XCTestCase {
    private static let projection = LocalProjection(origin: YosemiteGeo.valleyCenter)

    private static let fixture: (content: Content, trails: [LineFeature], traces: [String: MapRouteTrace]) = {
        let content = try! BundleContent.load()
        let doc = try! GeoJSON.parse(BundleContent.data("trails.geojson", subdirectory: "Geo"))
        var trails: [LineFeature] = []
        for (i, f) in doc.features.enumerated() {
            trails += SceneBuilder.lineFeatures(from: f, index: i, projection: projection, name: f.string("TRLNAME"), label: f.string("MAPLABEL"), styleKey: "trail")
        }
        return (content, trails, HikeRouteResolver.traces(for: content.hikeRoutes.routes, trails: trails, projection: projection))
    }()

    private var content: Content { Self.fixture.content }
    private var traces: [String: MapRouteTrace] { Self.fixture.traces }

    private func metres(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private func length(_ points: [CGPoint]) -> Double { Double(GeometryOps.length(points)) }

    func testPackCoversEveryPublishedVariantWithStableIdsAndOneDefaultPerHike() {
        let routes = content.hikeRoutes.routes
        XCTAssertEqual(routes.count, 19)
        XCTAssertEqual(Set(routes.map(\.id)).count, 19, "route ids are unique")
        XCTAssertEqual(Set(routes.map(\.id)), ["bridalveil-viewing-area", "lower-yosemite-fall-loop", "cooks-meadow-loop", "mirror-lake-paved-road", "mirror-lake-loop",
                                               "valley-loop-half", "valley-loop-full", "vernal-footbridge", "vernal-fall-mist", "vernal-fall-clark-point-loop",
                                               "nevada-fall-mist", "nevada-fall-clark-point-loop", "yosemite-falls-columbia-rock", "yosemite-falls-top",
                                               "four-mile-one-way", "four-mile-round-trip", "snow-creek-footbridge", "half-dome-mist", "half-dome-john-muir"])
        for trail in content.trails.trails {
            let own = content.hikeRoutes(for: trail.id)
            XCTAssertEqual(own.count, trail.routes.count, trail.id)
            XCTAssertEqual(own.map(\.label), trail.routes.map(\.label), "\(trail.id): published order and labels")
            XCTAssertEqual(own.filter(\.isDefault).count, 1, trail.id)
            for published in trail.routes { XCTAssertEqual(content.hikeRoute(published.id)?.trailId, trail.id, published.id) }
        }
        XCTAssertEqual(content.defaultHikeRoute(for: "trail-yosemite-falls")?.id, "yosemite-falls-top", "the whole named trail is the default; Columbia Rock stays an explicit option")
        XCTAssertEqual(content.defaultHikeRoute(for: "trail-valley-loop")?.id, "valley-loop-full", "the full loop is the default; the half loop stays an explicit option")
        XCTAssertEqual(content.defaultHikeRoute(for: "trail-vernal-fall")?.id, "vernal-fall-mist")
        XCTAssertEqual(content.hikeRoutes.geometry.featureCount, 612)
        XCTAssertEqual(content.hikeRoutes.geometry.sha256, SHA256Digest.hex(try! BundleContent.data("trails.geojson", subdirectory: "Geo")), "the pack was built against the bundled geometry")
    }

    func testPublishedTimesAndPerVariantDifficultyDecodeWithTheirSources() throws {
        let timed = content.trails.trails.flatMap(\.routes).filter { $0.timeHours != nil }
        XCTAssertGreaterThanOrEqual(timed.count, 15)
        XCTAssertEqual(try XCTUnwrap(content.trail("trail-vernal-footbridge")).routes[0].timeHours, "1–1.5 hours")
        XCTAssertEqual(try XCTUnwrap(content.trail("trail-half-dome")).route("half-dome-mist")?.timeHours, "10–12 hours")
        let loop = try XCTUnwrap(content.trail("trail-valley-loop"))
        XCTAssertEqual(loop.route("valley-loop-half")?.distanceMi, 7.2)
        XCTAssertEqual(loop.route("valley-loop-full")?.distanceMi, 11.5)
        XCTAssertTrue(loop.discrepancies?.contains { $0.contains("6.5") && $0.contains("13") } ?? false, "the overview figures stay as a dated discrepancy")
        XCTAssertEqual(content.trails.trails.filter { $0.guide != nil }.count, 12)

        // Every variant carries the difficulty its NPS page publishes, with a dated source; Yosemite Falls splits it.
        for trail in content.trails.trails {
            for route in trail.routes {
                XCTAssertNotNil(route.difficulty, "\(route.id)")
                XCTAssertNotNil(route.difficultySource?.url, "\(route.id)")
                XCTAssertEqual(route.difficultySource?.checked, "2026-10-27", route.id)
            }
        }
        let falls = try XCTUnwrap(content.trail("trail-yosemite-falls"))
        XCTAssertEqual(falls.route("yosemite-falls-columbia-rock")?.difficulty, "Moderate")
        XCTAssertEqual(falls.route("yosemite-falls-top")?.difficulty, "Strenuous")
        XCTAssertEqual(falls.difficulty(for: falls.route("yosemite-falls-columbia-rock")!), "Moderate")
        XCTAssertEqual(falls.route("yosemite-falls-columbia-rock")?.difficultyRank, 2)
        XCTAssertEqual(try XCTUnwrap(content.trail("trail-vernal-footbridge")).routes[0].difficulty, "Moderate")
        XCTAssertEqual(try XCTUnwrap(content.trail("trail-vernal-fall")).route("vernal-fall-mist")?.difficulty, "Strenuous", "the detail page rates the top of Vernal Fall strenuous even though the hike card says moderate to strenuous")
    }

    func testEveryRouteResolvesContinuouslyOntoTheBundledFeaturesAndMeetsItsAnchors() throws {
        let byId = Dictionary(Self.fixture.trails.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(traces.count, 19, "every bundled route resolves")
        for route in content.hikeRoutes.routes {
            let trace = try XCTUnwrap(traces[route.id], route.id)
            var previousEnd: CGPoint?
            for (i, seg) in route.segments.enumerated() {
                let feature = try XCTUnwrap(byId[String(seg.feature)], "\(route.id) segment \(i) feature \(seg.feature)")
                XCTAssertTrue((0...1).contains(seg.from) && (0...1).contains(seg.to) && seg.from != seg.to, "\(route.id) segment \(i)")
                let piece = HikeRouteResolver.slice(feature.points, from: seg.from, to: seg.to)
                if let previousEnd { XCTAssertLessThan(metres(previousEnd, piece[0]), 2, "\(route.id): segment \(i) must start where segment \(i - 1) ends") }
                previousEnd = piece[piece.count - 1]
            }
            XCTAssertLessThan(metres(trace.points[0], trace.start.point), 50, "\(route.id) starts at its start anchor")
            XCTAssertLessThan(metres(trace.points[trace.points.count - 1], trace.destination.point), 50, "\(route.id) ends at its destination anchor")
            let traced = length(trace.points) / 1609.344
            XCTAssertEqual(traced, route.traceOneWayMiles, accuracy: 0.03, "\(route.id): the pack's one-way length is what the resolver draws")
            switch route.kind {
            case .loop:
                XCTAssertLessThan(metres(trace.points[0], trace.points[trace.points.count - 1]), 2, "\(route.id) closes")
                XCTAssertEqual(route.traceMiles, route.traceOneWayMiles, accuracy: 0.011, route.id)
                XCTAssertEqual(route.start.anchor, route.destination.anchor, route.id)
            case .outAndBack:
                XCTAssertEqual(route.traceMiles, route.traceOneWayMiles * 2, accuracy: 0.011, "\(route.id) is walked twice")
                XCTAssertEqual(trace.travelled.count, trace.points.count * 2 - 1)
                XCTAssertEqual(trace.travelled.last, trace.points.first)
            case .oneWay:
                XCTAssertEqual(route.traceMiles, route.traceOneWayMiles, route.id)
            }
            for m in route.orderedMilestones {
                let p = Self.projection.project(m.coordinate)
                XCTAssertLessThan(GeometryOps.distance(p, toPolyline: trace.travelled), 60, "\(route.id): milestone \(m.anchor) sits on the route")
            }
            let chainages = route.orderedMilestones.map(\.chainageMiles)
            XCTAssertEqual(chainages, chainages.sorted(), "\(route.id): milestones in travel order")
            XCTAssertEqual(Set(route.milestoneRows.map(\.id)).count, route.orderedMilestones.count, "\(route.id): list rows stay distinct even when a loop starts and ends at one anchor")
            XCTAssertTrue((0.75...1.35).contains(route.traceToPublishedRatio), "\(route.id): \(route.traceMiles) mi vs \(route.publishedMiles) published")
            for level in LevelOfDetail.allCases {
                XCTAssertFalse(trace.path(level).isEmpty, "\(route.id): cached path at \(level)")
            }
        }
    }

    func testCorridorRoutesAreDistinctAndStopWhereTheyShould() throws {
        let footbridge = try XCTUnwrap(content.hikeRoute("vernal-footbridge"))
        XCTAssertEqual(footbridge.segments.map(\.feature), [18937, 15622, 16589, 20007, 20091])
        XCTAssertLessThan(footbridge.segments.last!.to, 0.5, "the trace is trimmed at the footbridge, not the end of the JMT feature")
        XCTAssertFalse(footbridge.featureIds.contains(15046), "nothing above the footbridge is highlighted")
        XCTAssertTrue(footbridge.segments.allSatisfy { $0.name == "John Muir Trail" })

        let vernalMist = try XCTUnwrap(content.hikeRoute("vernal-fall-mist"))
        let vernalLoop = try XCTUnwrap(content.hikeRoute("vernal-fall-clark-point-loop"))
        let nevadaMist = try XCTUnwrap(content.hikeRoute("nevada-fall-mist"))
        let nevadaLoop = try XCTUnwrap(content.hikeRoute("nevada-fall-clark-point-loop"))
        XCTAssertTrue(vernalMist.featureIds.contains(19515))
        XCTAssertFalse(vernalMist.featureIds.contains(18748), "the Vernal route stops below the Nevada Fall switchbacks")
        XCTAssertTrue(vernalLoop.featureIds.isSuperset(of: [20407, 16432]), "the Clark Point cut-off and the JMT descent")
        XCTAssertFalse(vernalLoop.featureIds.contains(20133))
        XCTAssertTrue(nevadaMist.featureIds.isSuperset(of: [18748, 17156]))
        XCTAssertTrue(nevadaLoop.featureIds.isSuperset(of: [18748, 20133, 16432]))
        XCTAssertFalse(nevadaLoop.featureIds.contains(20407), "the Nevada loop descends the full JMT, not the cut-off")
        XCTAssertNotEqual(vernalMist.featureIds, nevadaMist.featureIds)
        XCTAssertNotEqual(vernalLoop.featureIds, nevadaLoop.featureIds)
        for route in [vernalMist, vernalLoop, nevadaMist, nevadaLoop] {
            XCTAssertFalse(route.featureIds.contains(18962), "\(route.id) never continues toward Little Yosemite Valley")
        }

        let halfDome = try XCTUnwrap(content.hikeRoute("half-dome-mist"))
        XCTAssertEqual(halfDome.segments.suffix(4).map(\.feature), [18962, 20072, 22688, 19755], "the appended JMT features connect Nevada Fall to the Half Dome Trail")
        let jmt = try XCTUnwrap(content.hikeRoute("half-dome-john-muir"))
        XCTAssertTrue(jmt.featureIds.isSuperset(of: [16432, 20133, 20072, 22688, 19755]))
        XCTAssertFalse(jmt.featureIds.contains(19515), "the JMT variant avoids the Mist Trail stairs")
        XCTAssertGreaterThan(jmt.traceMiles, halfDome.traceMiles)

        let top = try XCTUnwrap(content.hikeRoute("yosemite-falls-top"))
        XCTAssertEqual(top.segments.map(\.feature), [15475, 22204, 19858], "the overlook spur, never the Yosemite Point branch")
        XCTAssertEqual(try XCTUnwrap(content.hikeRoute("yosemite-falls-columbia-rock")).segments.map(\.feature), [15475])
        XCTAssertLessThan(content.hikeRoute("yosemite-falls-columbia-rock")!.segments[0].to, 0.4)

        let mirror = try XCTUnwrap(content.hikeRoute("mirror-lake-loop"))
        let junction = try XCTUnwrap(mirror.segments.first { $0.feature == 17904 })
        XCTAssertLessThan(junction.from, 0.95, "the loop feature is trimmed at the Snow Creek junction vertex instead of a connector")
        XCTAssertEqual(junction.to, 0)

        let valleyFull = try XCTUnwrap(content.hikeRoute("valley-loop-full"))
        XCTAssertEqual(valleyFull.start.anchor, "shuttle-stop-6")
        XCTAssertTrue(valleyFull.featureIds.isSuperset(of: [15200, 14868, 21366, 16717, 20751]), "Pohono Bridge, south side and Sentinel Bridge")
        XCTAssertFalse(valleyFull.featureIds.contains(16540), "no Happy Isles extension")
        XCTAssertFalse(valleyFull.featureIds.contains(15469), "no Mirror Lake extension")
        XCTAssertFalse(valleyFull.featureIds.contains(18922), "no Village stock-trail excursion")
        let valleyHalf = try XCTUnwrap(content.hikeRoute("valley-loop-half"))
        XCTAssertTrue(valleyHalf.featureIds.isSuperset(of: [19413, 16717, 20751]), "El Capitan Bridge and the south side back to Sentinel Bridge")
        XCTAssertFalse(valleyHalf.featureIds.contains(15200))
        XCTAssertFalse(valleyHalf.featureIds.contains(20847), "no Swinging Bridge substitution")

        let cooks = try XCTUnwrap(content.hikeRoute("cooks-meadow-loop"))
        XCTAssertEqual(cooks.segments.filter { $0.feature == 21598 }.count, 2, "the Sentinel Bridge out-and-back is walked twice")
        XCTAssertFalse(cooks.featureIds.contains(18673), "Sentinel Boardwalk south of the Merced is not on the loop")
        XCTAssertLessThan(cooks.traceMiles, 1)
        XCTAssertTrue(cooks.traceNote.contains("stop 6"))
    }

    func testSharedCorridorFeaturesMapBackToEveryHikeThatWalksThem() {
        let onFootbridgeApproach = Set(content.hikeRoutes(usingFeature: 20007).map(\.trailId))
        XCTAssertEqual(onFootbridgeApproach, ["trail-vernal-footbridge", "trail-vernal-fall", "trail-nevada-fall", "trail-half-dome"])
        XCTAssertEqual(Set(content.hikeRoutes(usingFeature: 19755).map(\.trailId)), ["trail-half-dome"])
        XCTAssertTrue(content.hikeRoutes(usingFeature: 99_999).isEmpty)
    }

    func testResolverSlicesByArcLengthInEitherDirection() {
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)]
        XCTAssertEqual(HikeRouteResolver.slice(line, from: 0, to: 1), line)
        XCTAssertEqual(HikeRouteResolver.slice(line, from: 0.25, to: 0.75), [CGPoint(x: 50, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 50)])
        XCTAssertEqual(HikeRouteResolver.slice(line, from: 1, to: 0.5), [CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 0)])
    }

    func testARouteWithAMissingMiddleFeatureIsDroppedRatherThanBridged() throws {
        // Take the Little Yosemite Valley connector away: both Half Dome routes vanish, nothing else changes,
        // and no straight line is drawn between Nevada Fall and the Half Dome Trail.
        let without = Self.fixture.trails.filter { $0.id != "20072" }
        let traces = HikeRouteResolver.traces(for: content.hikeRoutes.routes, trails: without, projection: Self.projection)
        XCTAssertNil(traces["half-dome-mist"])
        XCTAssertNil(traces["half-dome-john-muir"])
        XCTAssertEqual(traces.count, 17)
        for (id, trace) in traces {
            XCTAssertEqual(trace.points.count, Self.fixture.traces[id]!.points.count, id)
        }
        let byId = Dictionary(without.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertNil(HikeRouteResolver.join(content.hikeRoute("half-dome-mist")!.segments, features: byId))
        XCTAssertNotNil(HikeRouteResolver.join(content.hikeRoute("four-mile-one-way")!.segments, features: byId))
    }

    func testTerrainProfilesFollowTravelOrderAndStayOnTheGrid() throws {
        let grid = try TerrainGrid.load(file: TerrainGrid.basemapFile)
        let fourMile = try XCTUnwrap(traces["four-mile-one-way"])
        let up = try XCTUnwrap(HikeRouteResolver.profile(for: fourMile, grid: grid, projection: Self.projection))
        XCTAssertEqual(up.samples.first!.distanceMetres, 0)
        XCTAssertEqual(up.totalMetres, length(fourMile.points), accuracy: 1)
        XCTAssertGreaterThan(up.samples.last!.elevationMetres, up.samples.first!.elevationMetres + 900, "one way ends high at Glacier Point")
        XCTAssertEqual(up.maxMetres, 2186, accuracy: 40, "Glacier Point is about 2,199 m")
        XCTAssertEqual(up.approxGainMetres * 3.28084, 3200, accuracy: 350, "terrain gain is in the published ballpark but is only an approximation")

        let halfDome = try XCTUnwrap(traces["half-dome-mist"])
        let roundTrip = try XCTUnwrap(HikeRouteResolver.profile(for: halfDome, grid: grid, projection: Self.projection))
        XCTAssertEqual(roundTrip.samples.first!.elevationMetres, roundTrip.samples.last!.elevationMetres, accuracy: 1, "an out-and-back returns to its start elevation")
        XCTAssertEqual(roundTrip.totalMetres, 2 * length(halfDome.points), accuracy: 2)
        XCTAssertGreaterThan(roundTrip.maxMetres, 2600)
        XCTAssertEqual(roundTrip.approxGainMetres, roundTrip.approxLossMetres, accuracy: 15)
        for route in content.hikeRoutes.routes {
            XCTAssertNotNil(HikeRouteResolver.profile(for: traces[route.id]!, grid: grid, projection: Self.projection), "\(route.id) lies inside the relief grid")
        }
    }

    func testFiltersMatchDifficultyAndLengthAgainstOneVariantAndOpenThatVariant() {
        let trails = content.trails.trails
        func apply(_ query: String = "", _ difficulty: HikeDifficultyFilter = .all, _ distance: HikeDistanceFilter = .any, saved: Set<String> = [], savedOnly: Bool = false, sort: TrailSort = .difficulty) -> [HikeMatch] {
            HikeFilters.apply(trails, query: query, difficulty: difficulty, distance: distance, savedOnly: savedOnly, savedIds: saved, sort: sort) { content.defaultHikeRoute(for: $0.id)?.id }
        }
        let unfiltered = apply()
        XCTAssertEqual(unfiltered.count, 12)
        XCTAssertTrue(unfiltered.allSatisfy { !$0.filtered })
        XCTAssertEqual(unfiltered.first { $0.trail.id == "trail-yosemite-falls" }?.route.id, "yosemite-falls-top", "no filter means the default variant")
        XCTAssertEqual(unfiltered.first { $0.trail.id == "trail-valley-loop" }?.route.id, "valley-loop-full")

        let strenuous = apply("", .strenuous, .any, sort: .distance)
        XCTAssertEqual(strenuous.map(\.trail.id), ["trail-vernal-fall", "trail-four-mile", "trail-nevada-fall", "trail-yosemite-falls", "trail-snow-creek", "trail-half-dome"], "sorted by the matched variant's distance")
        XCTAssertEqual(strenuous.first { $0.trail.id == "trail-yosemite-falls" }?.route.id, "yosemite-falls-top")

        let moderateShort = apply("", .moderate, .short)
        XCTAssertEqual(Set(moderateShort.map(\.trail.id)), ["trail-vernal-footbridge", "trail-yosemite-falls"])
        let columbia = moderateShort.first { $0.trail.id == "trail-yosemite-falls" }!
        XCTAssertEqual(columbia.route.id, "yosemite-falls-columbia-rock", "the moderate 2-mile variant matched, not the strenuous default")
        XCTAssertTrue(columbia.filtered, "opening the card lands on the matched variant")
        let moderateLong = apply("", .moderate, .long)
        XCTAssertEqual(moderateLong.map(\.route.id), ["valley-loop-full"], "the 11.5-mile full loop is the only moderate variant over 8 miles; the 7.2-mile half loop is not")
        XCTAssertEqual(apply("", .moderate, .medium).first { $0.trail.id == "trail-valley-loop" }?.route.id, "valley-loop-half", "3–8 miles picks the half loop although the full loop is the default")
        XCTAssertEqual(apply("", .strenuous, .short).map(\.route.id), ["vernal-fall-mist"], "difficulty and length are tested on the same variant")
        XCTAssertEqual(Set(apply("", .easy).map(\.trail.id)), ["trail-bridalveil-fall", "trail-lower-yosemite-fall", "trail-cooks-meadow", "trail-mirror-lake"])

        let short = apply("", .all, .short)
        XCTAssertTrue(short.allSatisfy { $0.route.distanceMi < 3 })
        XCTAssertEqual(short.first { $0.trail.id == "trail-mirror-lake" }?.route.id, "mirror-lake-paved-road")
        XCTAssertEqual(apply("", .all, .any, saved: ["trail-half-dome"], savedOnly: true).map(\.trail.id), ["trail-half-dome"])
        XCTAssertEqual(apply("clark point").map(\.trail.id), ["trail-vernal-fall", "trail-nevada-fall"])
        XCTAssertTrue(apply("zzzz").isEmpty)
    }
}
