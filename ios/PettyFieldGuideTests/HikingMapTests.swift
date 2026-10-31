import XCTest
import CoreGraphics
import SwiftUI
import UIKit
@testable import PettyFieldGuide

/// Selecting a hike on the Valley map: readiness, framing, clamp, overlay visibility and links.
@MainActor
final class HikingMapTests: XCTestCase {
    private static let fixture: (content: Content, scene: MapScene) = {
        let content = try! BundleContent.load()
        let projection = LocalProjection(origin: YosemiteGeo.valleyCenter)
        let doc = try! GeoJSON.parse(BundleContent.data("trails.geojson", subdirectory: "Geo"))
        var trails: [LineFeature] = []
        for (i, f) in doc.features.enumerated() {
            trails += SceneBuilder.lineFeatures(from: f, index: i, projection: projection, name: f.string("TRLNAME"), label: f.string("MAPLABEL"), styleKey: "trail")
        }
        let traces = HikeRouteResolver.traces(for: content.hikeRoutes.routes.filter { $0.pack == .valley }, trails: trails, projection: projection)
        let scene = MapScene(projection: projection, extent: projection.projectedRect(YosemiteGeo.valleyBounds), roads: [], trails: trails, waterLines: [], waterAreas: [],
                             buildings: [], parking: [], pois: [], boundary: [], fireScars: [], contours: [], sources: [], hikeRoutes: traces)
        return (content, scene)
    }()

    private var content: Content { Self.fixture.content }
    private var scene: MapScene { Self.fixture.scene }
    private let phone = CGSize(width: 390, height: 844)
    private let phoneInsets = UIEdgeInsets(top: 150, left: 0, bottom: 120, right: 64)

    private func valleyModel(insets: UIEdgeInsets? = nil) -> MapViewModel {
        let model = MapViewModel(restoresPreferences: true, defaults: UserDefaults(suiteName: "pfg-hiking-\(UUID().uuidString)")!)
        model.obscuredInsets = insets ?? phoneInsets
        return model
    }

    private func layOut(_ model: MapViewModel, _ size: CGSize) {
        var camera = model.camera
        camera.viewSize = size
        model.cameraDidChange(camera)
    }

    private func readyModel(route: String? = nil) -> MapViewModel {
        let model = valleyModel()
        model.setScene(scene)
        layOut(model, phone)
        model.configure(content: content, saved: SavedState(), elementScale: 1, dark: false)
        if let route { model.focus(on: .hikeRoute(route), animated: false) }
        return model
    }

    private func assertFits(_ camera: MapCamera, routeId: String, size: CGSize, insets: UIEdgeInsets, floor: CGFloat, _ message: String) {
        let route = scene.hikeRoutes[routeId]!
        XCTAssertEqual(camera.viewSize, size, message)
        let topLeft = camera.screenPoint(for: CGPoint(x: route.bounds.minX, y: route.bounds.maxY))
        let bottomRight = camera.screenPoint(for: CGPoint(x: route.bounds.maxX, y: route.bounds.minY))
        XCTAssertGreaterThanOrEqual(topLeft.x, insets.left, "\(message): west edge clear of the chrome")
        XCTAssertGreaterThanOrEqual(topLeft.y, insets.top, "\(message): north edge clear of the top chrome")
        XCTAssertLessThanOrEqual(bottomRight.x, size.width - insets.right, "\(message): east edge clear of the controls")
        XCTAssertLessThanOrEqual(bottomRight.y, size.height - insets.bottom, "\(message): south edge clear of the card and bar")
        XCTAssertGreaterThanOrEqual(camera.scale, floor - 1e-9, message)
    }

    private func assertFits(_ model: MapViewModel, routeId: String, size: CGSize, insets: UIEdgeInsets, _ message: String) {
        assertFits(model.camera, routeId: routeId, size: size, insets: insets, floor: model.scaleLimits.lowerBound, message)
    }

    func testEveryArrivalOrderOfSceneLayoutContentAndHikeLinkFramesTheWholeRoute() {
        enum Event: CaseIterable { case scene, layout, content, link }
        func permutations(_ items: [Event]) -> [[Event]] {
            guard items.count > 1 else { return [items] }
            return items.flatMap { item in permutations(items.filter { $0 != item }).map { [item] + $0 } }
        }
        for order in permutations(Event.allCases) {
            let model = valleyModel()
            for event in order {
                switch event {
                case .scene: model.setScene(scene)
                case .layout: layOut(model, phone)
                case .content: model.configure(content: content, saved: SavedState(), elementScale: 1, dark: false)
                case .link: model.focus(on: .trail("trail-nevada-fall"))
                }
            }
            XCTAssertEqual(model.activeRouteId, "nevada-fall-mist", "\(order): the trail link opens the default route")
            XCTAssertEqual(model.selection, .hike(routeId: "nevada-fall-mist"), "\(order)")
            XCTAssertEqual(model.frameOptions.highlightedRouteId, "nevada-fall-mist", "\(order)")
            assertFits(model, routeId: "nevada-fall-mist", size: phone, insets: phoneInsets, "\(order)")
        }
    }

    func testRouteLinkSelectsThatVariantAndTheCardRefitFollowsInsetsResizesAndNotUserPans() {
        let model = readyModel(route: "yosemite-falls-columbia-rock")
        XCTAssertEqual(model.activeRouteId, "yosemite-falls-columbia-rock")
        assertFits(model, routeId: "yosemite-falls-columbia-rock", size: phone, insets: phoneInsets, "initial fit")
        XCTAssertNil(model.frameContent.markers.first { $0.id == "trail-yosemite-falls" }, "the hike's trailhead pin is replaced by the route markers")
        XCTAssertNotNil(model.frameContent.markers.first { $0.id == MapMarker.routeStartId })
        let destination = model.frameContent.markers.first { $0.id == MapMarker.routeDestinationId }
        XCTAssertEqual(destination?.title, "Turnaround", "a fresh selection is focused, so the badge label is compact")
        XCTAssertEqual(destination?.accessibleName, "Destination · Columbia Rock", "VoiceOver keeps the full name")
        model.focusesHike = false
        XCTAssertEqual(model.frameContent.markers.first { $0.id == MapMarker.routeDestinationId }?.title, "Destination · Columbia Rock", "all places restores the full label")
        model.focusesHike = true

        // The hike card appears and raises the bottom inset: the route is refitted once so nothing hides behind it.
        let taller = UIEdgeInsets(top: 150, left: 0, bottom: 260, right: 64)
        model.obscuredInsets = taller
        assertFits(model, routeId: "yosemite-falls-columbia-rock", size: phone, insets: taller, "after the card inset")

        // Rotation keeps the whole route framed, with the chrome insets that layout reports.
        let landscape = CGSize(width: 844, height: 390)
        let landscapeInsets = UIEdgeInsets(top: 90, left: 0, bottom: 130, right: 64)
        model.obscuredInsets = landscapeInsets
        layOut(model, landscape)
        assertFits(model, routeId: "yosemite-falls-columbia-rock", size: landscape, insets: landscapeInsets, "after rotation")
        model.obscuredInsets = taller

        // A user pan ends the automatic following; later layout changes leave the camera alone.
        var panned = model.camera
        panned.pan(byScreen: CGPoint(x: -150, y: 30))
        model.cameraDidChange(panned)
        layOut(model, phone)
        XCTAssertEqual(model.camera.center, panned.center)
        XCTAssertEqual(model.activeRouteId, "yosemite-falls-columbia-rock", "panning never clears the route")

        // Switching variant refits; Fit refits; dismissing clears the overlay and its markers.
        model.selectHike("yosemite-falls-top", animated: false)
        XCTAssertEqual(model.activeRouteId, "yosemite-falls-top")
        assertFits(model, routeId: "yosemite-falls-top", size: phone, insets: taller, "variant switch")
        panned = model.camera
        panned.pan(byScreen: CGPoint(x: 90, y: 0))
        model.cameraDidChange(panned)
        model.fitActiveRoute(animated: false)
        assertFits(model, routeId: "yosemite-falls-top", size: phone, insets: taller, "explicit fit")
        model.clearHike()
        XCTAssertNil(model.activeRouteId)
        XCTAssertNil(model.selection)
        XCTAssertNil(model.frameOptions.highlightedRouteId)
        XCTAssertNil(model.frameContent.markers.first { $0.id == MapMarker.routeStartId })
        XCTAssertNotNil(model.frameContent.markers.first { $0.id == "trail-yosemite-falls" }, "the trailhead pin returns")
        XCTAssertEqual(model.frameContent.markers.first { $0.id == "trail-yosemite-falls" }?.title, "Yosemite Falls Trail · trailhead")
    }

    func testDirectRefitStopsARunningRouteAnimationOnTheAttachedCanvas() {
        // Selecting a route animates toward a fit computed with the pre-card insets. The card then raises
        // the inset and refits directly; the old display link must not finish later and overwrite that fit.
        let model = valleyModel()
        let canvas = MapCanvas(camera: model.camera, options: model.frameOptions)
        canvas.frame = CGRect(origin: .zero, size: phone)
        canvas.onCameraChange = { [weak model] camera in model?.cameraDidChange(camera) }
        model.attach(canvas)
        model.setScene(scene)
        canvas.layoutSubviews()
        XCTAssertTrue(model.hasLaidOut)
        model.configure(content: content, saved: SavedState(), elementScale: 1, dark: false)
        model.focus(on: .hikeRoute("nevada-fall-mist"), animated: true)
        XCTAssertTrue(canvas.isAnimating, "a selection with a live canvas animates to the fit")
        let before = canvas.camera
        let taller = UIEdgeInsets(top: 150, left: 0, bottom: 300, right: 64)
        model.obscuredInsets = taller
        XCTAssertFalse(canvas.isAnimating, "the direct refit stops the running animation")
        XCTAssertEqual(canvas.camera, model.camera, "the canvas now shows exactly the refit camera")
        XCTAssertNotEqual(canvas.camera, before)
        assertFits(canvas.camera, routeId: "nevada-fall-mist", size: phone, insets: taller, floor: model.scaleLimits.lowerBound, "attached refit")
        canvas.stopAnimation()
    }

    func testRouteBadgesAndHikeEntryPointsKeepOrOpenTheWholeRoute() {
        let model = readyModel(route: "half-dome-mist")
        let fit = model.camera
        // Tapping the route's own start or destination badge (touch or VoiceOver activation) keeps the hike up.
        model.handleTap(.marker(id: MapMarker.routeDestinationId), at: .zero)
        XCTAssertEqual(model.selection, .hike(routeId: "half-dome-mist"))
        XCTAssertEqual(model.activeRouteId, "half-dome-mist")
        model.handleTap(.marker(id: MapMarker.routeStartId), at: .zero)
        XCTAssertEqual(model.selection, .hike(routeId: "half-dome-mist"))
        XCTAssertEqual(model.camera, fit, "badge taps never move the map or open a place")

        // A hike's trailhead pin and its place link both open the complete default route, not a generic place.
        model.clearHike()
        model.handleTap(.marker(id: "trail-yosemite-falls"), at: .zero)
        XCTAssertEqual(model.activeRouteId, "yosemite-falls-top")
        XCTAssertEqual(model.selection, .hike(routeId: "yosemite-falls-top"))
        model.focus(on: .place("trail-valley-loop"), animated: false)
        XCTAssertEqual(model.activeRouteId, "valley-loop-full")
        assertFits(model, routeId: "valley-loop-full", size: phone, insets: phoneInsets, "place focus on a hike")
        model.focus(on: .place("ahwahnee-hotel"), animated: false)
        XCTAssertEqual(model.selection, .place("ahwahnee-hotel"), "ordinary places still focus as places")
        XCTAssertNil(model.activeRouteId)
    }

    func testHalfDomeFitsOnPhoneAndTabletAndStaysInsideTheWidenedClamp() throws {
        for (size, insets) in [(phone, phoneInsets), (CGSize(width: 1024, height: 1366), UIEdgeInsets(top: 120, left: 0, bottom: 200, right: 64)),
                               (CGSize(width: 1366, height: 1024), UIEdgeInsets(top: 120, left: 0, bottom: 110, right: 64))] {
            let model = valleyModel(insets: insets)
            model.setScene(scene)
            layOut(model, size)
            model.configure(content: content, saved: SavedState(), elementScale: 1, dark: false)
            model.focus(on: .hikeRoute("half-dome-mist"), animated: false)
            assertFits(model, routeId: "half-dome-mist", size: size, insets: insets, "\(size)")
            let route = scene.hikeRoutes["half-dome-mist"]!
            XCTAssertGreaterThan(route.bounds.maxX, scene.extent.maxX, "Half Dome leaves the ordinary Valley extent")
            let clamp = try XCTUnwrap(model.clampRect)
            XCTAssertTrue(clamp.contains(route.bounds), "\(size): the clamp holds the whole trace")
            var clamped = model.camera
            clamped.clamp(to: clamp)
            XCTAssertEqual(clamped.center.x, model.camera.center.x, accuracy: 0.01, "\(size): clamping the fitted camera does not shift it")
            XCTAssertEqual(clamped.center.y, model.camera.center.y, accuracy: 0.01, "\(size): clamping the fitted camera does not shift it")
            XCTAssertTrue(clamped.visibleRect().contains(route.bounds), "\(size)")
            let park = try TerrainGrid.load(file: TerrainGrid.parkFile)
            XCTAssertTrue(scene.projection.projectedRect(park.bounds).contains(model.camera.visibleRect()), "\(size): the view stays on the park relief")
        }
        let plain = valleyModel()
        plain.setScene(scene)
        XCTAssertEqual(plain.clampRect, scene.extent.insetBy(dx: -2000, dy: -2000), "without a hike the clamp is the Valley extent")
    }

    func testSelectedRouteIsDrawnAndTappableAboveHiddenTrailsAndShuttleOverlays() {
        let model = readyModel(route: "vernal-fall-clark-point-loop")
        let route = scene.hikeRoutes["vernal-fall-clark-point-loop"]!
        // The Clark Point cut-off is an unnamed feature the base renderer hides below scale 0.15; at 0.03 every trail is culled.
        let cutoff = scene.trails.first { $0.id == "20407" }!
        XCTAssertNil(cutoff.name)
        XCTAssertFalse(MapRenderer.trailVisible(cutoff, scale: 0.05))
        XCTAssertTrue(scene.trails.allSatisfy { !MapRenderer.trailVisible($0, scale: 0.03) || $0.styleKey == "bike" })
        let mid = cutoff.points[cutoff.points.count / 2]
        let camera = MapCamera(center: mid, scale: 0.03, viewSize: phone)
        let screen = camera.screenPoint(for: mid)
        let hit = MapHitTester.hit(at: screen, scene: scene, camera: camera, content: MapFrameContent(), options: model.frameOptions)
        XCTAssertEqual(hit, .route(id: "vernal-fall-clark-point-loop"), "the highlighted route is tappable where the base trail is culled")
        var off = model.frameOptions
        off.highlightedRouteId = nil
        XCTAssertEqual(MapHitTester.hit(at: screen, scene: scene, camera: camera, content: MapFrameContent(), options: off), .none)
        model.handleTap(hit, at: screen)
        XCTAssertEqual(model.selection, .hike(routeId: "vernal-fall-clark-point-loop"))
        XCTAssertTrue(route.bounds.contains(mid))

        // A shuttle shape running along the same corridor: the route is drawn above it, so it also wins the tap.
        let shuttle = MapOverlayLine(id: "route-shuttle", points: route.points, colorHex: "#3eb649", width: 2.6, dashed: false, directional: true)
        let content = MapFrameContent(overlayLines: [shuttle])
        let close = MapCamera(center: mid, scale: 1, viewSize: phone)
        XCTAssertEqual(MapHitTester.hit(at: close.screenPoint(for: mid), scene: scene, camera: close, content: content, options: model.frameOptions), .route(id: "vernal-fall-clark-point-loop"))
        XCTAssertEqual(MapHitTester.hit(at: close.screenPoint(for: mid), scene: scene, camera: close, content: content, options: off), .overlayLine(id: "route-shuttle"), "without a hike the shuttle shape is inspectable as before")

        // Tapping a shared base segment keeps the raw segment selection; the card lists every hike that walks it.
        let approach = scene.trails.first { $0.id == "20007" }!
        model.cameraDidChange(MapCamera(center: approach.points[approach.points.count / 2], scale: 1, viewSize: phone))
        model.handleTap(.trail(id: "20007"), at: .zero)
        XCTAssertEqual(model.selection, .trail(id: "20007"))
        XCTAssertNil(model.activeRouteId, "selecting something else clears the hike overlay")
        XCTAssertEqual(Set(self.content.hikeRoutes(usingFeature: 20007).map(\.trailId)).count, 5, "four Valley hikes and the Panorama Trail descent")
    }

    func testConcurrentMapLoadsBothSeeTheReadyScene() async {
        // A region map opened by deep link while the Map tab is still loading must not be left on "Loading".
        let store = GeoPackStore()
        var seen: [Bool] = []
        func loadAndCheck() async -> Bool {
            await store.loadMap()
            if case .ready = store.map { return true }
            return false
        }
        async let first = loadAndCheck()
        async let second = loadAndCheck()
        seen = await [first, second]
        XCTAssertEqual(seen, [true, true], "both callers return only once the shared build is ready")
        guard case .ready(let scene) = store.map else { return XCTFail("map scene should be ready") }
        XCTAssertFalse(scene.roads.isEmpty)
        await store.loadMap()
        guard case .ready(let again) = store.map else { return XCTFail("still ready") }
        XCTAssertTrue(again === scene, "a later call reuses the built scene")
    }

    func testConcurrentSceneAndProfileRequestsShareOneLoadAndSettle() async {
        let store = GeoPackStore()
        async let profile = store.hikeProfile(for: "four-mile-one-way")
        async let load: Void = store.loadMap()
        let (first, _) = await (profile, load)
        XCTAssertNotNil(first, "a profile asked for while the scene is still loading waits for it instead of giving up")
        guard case .ready(let scene) = store.map else { return XCTFail("map scene should be ready") }
        XCTAssertEqual(scene.hikeRoutes.count, content.hikeRoutes.routes.count, "Valley-pack and park-pack routes all resolve on the one map")
        let again = await store.hikeProfile(for: "four-mile-one-way")
        XCTAssertEqual(again, first, "cached")
        let missing = await store.hikeProfile(for: "no-such-route")
        XCTAssertNil(missing, "an unknown route is a terminal nil, not a hang")
    }

    func testMiniMapRefitsTheLatestVariantAfterARelayout() throws {
        // Columbia Rock is the lower part of the top-of-falls route, so a canvas still fitting the first
        // trace after a rotation would crop the second.
        let first = try XCTUnwrap(scene.hikeRoutes["yosemite-falls-columbia-rock"])
        let second = try XCTUnwrap(scene.hikeRoutes["yosemite-falls-top"])
        let firstRoute = try XCTUnwrap(content.hikeRoute(first.id)), secondRoute = try XCTUnwrap(content.hikeRoute(second.id))
        let host = UIHostingController(rootView: HikeMiniMap(scene: scene, route: firstRoute, trace: first, dark: false))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 230))
        window.rootViewController = host
        window.isHidden = false
        func settle() {
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        func canvas(in view: UIView) -> MapCanvas? {
            if let c = view as? MapCanvas { return c }
            for sub in view.subviews { if let c = canvas(in: sub) { return c } }
            return nil
        }
        settle()
        let canvas = try XCTUnwrap(canvas(in: host.view), "the mini-map hosts a MapCanvas")
        XCTAssertFalse(canvas.isUserInteractionEnabled)
        XCTAssertEqual(canvas.options.highlightedRouteId, first.id)
        XCTAssertTrue(canvas.camera.visibleRect().contains(first.bounds))

        host.rootView = HikeMiniMap(scene: scene, route: secondRoute, trace: second, dark: false)
        settle()
        XCTAssertEqual(canvas.options.highlightedRouteId, second.id, "the variant switch reaches the canvas")
        XCTAssertTrue(canvas.camera.visibleRect().contains(second.bounds))

        window.frame = CGRect(x: 0, y: 0, width: 844, height: 230)
        settle()
        XCTAssertEqual(canvas.camera.viewSize.width, 844, accuracy: 1)
        XCTAssertTrue(canvas.camera.visibleRect().contains(second.bounds), "a relayout refits the variant shown now, not the one the canvas was created with")
        XCTAssertEqual(canvas.content.markers.prefix(2).map(\.id), [MapMarker.routeStartId, MapMarker.routeDestinationId])
        XCTAssertEqual(canvas.content.markers.prefix(2).map(\.title), ["Start", "Turnaround"], "the mini-map uses compact endpoint labels; names live in its accessibility label")
        let waypoints = canvas.content.markers.dropFirst(2)
        XCTAssertEqual(waypoints.map(\.title), ["Columbia Rock", "Top junction"], "the outward waypoints are dotted with compact names")
        XCTAssertTrue(waypoints.allSatisfy { $0.id.hasPrefix(MapMarker.routeMilestonePrefix) && $0.labelMinScale == nil })
        XCTAssertEqual(MapMarker.routeMarkers(for: second).map(\.title),
                       ["Start · \(second.start.name)", "\(second.destination.approximate ? "Approximate destination" : "Destination") · \(second.destination.name)"],
                       "full-map labels keep the names")

        // The inspection cursor reaches the canvas without moving its camera.
        let framed = canvas.camera
        host.rootView = HikeMiniMap(scene: scene, route: secondRoute, trace: second, dark: false, cursor: second.chainage.point(at: 500))
        settle()
        XCTAssertEqual(canvas.content.routeCursor, second.chainage.point(at: 500))
        XCTAssertEqual(canvas.camera, framed, "a cursor change never refits the mini-map")
        window.isHidden = true
    }

    func testHikeRouteLinksRoundTripAndPlainTrailLinksStillWork() {
        let router = AppRouter()
        let url = AppRouter.url(for: .hikeRoute(trailId: "trail-half-dome", routeId: "half-dome-john-muir"))!
        XCTAssertEqual(url.absoluteString, "enveyosemite://trail/trail-half-dome/half-dome-john-muir")
        router.open(url: url)
        XCTAssertEqual(router.section, .trails)
        XCTAssertEqual(router.paths[.trails], [.hikeRoute(trailId: "trail-half-dome", routeId: "half-dome-john-muir")])
        let legacy = AppRouter()
        legacy.open(url: URL(string: "pettyfieldguide://trail/trail-half-dome")!)
        XCTAssertEqual(legacy.paths[.trails], [.trail("trail-half-dome")])
        XCTAssertEqual(AppSection.pillTabs, [.map, .trails, .directory, .status], "Trails is a primary tab")
    }
}
