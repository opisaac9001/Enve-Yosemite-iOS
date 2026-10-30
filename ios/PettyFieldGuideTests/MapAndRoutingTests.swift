import XCTest
import CoreLocation
@testable import PettyFieldGuide

@MainActor
final class MapAndRoutingTests: XCTestCase {
    func testLayerTogglesChangeRenderingOptions() {
        let model = MapViewModel()
        XCTAssertTrue(model.frameOptions.showBuildings)
        XCTAssertFalse(model.frameOptions.showContours)
        model.layers.contours = true
        XCTAssertTrue(model.frameOptions.showContours)
        model.layers.buildings = false
        XCTAssertFalse(model.frameOptions.showBuildings)
        model.layers.buildingLabels = .off
        XCTAssertEqual(model.frameOptions.buildingLabelMode, .off)
        model.layers.emphasizeShuttle = true
        XCTAssertTrue(model.frameOptions.emphasizeShuttle)
    }

    func testValleyMapPersistsLayersAndCategoriesAcrossInstances() {
        let defaults = UserDefaults(suiteName: "pfg-map-\(UUID().uuidString)")!
        let first = MapViewModel(restoresPreferences: true, defaults: defaults)
        first.layers.contours = true
        first.layers.buildingLabels = .footprint
        first.activeCategories = ["food", "parking"]
        let second = MapViewModel(restoresPreferences: true, defaults: defaults)
        XCTAssertTrue(second.layers.contours)
        XCTAssertEqual(second.layers.buildingLabels, .footprint)
        XCTAssertTrue(second.frameOptions.showContours, "restored layers must reach the renderer options immediately")
        XCTAssertEqual(second.activeCategories, ["food", "parking"])
        let secondary = MapViewModel(defaults: defaults)
        XCTAssertEqual(secondary.layers, MapLayerToggles(), "secondary maps do not inherit the Valley map's choices")

        // A backup import rewrites the stored preferences and a live Valley map follows.
        defaults.set(try? JSONEncoder().encode(MapLayerToggles(smoke: true, buildings: false)), forKey: MapViewModel.layersKey)
        defaults.set(["shuttle"], forKey: MapViewModel.categoriesKey)
        second.reloadPreferences()
        XCTAssertTrue(second.layers.smoke)
        XCTAssertFalse(second.frameOptions.showBuildings)
        XCTAssertEqual(second.activeCategories, ["shuttle"])
    }

    func testAnimationsReplaceTheirDisplayLinkAndDoNotRetainTheCanvas() {
        var canvas: MapCanvas? = MapCanvas(camera: MapCamera(center: .zero, scale: 1, viewSize: CGSize(width: 300, height: 300)), options: MapFrameOptions(dark: false))
        weak let weakCanvas = canvas
        var target = canvas!.camera
        target.scale = 2
        canvas?.animate(to: target)
        canvas?.animate(to: target)
        XCTAssertTrue(canvas!.isAnimating)
        canvas?.stopAnimation()
        XCTAssertFalse(canvas!.isAnimating)
        canvas?.animate(to: target)
        canvas = nil
        XCTAssertNil(weakCanvas, "a live display link must not keep the canvas alive")
    }

    func testParkedCarPinRulesAndValleyCoverage() throws {
        let valley = YosemiteGeo.valleyCenter
        let pin = ParkedCar.pin(at: valley, basis: .manual, note: "  row C, by the restroom \n")
        XCTAssertEqual(pin.note, "row C, by the restroom")
        XCTAssertEqual(pin.basis, .manual)
        XCTAssertNil(ParkedCar.pin(at: valley, basis: .location, note: "   ").note, "a blank note is stored as no note")
        XCTAssertTrue(ParkedCar.isOnValleyMap(valley))
        let mariposaGrove = CLLocationCoordinate2D(latitude: 37.5083, longitude: -119.6020)
        XCTAssertFalse(ParkedCar.isOnValleyMap(mariposaGrove), "a pin beyond the bundled extent is never clamped onto the Valley map")
        let outside = ParkedCar.pin(at: mariposaGrove, basis: .location, note: "")
        let url = try XCTUnwrap(ParkedCar.externalMapURL(for: outside))
        XCTAssertEqual(url.host, "maps.apple.com")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ll" }?.value, "\(mariposaGrove.latitude),\(mariposaGrove.longitude)")

        // The pin survives the real encoding and a clear removes note and coordinates together.
        let data = try SavedStore.encoder.encode(pin)
        XCTAssertEqual(try SavedStore.decoder.decode(SavedCar.self, from: data), pin)
        let model = MapViewModel()
        model.camera.center = LocalProjection(origin: YosemiteGeo.valleyCenter).project(valley)
        XCTAssertEqual(model.centerCoordinate.latitude, valley.latitude, accuracy: 1e-9)
        XCTAssertEqual(model.centerCoordinate.longitude, valley.longitude, accuracy: 1e-9)
    }

    func testEveryGeneratedDeepLinkRoundTrips() {
        let cases: [(Route, AppSection)] = [
            (.trail("trail-vernal-fall"), .trails), (.campground("cg-upper-pines"), .trails), (.event("evt-1"), .events), (.permit("wilderness"), .permits),
            (.contact("dispatch"), .contacts), (.document("guide"), .documents), (.region("tuolumne"), .park), (.stop(7), .navigation), (.webcam("half-dome"), .status),
            (.explorerLayer("trails"), .trip), (.riskCheck("river"), .risks), (.fireIncident("CA-SNF-001234"), .fire), (.planner, .navigation),
        ]
        for (route, section) in cases {
            let router = AppRouter()
            router.open(url: AppRouter.url(for: route)!)
            XCTAssertEqual(router.section, section, "\(route)")
            XCTAssertEqual(router.paths[section], [route], "\(route)")
        }
        let map = AppRouter()
        map.open(url: AppRouter.url(for: .place("ahwahnee"))!)
        XCTAssertEqual(map.section, .map)
        XCTAssertEqual(map.mapFocus, .place("ahwahnee"))
        map.open(url: AppRouter.url(for: .site(campground: "cg-upper-pines", ridbId: "76"))!)
        XCTAssertEqual(map.mapFocus, .site(campground: "cg-upper-pines", ridbId: "76"))
        map.open(url: AppRouter.url(for: .housekeepingUnit("179"))!)
        XCTAssertEqual(map.mapFocus, .place("housekeeping-unit-179"))

        let tools = AppRouter()
        tools.open(url: AppRouter.url(for: MapTool.sunPreview)!)
        XCTAssertEqual(tools.section, .map)
        XCTAssertEqual(tools.pendingMapTool, .sunPreview)
        tools.open(url: AppRouter.url(for: MapTool.parkedCar)!)
        XCTAssertEqual(tools.pendingMapTool, .parkedCar)
        tools.open(url: AppRouter.url(for: AppSection.fire)!)
        XCTAssertEqual(tools.section, .fire)
        tools.open(url: AppRouter.url(for: AppSheet.waterIceGuide)!)
        XCTAssertEqual(tools.sheet, .waterIceGuide)
        XCTAssertNil(AppRouter.url(for: AppSheet.backup), "only sheets with a handled host produce links")
        XCTAssertEqual(SearchTopic.all.first { $0.id == "water" }?.sheet, .waterIceGuide)
        XCTAssertEqual(SearchTopic.all.first { $0.id == "parked-car" }?.mapTool, .parkedCar)

        let events = AppRouter()
        var filter = EventFilter(); filter.categories = ["Talk"]
        events.open(url: AppRouter.eventFilterURL(encoded: filter.encoded()!)!)
        XCTAssertEqual(events.section, .events)
        XCTAssertEqual(events.pendingEventFilter.flatMap(EventFilter.decode), filter)

        let untouched = AppRouter()
        untouched.open(url: URL(string: "enveyosemite://nonsense/1")!)
        untouched.open(url: URL(string: "https://example.com/place/x")!)
        XCTAssertEqual(untouched.section, .map)
        XCTAssertTrue(untouched.paths.isEmpty)
        XCTAssertNil(untouched.mapFocus)
    }

    func testGeneratedLinksUseTheEnveSchemeAndLegacyLinksStillOpen() throws {
        let generated: [URL?] = [
            AppRouter.url(for: Route.place("ahwahnee")), AppRouter.url(for: Route.site(campground: "cg-upper-pines", ridbId: "76")), AppRouter.url(for: Route.planner),
            AppRouter.url(for: MapTool.sunPreview), AppRouter.url(for: MapTool.layers), AppRouter.url(for: MapTool.parkedCar),
            AppRouter.url(for: AppSheet.updates), AppRouter.url(for: AppSheet.changelog), AppRouter.url(for: AppSheet.suggestions), AppRouter.url(for: AppSheet.waterIceGuide),
            AppRouter.url(for: AppSection.risks), AppRouter.eventFilterURL(encoded: EventFilter().encoded()!),
        ]
        for url in generated {
            XCTAssertEqual(try XCTUnwrap(url).scheme, "enveyosemite", "\(String(describing: url))")
        }
        XCTAssertEqual(AppRouter.url(for: Route.trail("trail-mist"))?.absoluteString, "enveyosemite://trail/trail-mist")

        // Links shared or server-generated before the rename keep working, host by host.
        let legacy: [(String, (AppRouter) -> Void)] = [
            ("pettyfieldguide://place/ahwahnee", { XCTAssertEqual($0.mapFocus, .place("ahwahnee")) }),
            ("pettyfieldguide://site/cg-upper-pines/76", { XCTAssertEqual($0.mapFocus, .site(campground: "cg-upper-pines", ridbId: "76")) }),
            ("pettyfieldguide://trail/trail-mist", { XCTAssertEqual($0.paths[.trails], [.trail("trail-mist")]) }),
            ("pettyfieldguide://event/evt-1", { XCTAssertEqual($0.paths[.events], [.event("evt-1")]) }),
            ("pettyfieldguide://stop/7", { XCTAssertEqual($0.paths[.navigation], [.stop(7)]) }),
            ("pettyfieldguide://section/risks", { XCTAssertEqual($0.section, .risks) }),
            ("pettyfieldguide://sun", { XCTAssertEqual($0.pendingMapTool, .sunPreview) }),
            ("pettyfieldguide://car", { XCTAssertEqual($0.pendingMapTool, .parkedCar) }),
            ("pettyfieldguide://water", { XCTAssertEqual($0.sheet, .waterIceGuide) }),
            ("pettyfieldguide://updates", { XCTAssertEqual($0.sheet, .updates) }),
            ("PettyFieldGuide://changelog", { XCTAssertEqual($0.sheet, .changelog) }),
            ("EnveYosemite://suggestions", { XCTAssertEqual($0.sheet, .suggestions) }),
        ]
        for (raw, check) in legacy {
            let router = AppRouter()
            router.open(url: URL(string: raw)!)
            check(router)
        }
        var filter = EventFilter(); filter.costs = ["free"]
        var legacyFilterLink = URLComponents(url: try XCTUnwrap(AppRouter.eventFilterURL(encoded: filter.encoded()!)), resolvingAgainstBaseURL: false)!
        legacyFilterLink.scheme = AppRouter.legacyScheme
        let events = AppRouter()
        events.open(url: try XCTUnwrap(legacyFilterLink.url))
        XCTAssertEqual(events.section, .events)
        XCTAssertEqual(events.pendingEventFilter.flatMap(EventFilter.decode), filter)

        // Anything else is ignored outright, even when the host would otherwise be valid.
        for raw in ["enveyosemite:place/ahwahnee", "yosemite://place/ahwahnee", "petty-fieldguide://place/ahwahnee", "https://enveyosemite/place/ahwahnee", "mailto:place@example.com"] {
            let router = AppRouter()
            router.open(url: URL(string: raw)!)
            XCTAssertEqual(router.section, .map, raw)
            XCTAssertNil(router.mapFocus, raw)
            XCTAssertNil(router.sheet, raw)
            XCTAssertNil(router.pendingMapTool, raw)
            XCTAssertTrue(router.paths.isEmpty, raw)
        }
    }
}
