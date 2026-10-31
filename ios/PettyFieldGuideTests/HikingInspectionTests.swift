import XCTest
import CoreGraphics
import CoreLocation
import SwiftUI
import UIKit
@testable import PettyFieldGuide

/// Distance-linked inspection of a route: chainage interpolation, passes, landmarks, grade credibility,
/// the map's focus presentation and cursor, and the hosted chart scrubber.
@MainActor
final class HikingInspectionTests: XCTestCase {
    private static let projection = LocalProjection(origin: YosemiteGeo.valleyCenter)

    private static let fixture: (content: Content, scene: MapScene, grid: TerrainGrid) = {
        let content = try! BundleContent.load()
        let doc = try! GeoJSON.parse(BundleContent.data("trails.geojson", subdirectory: "Geo"))
        var trails: [LineFeature] = []
        for (i, f) in doc.features.enumerated() {
            trails += SceneBuilder.lineFeatures(from: f, index: i, projection: projection, name: f.string("TRLNAME"), label: f.string("MAPLABEL"), styleKey: "trail")
        }
        let traces = HikeRouteResolver.traces(for: content.hikeRoutes.routes.filter { $0.pack == .valley }, trails: trails, projection: projection)
        let scene = MapScene(projection: projection, extent: projection.projectedRect(YosemiteGeo.valleyBounds), roads: [], trails: trails, waterLines: [], waterAreas: [],
                             buildings: [], parking: [], pois: [], boundary: [], fireScars: [], contours: [], sources: [], hikeRoutes: traces)
        return (content, scene, try! TerrainGrid.load(file: TerrainGrid.basemapFile))
    }()

    private var content: Content { Self.fixture.content }
    private var scene: MapScene { Self.fixture.scene }
    private let phone = CGSize(width: 390, height: 844)
    private let phoneInsets = UIEdgeInsets(top: 150, left: 0, bottom: 120, right: 64)

    private func realInspector(_ routeId: String) throws -> HikeInspector {
        let route = try XCTUnwrap(content.hikeRoute(routeId))
        let trace = try XCTUnwrap(scene.hikeRoutes[routeId])
        let profile = try XCTUnwrap(HikeRouteResolver.profile(for: trace, grid: Self.fixture.grid, projection: Self.projection))
        return HikeInspector(route: route, trace: trace, profile: profile)
    }

    /// A straight trail running east with one repeated vertex, published as an out-and-back with a waypoint
    /// halfway, on terrain that rises 10 % to the turnaround and falls 10 % back.
    private func synthetic(length: Double = 1000) throws -> (route: HikeRoute, trace: MapRouteTrace, profile: HikeProfile) {
        let origin = YosemiteGeo.valleyCenter
        func east(_ metres: Double) -> CLLocationCoordinate2D { Self.projection.unproject(CGPoint(x: metres, y: 0)) }
        let feature = try XCTUnwrap(SceneBuilder.lineFeature(id: "1", coords: [0, 0.25, 0.5, 0.5, 0.75, 1].map { east($0 * length) }, projection: Self.projection,
                                                             name: "Test", label: nil, attributes: [:], styleKey: "trail"))
        func milestone(_ anchor: String, _ name: String, _ role: String, _ metres: Double) -> HikeMilestone {
            let c = east(metres)
            return HikeMilestone(anchor: anchor, name: name, role: role, lonlat: [c.longitude, c.latitude], chainageMiles: metres / 1609.344, offsetMetres: 0, source: "test")
        }
        let route = HikeRoute(id: "test-out-and-back", trailId: "trail-test", label: "Test", kind: .outAndBack, isDefault: true, publishedMiles: length / 1609.344 * 2,
                              traceMiles: length / 1609.344 * 2, traceOneWayMiles: length / 1609.344, traceToPublishedRatio: 1,
                              bounds: GeoBounds(west: origin.longitude, south: origin.latitude, east: east(length).longitude, north: origin.latitude),
                              start: milestone("a", "A", "start", 0), destination: milestone("end", "End", "destination", length), milestones: [milestone("mid", "Mid", "waypoint", length / 2)],
                              segments: [HikeSegment(feature: 1, name: "Test", altName: nil, surface: nil, use: nil, from: 0, to: 1, metres: length)],
                              metresByName: ["Test": length], unnamedFeatures: 0, sequence: "Test sequence", traceNote: "")
        let trace = try XCTUnwrap(HikeRouteResolver.traces(for: [route], trails: [feature], projection: Self.projection)[route.id])
        let total = trace.chainage.totalMetres
        var samples: [HikeProfile.Sample] = []
        var d = 0.0
        while true {
            samples.append(HikeProfile.Sample(distanceMetres: d, elevationMetres: 1000 + 0.1 * min(d, total - d)))
            if d >= total { break }
            d = min(d + 40, total)
        }
        let profile = HikeProfile(samples: samples, stepMetres: 40, minMetres: 1000, maxMetres: 1000 + 0.1 * length,
                                  approxGainMetres: 0.1 * length, approxLossMetres: 0.1 * length, source: "test")
        return (route, trace, profile)
    }

    private func assertEqual(_ values: [Double], _ expected: [Double], accuracy: Double = 1e-6, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(values.count, expected.count, message, file: file, line: line)
        for (value, target) in zip(values, expected) { XCTAssertEqual(value, target, accuracy: accuracy, message, file: file, line: line) }
    }

    // MARK: Chainage and profile lookups

    func testChainageInterpolatesEndpointsAndInteriorPointsAndStepsOverRepeatedVertices() {
        let line = HikeChainage(points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)])
        XCTAssertEqual(line.cumulative, [0, 100, 100, 200])
        XCTAssertEqual(line.totalMetres, 200)
        XCTAssertEqual(line.point(at: 0), CGPoint(x: 0, y: 0))
        XCTAssertEqual(line.point(at: 50), CGPoint(x: 50, y: 0))
        XCTAssertEqual(line.point(at: 100), CGPoint(x: 100, y: 0), "the zero-length segment does not divide by zero")
        XCTAssertEqual(line.point(at: 150), CGPoint(x: 100, y: 50))
        XCTAssertEqual(line.point(at: 200), CGPoint(x: 100, y: 100))
        XCTAssertEqual(line.point(at: -5), CGPoint(x: 0, y: 0), "clamped below")
        XCTAssertEqual(line.point(at: 999), CGPoint(x: 100, y: 100), "clamped above")
        XCTAssertEqual(HikeChainage(points: [CGPoint(x: 3, y: 4)]).point(at: 10), CGPoint(x: 3, y: 4))
        XCTAssertEqual(HikeChainage(points: []).totalMetres, 0)

        // Every bundled trace carries its travelled chainage: an out-and-back is twice its one-way length.
        for route in content.hikeRoutes.routes where route.pack == .valley {
            let trace = scene.hikeRoutes[route.id]!
            XCTAssertEqual(trace.chainage.points, trace.travelled, route.id)
            XCTAssertEqual(trace.chainage.totalMetres, Double(GeometryOps.length(trace.travelled)), accuracy: 0.01, route.id)
            XCTAssertEqual(trace.turnaroundMetres, route.kind == .outAndBack ? trace.chainage.totalMetres / 2 : trace.chainage.totalMetres, accuracy: 0.01, route.id)
        }
    }

    func testElevationInterpolatesBetweenSamplesAndGradeIsOnlyReportedOverEnoughLine() throws {
        let (route, trace, profile) = try synthetic()
        let inspector = HikeInspector(route: route, trace: trace, profile: profile)
        XCTAssertEqual(inspector.elevation(at: 20), 1002, accuracy: 1e-6, "halfway between the 0 m and 40 m samples")
        XCTAssertEqual(inspector.elevation(at: 0), 1000, accuracy: 1e-6)
        XCTAssertEqual(inspector.elevation(at: 2000), 1000, accuracy: 1e-6)
        XCTAssertEqual(inspector.elevation(at: -10), 1000, accuracy: 1e-6, "clamped")
        XCTAssertEqual(try XCTUnwrap(inspector.grade(at: 0)), 10, accuracy: 1e-6, "the window at the start reaches forward only")
        XCTAssertEqual(try XCTUnwrap(inspector.grade(at: 500)), 10, accuracy: 1e-6)

        // A pass shorter than the half window has no credible grade: 20 m terrain cannot support one over 60 m.
        let (shortRoute, shortTrace, shortProfile) = try synthetic(length: 60)
        let short = HikeInspector(route: shortRoute, trace: shortTrace, profile: shortProfile)
        XCTAssertEqual(short.totalMetres, 120, accuracy: 1e-6)
        XCTAssertNil(short.grade(at: 30), "60 m of outward line is below the 100 m minimum")
        XCTAssertNil(short.inspection(at: 90).gradePercent, "and so is the return pass")
        XCTAssertEqual(short.inspection(at: 30).elevationMetres, 1003, accuracy: 1e-6, "elevation is still reported")

        let flat = HikeInspection(metres: 0, elevationMetres: 0, gradePercent: 1.5, point: .zero, leg: nil, at: nil, previous: nil, next: nil)
        XCTAssertEqual(flat.gradeText, "about level")
        let unknown = HikeInspection(metres: 0, elevationMetres: 0, gradePercent: nil, point: .zero, leg: nil, at: nil, previous: nil, next: nil)
        XCTAssertNil(unknown.gradeText)
        XCTAssertFalse(unknown.headline.contains("%"), "no grade is shown when none is credible")
    }

    // MARK: Passes, landmarks and texts

    func testOutwardAndReturnPassesShareGroundButNotChainageLegOrGradeSign() throws {
        let (route, trace, profile) = try synthetic()
        let inspector = HikeInspector(route: route, trace: trace, profile: profile)
        XCTAssertEqual(inspector.totalMetres, 2000, accuracy: 1e-6)
        XCTAssertEqual(inspector.landmarks.map(\.id), ["0-a", "1-mid", "2-end", "return-1-mid", "return-0-a"])
        assertEqual(inspector.landmarks.map(\.metres), [0, 500, 1000, 1500, 2000])
        XCTAssertEqual(inspector.landmarks.map(\.leg), [.outward, .outward, .outward, .back, .back])
        XCTAssertEqual(inspector.landmarks.map(\.displayName), ["A", "Mid", "End", "Mid (return)", "A (return)"])

        let out = inspector.inspection(at: 300), back = inspector.inspection(at: 1700)
        XCTAssertEqual(out.point.x, back.point.x, accuracy: 1e-6, "the same ground")
        XCTAssertEqual(out.point.y, back.point.y, accuracy: 1e-6)
        XCTAssertEqual(out.elevationMetres, back.elevationMetres, accuracy: 1e-6)
        XCTAssertEqual(out.leg, .outward)
        XCTAssertEqual(back.leg, .back)
        XCTAssertEqual(try XCTUnwrap(out.gradePercent), 10, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(back.gradePercent), -10, accuracy: 1e-6, "the same slope is a descent on the way back")
        XCTAssertEqual(out.previous?.id, "0-a"); XCTAssertEqual(out.next?.id, "1-mid")
        XCTAssertEqual(back.previous?.id, "return-1-mid"); XCTAssertEqual(back.next?.id, "return-0-a")
        XCTAssertEqual(out.headline, "0.2 mi · ≈3,379 ft · ≈10% climb · outward")
        XCTAssertEqual(back.headline, "1.1 mi · ≈3,379 ft · ≈10% descent · return")
        XCTAssertEqual(out.landmarkText, "0.2 mi past A · 0.1 mi to Mid")
        XCTAssertEqual(back.landmarkText, "0.1 mi past Mid (return) · 0.2 mi to A (return)")
        XCTAssertTrue(back.accessibilitySummary.contains("return pass") && back.accessibilitySummary.contains("about 3,379 feet"), back.accessibilitySummary)

        // The turnaround belongs to the outward pass and its grade is the final climb, not an average with the descent.
        let turn = inspector.inspection(at: 1000)
        XCTAssertEqual(turn.at?.id, "2-end")
        XCTAssertEqual(turn.leg, .outward)
        XCTAssertEqual(try XCTUnwrap(turn.gradePercent), 10, accuracy: 1e-6)
        XCTAssertTrue(turn.headline.hasSuffix("turnaround"), turn.headline)
        XCTAssertEqual(turn.previous?.id, "1-mid"); XCTAssertEqual(turn.next?.id, "return-1-mid")
        XCTAssertEqual(try XCTUnwrap(inspector.inspection(at: 1001).gradePercent), -10, accuracy: 1e-6, "one metre into the return the window stays on the return pass")
        let finish = inspector.inspection(at: 2000)
        XCTAssertEqual(finish.at?.id, "return-0-a")
        XCTAssertNil(finish.next)
        XCTAssertEqual(inspector.inspection(at: 5000).metres, inspector.totalMetres, "clamped to the route's total")
        XCTAssertEqual(inspector.inspection(at: 10).landmarkText, "At A", "within 20 m counts as being at the landmark")

        // Stepping and landmark navigation are the accessible equivalents of dragging.
        XCTAssertEqual(inspector.stepMetres, 50, accuracy: 1e-6)
        XCTAssertEqual(inspector.step(from: nil, forward: true), 50, accuracy: 1e-6)
        XCTAssertEqual(inspector.step(from: 1990, forward: true), 2000, accuracy: 1e-6)
        XCTAssertEqual(inspector.step(from: 30, forward: false), 0)
        XCTAssertEqual(inspector.nextLandmark(after: nil)?.id, "0-a")
        XCTAssertEqual(inspector.nextLandmark(after: 500)?.id, "2-end", "a landmark within the snap distance is the current one, not the next")
        XCTAssertEqual(inspector.previousLandmark(before: 500)?.id, "0-a")
        XCTAssertNil(inspector.previousLandmark(before: 0))
        XCTAssertNil(inspector.nextLandmark(after: 2000))
    }

    func testLoopsKeepDistinctStartAndEndRowsAndOneWayRoutesHaveNoPasses() throws {
        let loop = try realInspector("cooks-meadow-loop")
        XCTAssertEqual(loop.landmarks.count, 6, "no mirrored return entries on a loop")
        XCTAssertEqual(loop.landmarks.first?.id, "0-shuttle-stop-6")
        XCTAssertEqual(loop.landmarks.last?.id, "5-shuttle-stop-6", "the shared anchor keeps separate start and end identities")
        XCTAssertEqual(loop.landmarks.first?.metres, 0)
        XCTAssertEqual(try XCTUnwrap(loop.landmarks.last).metres, loop.totalMetres)
        XCTAssertEqual(loop.inspection(at: 0).at?.id, "0-shuttle-stop-6")
        XCTAssertEqual(loop.inspection(at: loop.totalMetres).at?.id, "5-shuttle-stop-6")
        XCTAssertNil(loop.inspection(at: 300).leg)
        XCTAssertTrue(loop.landmarks.allSatisfy { $0.leg == nil })
        let chainages = loop.landmarks.map(\.metres)
        XCTAssertEqual(chainages, chainages.sorted())
        let bridge = try XCTUnwrap(loop.landmark("2-sentinel-bridge"))
        XCTAssertLessThan(GeometryOps.distance(bridge.point, toPolyline: loop.chainage.points), 0.01, "landmarks sit on the travelled line even when the anchor is offset")
        XCTAssertGreaterThan(hypot(bridge.point.x - Self.projection.project(content.hikeRoute("cooks-meadow-loop")!.milestones[1].coordinate).x,
                                   bridge.point.y - Self.projection.project(content.hikeRoute("cooks-meadow-loop")!.milestones[1].coordinate).y), 20,
                             "Sentinel Bridge's own point is about 31 m off the line")

        let oneWay = try realInspector("four-mile-one-way")
        XCTAssertEqual(oneWay.landmarks.map(\.id), ["0-four-mile-trailhead", "1-glacier-point-trailhead"])
        XCTAssertNil(oneWay.inspection(at: 1000).leg)
        XCTAssertEqual(oneWay.inspection(at: oneWay.totalMetres).at?.role, "destination")
        XCTAssertFalse(oneWay.inspection(at: oneWay.totalMetres).headline.contains("turnaround"))
        XCTAssertGreaterThan(try XCTUnwrap(oneWay.inspection(at: oneWay.totalMetres / 2).gradePercent), 0, "Four Mile climbs toward Glacier Point")

        let nevada = try realInspector("nevada-fall-mist")
        XCTAssertEqual(nevada.landmarks.count, 11, "start, four waypoints, turnaround, the four waypoints again and the finish")
        let footbridge = try XCTUnwrap(nevada.landmark("1-vernal-fall-footbridge"))
        let footbridgeBack = try XCTUnwrap(nevada.landmark("return-1-vernal-fall-footbridge"))
        XCTAssertEqual(footbridge.metres, 0.87 * 1609.344, accuracy: 1e-6, "pack chainage is used as published")
        XCTAssertEqual(footbridgeBack.metres, nevada.totalMetres - footbridge.metres, accuracy: 1e-6)
        XCTAssertLessThan(hypot(footbridge.point.x - footbridgeBack.point.x, footbridge.point.y - footbridgeBack.point.y), 0.01, "the mirrored entry is the same ground")
        XCTAssertEqual(nevada.landmarks.map(\.metres), nevada.landmarks.map(\.metres).sorted())
    }

    // MARK: Map focus and cursor

    private func valleyModel(defaults: UserDefaults) -> MapViewModel {
        let model = MapViewModel(restoresPreferences: true, defaults: defaults)
        model.obscuredInsets = phoneInsets
        var camera = model.camera
        camera.viewSize = phone
        model.setScene(scene)
        model.cameraDidChange(camera)
        return model
    }

    func testFocusQuietsUnrelatedPlacesKeepsPersonalPinsAndNeverTouchesPreferences() throws {
        let defaults = UserDefaults(suiteName: "pfg-inspect-\(UUID().uuidString)")!
        let model = valleyModel(defaults: defaults)
        var saved = SavedState()
        saved.places["ahwahnee-hotel"] = SavedPlace(placeId: "ahwahnee-hotel", savedAt: .stamp, note: nil, noteUpdatedAt: nil)
        saved.car = SavedCar(latitude: 37.7449, longitude: -119.5934, note: nil, basis: .manual, updatedAt: .stamp)
        saved.campsite = SavedCampsite(campgroundId: "upper-pines", siteId: "76", label: "Upper Pines · site 18", placeId: nil, latitude: 37.7358, longitude: -119.5635, updatedAt: .stamp)
        model.configure(content: content, saved: saved, elementScale: 1, dark: false)
        model.userFix = MapUserFix(fix: LiveFix(latitude: 37.74, longitude: -119.58, horizontalAccuracy: 10, timestamp: .now), stale: false)
        model.layers.contours = true
        let storedLayers = defaults.data(forKey: MapViewModel.layersKey)
        let storedCategories = defaults.array(forKey: MapViewModel.categoriesKey) as? [String]
        let categories = model.activeCategories
        let before = Set(model.frameContent.markers.map(\.id))
        XCTAssertTrue(before.isSuperset(of: ["shuttle-10", "ahwahnee-hotel", "car", "campsite", "user", "trail-nevada-fall"]))
        XCTAssertFalse(model.frameContent.overlayLines.isEmpty, "shuttle shapes are drawn by default")

        model.focus(on: .hikeRoute("nevada-fall-mist"), animated: false)
        XCTAssertTrue(model.focusesHike, "a fresh selection starts focused")
        let focused = Set(model.frameContent.markers.map(\.id))
        XCTAssertTrue(focused.isSuperset(of: ["car", "campsite", "user", "ahwahnee-hotel", "shuttle-16", MapMarker.routeStartId, MapMarker.routeDestinationId]),
                      "personal pins, saved places and the hike's own shuttle stop stay")
        XCTAssertFalse(focused.contains("shuttle-10"), "an unrelated stop is quieted")
        let start = try XCTUnwrap(model.frameContent.markers.first { $0.id == MapMarker.routeStartId })
        XCTAssertEqual(start.title, "Start")
        XCTAssertEqual(start.accessibleName, "Start · Happy Isles trailhead", "focused endpoint badges show compact labels but keep the full name for VoiceOver")
        XCTAssertEqual(model.frameContent.markers.first { $0.id == MapMarker.routeDestinationId }?.accessibleName, "Destination · Nevada Fall Footbridge")
        XCTAssertFalse(focused.contains("trail-nevada-fall"))
        XCTAssertEqual(focused.filter { $0.hasPrefix(MapMarker.routeMilestonePrefix) }.count, 4, "the four outward waypoints are dotted")
        XCTAssertTrue(model.frameContent.overlayLines.isEmpty, "shuttle shapes are quieted while focused")
        XCTAssertEqual(model.layers.shuttleRoutes, true, "the layer toggle itself is untouched")
        XCTAssertEqual(model.activeCategories, categories)
        XCTAssertEqual(defaults.data(forKey: MapViewModel.layersKey), storedLayers, "focus is never persisted")
        XCTAssertEqual(defaults.array(forKey: MapViewModel.categoriesKey) as? [String], storedCategories)

        // Hidden markers are not drawn, so they cannot be hit; the waypoint dots can, and they inspect their point.
        let stop = try XCTUnwrap(content.place("shuttle-10"))
        let camera = MapCamera(center: Self.projection.project(stop.coordinate), scale: 1, viewSize: phone)
        let screen = camera.screenPoint(for: Self.projection.project(stop.coordinate))
        let hidden = MapHitTester.hit(at: screen, scene: scene, camera: camera, content: model.frameContent, options: model.frameOptions)
        if case .marker(let id) = hidden { XCTAssertNotEqual(id, "shuttle-10") }
        if case .cluster(let ids, _) = hidden { XCTAssertFalse(ids.contains("shuttle-10")) }
        let waypoint = try XCTUnwrap(model.frameContent.markers.first { $0.id == MapMarker.routeMilestonePrefix + "1-vernal-fall-footbridge" })
        XCTAssertEqual(waypoint.title, "Vernal Fall Footbridge")
        XCTAssertEqual(waypoint.accessibleName, "Waypoint · Vernal Fall Footbridge · 0.9 mi along the route")
        let close = MapCamera(center: waypoint.point, scale: 1, viewSize: phone)
        XCTAssertEqual(MapHitTester.hit(at: close.screenPoint(for: waypoint.point), scene: scene, camera: close, content: model.frameContent, options: model.frameOptions), .marker(id: waypoint.id))
        model.handleTap(.marker(id: waypoint.id), at: .zero)
        XCTAssertEqual(model.selection, .hike(routeId: "nevada-fall-mist"))
        XCTAssertEqual(try XCTUnwrap(model.inspectedMetres), 0.87 * 1609.344, accuracy: 1e-6)

        model.focusesHike = false
        let all = Set(model.frameContent.markers.map(\.id))
        XCTAssertTrue(all.contains("shuttle-10"), "all places return while the hike stays selected")
        XCTAssertEqual(model.frameContent.markers.first { $0.id == MapMarker.routeStartId }?.title, "Start · Happy Isles trailhead", "ordinary presentation keeps the full labels")
        XCTAssertNil(model.frameContent.markers.first { $0.id == MapMarker.routeStartId }?.accessibilityTitle)
        XCTAssertEqual(all.filter { $0.hasPrefix(MapMarker.routeMilestonePrefix) }.count, 4)
        XCTAssertFalse(model.frameContent.overlayLines.isEmpty)
        XCTAssertEqual(model.selection, .hike(routeId: "nevada-fall-mist"))
        let shown = MapHitTester.hit(at: screen, scene: scene, camera: camera, content: model.frameContent, options: model.frameOptions)
        switch shown {
        case .marker(let id): XCTAssertEqual(id, "shuttle-10")
        case .cluster(let ids, _): XCTAssertTrue(ids.contains("shuttle-10"))
        default: XCTFail("the stop is tappable again: \(shown)")
        }

        model.clearHike()
        XCTAssertTrue(model.focusesHike, "clearing restores the default for the next hike")
        XCTAssertEqual(Set(model.frameContent.markers.map(\.id)), before, "ordinary content is restored exactly")
        XCTAssertFalse(model.frameContent.overlayLines.isEmpty)
        XCTAssertEqual(defaults.data(forKey: MapViewModel.layersKey), storedLayers)
    }

    func testInspectionMovesOnlyTheCursorAndResetsWithTheRoute() throws {
        let model = valleyModel(defaults: UserDefaults(suiteName: "pfg-inspect-\(UUID().uuidString)")!)
        model.configure(content: content, saved: SavedState(), elementScale: 1, dark: false)
        model.focus(on: .hikeRoute("nevada-fall-mist"), animated: false)
        let trace = try XCTUnwrap(scene.hikeRoutes["nevada-fall-mist"])
        let fitted = model.camera
        let markers = model.frameContent.markers.map(\.id)
        XCTAssertNil(model.inspectedMetres)
        XCTAssertNil(model.frameContent.routeCursor)
        XCTAssertEqual(model.activeLandmarks.count, 11)

        model.inspect(metres: 800)
        XCTAssertEqual(model.inspectedMetres, 800)
        XCTAssertEqual(model.frameContent.routeCursor, trace.chainage.point(at: 800))
        XCTAssertEqual(model.camera, fitted, "scrubbing never moves the camera")
        XCTAssertEqual(model.frameContent.markers.map(\.id), markers, "scrubbing never rebuilds the marker set")
        model.inspect(metres: 1e9)
        XCTAssertEqual(try XCTUnwrap(model.inspectedMetres), trace.chainage.totalMetres, accuracy: 1e-9, "clamped to the travelled line")

        // The fit still follows a card-height change: inspection did not count as a user pan.
        let taller = UIEdgeInsets(top: 150, left: 0, bottom: 320, right: 64)
        model.obscuredInsets = taller
        XCTAssertNotEqual(model.camera, fitted)
        XCTAssertEqual(model.frameContent.routeCursor, trace.chainage.point(at: trace.chainage.totalMetres), "the cursor survives the content rebuild")
        XCTAssertEqual(model.camera.viewSize, phone)

        // Re-tapping the drawn route rebuilds the content with the same cursor; switching variant or clearing resets it.
        model.handleTap(.route(id: "nevada-fall-mist"), at: .zero)
        XCTAssertEqual(model.frameContent.routeCursor, trace.chainage.point(at: trace.chainage.totalMetres))
        model.selectHike("nevada-fall-clark-point-loop", animated: false)
        XCTAssertNil(model.inspectedMetres)
        XCTAssertNil(model.frameContent.routeCursor)
        XCTAssertEqual(model.activeLandmarks.count, 7)
        XCTAssertEqual(model.activeLandmarks.first?.id, "0-happy-isles-trailhead")
        XCTAssertEqual(model.activeLandmarks.last?.id, "6-happy-isles-trailhead")
        model.inspect(landmarkId: "5-clark-point")
        XCTAssertEqual(try XCTUnwrap(model.inspectedMetres), 4.05 * 1609.344, accuracy: 1e-6)
        model.inspect(landmarkId: "no-such-landmark")
        XCTAssertEqual(try XCTUnwrap(model.inspectedMetres), 4.05 * 1609.344, accuracy: 1e-6, "an unknown landmark changes nothing")
        model.centerOnInspection()
        XCTAssertNotNil(model.inspectedMetres, "without a canvas there is nothing to centre, and nothing breaks")
        model.clearHike()
        XCTAssertNil(model.inspectedMetres)
        XCTAssertNil(model.frameContent.routeCursor)
        XCTAssertTrue(model.activeLandmarks.isEmpty)
        model.inspect(metres: 100)
        XCTAssertNil(model.inspectedMetres, "no route, no cursor")

        // Explicit centring is the one camera move inspection offers; it animates on the attached canvas.
        let canvas = MapCanvas(camera: model.camera, options: model.frameOptions)
        canvas.frame = CGRect(origin: .zero, size: phone)
        canvas.onCameraChange = { [weak model] camera in model?.cameraDidChange(camera) }
        model.attach(canvas)
        canvas.layoutSubviews()
        model.focus(on: .hikeRoute("half-dome-mist"), animated: false)
        XCTAssertFalse(canvas.isAnimating)
        model.inspect(metres: 3000)
        XCTAssertFalse(canvas.isAnimating, "a cursor change starts no animation")
        model.centerOnInspection()
        XCTAssertTrue(canvas.isAnimating)
        canvas.stopAnimation()
    }

    // MARK: Hosted chart

    private final class Cursor: ObservableObject {
        @Published var metres: Double?
    }

    private struct Host: View {
        let inspector: HikeInspector
        @ObservedObject var cursor: Cursor
        var body: some View { HikeTerrainInspector(inspector: inspector, metres: $cursor.metres) }
    }

    func testHostedChartScrubsByHorizontalPositionRefusesVerticalDragsAndKeepsTheSelectionAcrossRelayout() throws {
        XCTAssertTrue(HikeProfileScrubber.ScrubView.beginsPan(velocity: CGPoint(x: 120, y: 30)))
        XCTAssertFalse(HikeProfileScrubber.ScrubView.beginsPan(velocity: CGPoint(x: 30, y: -120)), "a mostly vertical drag is left to the page scroll")
        XCTAssertFalse(HikeProfileScrubber.ScrubView.beginsPan(velocity: .zero))

        let inspector = try realInspector("vernal-fall-mist")
        let cursor = Cursor()
        let host = UIHostingController(rootView: Host(inspector: inspector, cursor: cursor))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        window.rootViewController = host
        window.isHidden = false
        func settle() {
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        func scrubber(in view: UIView) -> HikeProfileScrubber.ScrubView? {
            if let s = view as? HikeProfileScrubber.ScrubView { return s }
            for sub in view.subviews { if let s = scrubber(in: sub) { return s } }
            return nil
        }
        settle()
        let scrub = try XCTUnwrap(scrubber(in: host.view), "the chart hosts the scrubber")
        XCTAssertEqual(scrub.bounds.width, 390, accuracy: 1)
        XCTAssertFalse(scrub.isAccessibilityElement, "the chart itself is the adjustable element")
        let plot = HikeProfileChart.plotRect(in: scrub.bounds.size)
        scrub.scrub(x: plot.minX)
        XCTAssertEqual(cursor.metres, 0)
        scrub.scrub(x: plot.midX)
        XCTAssertEqual(try XCTUnwrap(cursor.metres), inspector.totalMetres / 2, accuracy: 0.5)
        scrub.scrub(x: 5)
        XCTAssertEqual(cursor.metres, 0, "left of the plot clamps to the start")
        scrub.scrub(x: 9999)
        XCTAssertEqual(try XCTUnwrap(cursor.metres), inspector.totalMetres, accuracy: 1e-9, "right of the plot clamps to the end")
        scrub.scrub(x: plot.midX)
        let mid = try XCTUnwrap(cursor.metres)

        window.frame = CGRect(x: 0, y: 0, width: 844, height: 400)
        settle()
        XCTAssertEqual(cursor.metres, mid, "a relayout keeps the inspected distance")
        let wide = try XCTUnwrap(scrubber(in: host.view))
        XCTAssertEqual(wide.bounds.width, 844, accuracy: 1)
        wide.scrub(x: HikeProfileChart.plotRect(in: wide.bounds.size).midX)
        XCTAssertEqual(try XCTUnwrap(cursor.metres), inspector.totalMetres / 2, accuracy: 0.5, "the wider plot maps the same distance to its new midpoint")
        window.isHidden = true
    }

    // MARK: Hosted map card ceiling

    private final class Measured: ObservableObject {
        @Published var height: CGFloat = 0
    }

    private struct CardHost: View {
        let trail: Trail
        let route: HikeRoute
        let content: Content
        @ObservedObject var model: MapViewModel
        let maxHeight: CGFloat
        let typeSize: DynamicTypeSize
        @ObservedObject var measured: Measured
        let router = AppRouter()

        var body: some View {
            VStack {
                Spacer()
                HikeMapCard(trail: trail, route: route, content: content, model: model, maxHeight: maxHeight)
                    .background(GeometryReader { p in
                        Color.clear
                            .onAppear { measured.height = p.size.height }
                            .onChange(of: p.size.height) { _, new in measured.height = new }
                    })
            }
            .dynamicTypeSize(typeSize)
            .environmentObject(router)
        }
    }

    func testHostedMapCardStaysUnderASmallCeilingAtNormalAndAccessibilitySizesAndScrollsTheRest() throws {
        let model = valleyModel(defaults: UserDefaults(suiteName: "pfg-inspect-\(UUID().uuidString)")!)
        model.configure(content: content, saved: SavedState(), elementScale: 1, dark: false)
        model.focus(on: .hikeRoute("vernal-fall-mist"), animated: false)
        let route = try XCTUnwrap(content.hikeRoute("vernal-fall-mist"))
        let trail = try XCTUnwrap(content.trail(route.trailId))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        func scrollView(in view: UIView) -> UIScrollView? {
            if let s = view as? UIScrollView { return s }
            for sub in view.subviews { if let s = scrollView(in: sub) { return s } }
            return nil
        }
        let ceiling: CGFloat = 130
        XCTAssertLessThan(ceiling, HikeMapCard.inlineTerrainViewport, "a ceiling this small sends terrain to the dedicated sheet")

        for typeSize in [DynamicTypeSize.large, .accessibility5] {
            let measured = Measured()
            let host = UIHostingController(rootView: CardHost(trail: trail, route: route, content: content, model: model, maxHeight: ceiling, typeSize: typeSize, measured: measured))
            window.rootViewController = host
            // The body is measured by a preference, so the viewport settles on the second layout pass.
            for _ in 0..<3 {
                host.view.frame = window.bounds
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            XCTAssertGreaterThan(measured.height, 0, "\(typeSize)")
            XCTAssertLessThanOrEqual(measured.height, ceiling + 0.5, "\(typeSize): the rendered card respects its ceiling")
            let scroll = try XCTUnwrap(scrollView(in: host.view), "\(typeSize): the card body is a scroll view")
            XCTAssertLessThanOrEqual(scroll.bounds.height, ceiling - 28 + 0.5, "\(typeSize)")
            XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height, "\(typeSize): the name, figures and actions are reachable by scrolling, not clipped")
        }
        window.isHidden = true
    }
}
