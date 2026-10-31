import XCTest
import CoreLocation
import UIKit
@testable import PettyFieldGuide

/// Built once for every test class that needs the real bundled map.
enum SharedScene {
    static let map = try! MapSceneBuilder.build()
}

/// The one continuous map: what it holds, that no pack is drawn twice, and that every link lands on it.
@MainActor
final class ContinuousMapTests: XCTestCase {
    private static let content = try! BundleContent.load()
    private var content: Content { Self.content }
    private var scene: MapScene { SharedScene.map }

    private func model(size: CGSize = CGSize(width: 390, height: 844)) -> MapViewModel {
        let model = MapViewModel(restoresPreferences: true, defaults: UserDefaults(suiteName: "pfg-continuous-\(UUID().uuidString)")!)
        model.obscuredInsets = UIEdgeInsets(top: 150, left: 0, bottom: 120, right: 64)
        model.setScene(scene)
        var camera = model.camera
        camera.viewSize = size
        model.cameraDidChange(camera)
        model.configure(content: content, saved: SavedState(), elementScale: 1, dark: false)
        return model
    }

    // MARK: Geometry

    func testValleyDetailAndParkSupplementsMergeWithoutDuplicates() throws {
        for (name, ids) in [("roads", scene.roads.map(\.id)), ("trails", scene.trails.map(\.id)), ("buildings", scene.buildings.map(\.id)),
                            ("parking", scene.parking.map(\.id)), ("water lines", scene.waterLines.map(\.id)), ("lakes", scene.waterAreas.map(\.id))] {
            XCTAssertEqual(Set(ids).count, ids.count, "\(name): every feature appears once")
        }
        for (pack, features) in [("roads", scene.roads.map(\.id)), ("buildings", scene.buildings.map(\.id)), ("parking", scene.parking.map(\.id))] {
            let valley = try GeoJSON.parse(BundleContent.data("\(pack).geojson", subdirectory: "Geo")).features.compactMap(\.id)
            let park = try GeoJSON.parse(BundleContent.data("park-\(pack).geojson", subdirectory: "Geo")).features.compactMap(\.id)
            XCTAssertTrue(Set(valley).isDisjoint(with: park), "\(pack): the park supplement leaves out every Valley feature")
            let base = Set(features.map { $0.split(separator: "-").first.map(String.init) ?? $0 })
            XCTAssertTrue(base.isSuperset(of: valley) && base.isSuperset(of: park), "\(pack): both packs are drawn")
        }
        let nps = try GeoJSON.parse(BundleContent.data("park-trails.geojson", subdirectory: "Geo")).features.compactMap(\.id)
        let trailIds = Set(scene.trails.map { $0.id.split(separator: "-").first.map(String.init) ?? $0.id })
        XCTAssertEqual(trailIds, Set(nps), "every NPS trail feature is on the map exactly once")
        XCTAssertTrue(scene.trails.allSatisfy { ["trail", "trail-major", "bike"].contains($0.styleKey) }, "one trail style family, Valley or not")
    }

    func testParkWideDetailReachesBeyondTheValley() {
        let valley = scene.projection.projectedRect(YosemiteGeo.valleyBounds)
        let beyond = { (rects: [CGRect]) in rects.filter { !valley.intersects($0) }.count }
        XCTAssertGreaterThan(beyond(scene.roads.map(\.bounds)), 400)
        XCTAssertGreaterThan(beyond(scene.buildings.map(\.bounds)), 1000)
        XCTAssertGreaterThan(beyond(scene.parking.map(\.bounds)), 100)
        XCTAssertGreaterThan(beyond(scene.waterAreas.map(\.bounds)), 1000, "NHD lakes across the high country")
        XCTAssertTrue(scene.waterAreas.contains { $0.name == "Tenaya Lake" })
        XCTAssertTrue(scene.waterLines.contains { $0.name == "Tuolumne River" && $0.styleKey == "river" })
        XCTAssertTrue(scene.labels.contains { $0.text == "Mount Lyell" && $0.minScale <= 0.004 }, "the park's highest summit is named from the overview")
        XCTAssertFalse(scene.labels.contains { $0.text == "El Capitan" }, "curated Valley landmarks are not labelled twice")
        let layers = scene.relief?.layers ?? []
        XCTAssertEqual(layers.count, 4, "outer, surround, park and Valley tiers")
        XCTAssertTrue(layers[2].footprint.contains(scene.extent), "the 3DEP park tier covers the whole extent")
        XCTAssertTrue(layers[1].footprint.contains(layers[2].footprint) && layers[0].footprint.contains(layers[1].footprint), "coarser tiers sit beneath")
        XCTAssertGreaterThan(layers[2].levels.count, 3, "a pyramid keeps whole-park views cheap to draw")
        XCTAssertNotNil(layers[0].levels[0].coverage, "the outer tier records its open-ocean gaps")
        XCTAssertTrue(layers[1...].allSatisfy { $0.levels[0].coverage == nil }, "the other tiers have none")
    }

    func testFirePerimetersAreAFireMapLayerNotBaseTerrain() throws {
        let scar = try XCTUnwrap(scene.fireScars.first { $0.contains($0.centroid) })
        let scarsOnly = MapScene(projection: scene.projection, extent: scene.extent, roads: [], trails: [], waterLines: [], waterAreas: [], buildings: [], parking: [],
                                 pois: [], boundary: [], fireScars: [scar], contours: [], sources: [])
        let camera = MapCamera(center: scar.centroid, scale: 0.02, viewSize: CGSize(width: 390, height: 844))
        let point = camera.screenPoint(for: scar.centroid)
        var options = MapFrameOptions(dark: false)
        XCTAssertFalse(options.showFireScars, "the Map tab never draws historical perimeters as terrain")
        XCTAssertEqual(MapHitTester.hit(at: point, scene: scarsOnly, camera: camera, content: MapFrameContent(), options: options), .none)
        options.showFireScars = true
        XCTAssertEqual(MapHitTester.hit(at: point, scene: scarsOnly, camera: camera, content: MapFrameContent(), options: options), .fireScar(id: scar.id))
    }

    func testLocalProjectionHoldsAcrossThePark() {
        let p = scene.projection
        let corners = [CLLocationCoordinate2D(latitude: 37.37, longitude: -120.05), CLLocationCoordinate2D(latitude: 38.30, longitude: -119.05),
                       CLLocationCoordinate2D(latitude: 37.8735, longitude: -119.3590)]
        for c in corners {
            let back = p.unproject(p.project(c))
            XCTAssertEqual(back.latitude, c.latitude, accuracy: 1e-9)
            XCTAssertEqual(back.longitude, c.longitude, accuracy: 1e-9)
            // Projected distance from the Valley stays within 1 % of the great-circle distance even at the park's corners.
            let projected = hypot(p.project(c).x, p.project(c).y)
            XCTAssertEqual(projected, haversineMeters(YosemiteGeo.valleyCenter, c), accuracy: haversineMeters(YosemiteGeo.valleyCenter, c) * 0.01)
        }
    }

    func testPlanarDecodingInvertsTheBuildToolIncludingWrapAround() {
        let width = 4, height = 3
        let units: [Int32] = [0, 15_976, 7, 65_535, 3, 2, 40_000, 1, 65_000, 0, 12, 13]
        var residuals = Data()
        for row in 0..<height {
            for col in 0..<width {
                let i = row * width + col
                let prediction: Int32 = row == 0 ? (col > 0 ? units[i - 1] : 0) : col == 0 ? units[i - width] : units[i - 1] + units[i - width] - units[i - width - 1]
                let r = UInt16(truncatingIfNeeded: units[i] - prediction)
                residuals.append(contentsOf: [UInt8(r & 0xFF), UInt8(r >> 8)])
            }
        }
        XCTAssertEqual(TerrainGrid.planarDecode(residuals, width: width, height: height, scale: 0.25), units.map { Float($0) * 0.25 })
    }

    func testPlanarDecodingAppliesTheOffsetAndMarksNoData() {
        var residuals = Data()
        for r: UInt16 in [100, 0xFFFF &- 100, 4] { residuals.append(contentsOf: [UInt8(r & 0xFF), UInt8(r >> 8)]) }
        let values = TerrainGrid.planarDecode(residuals, width: 3, height: 1, scale: 0.25, offset: -85, noData: 0xFFFF)
        XCTAssertEqual(values[0], 100 * 0.25 - 85)
        XCTAssertTrue(values[1].isNaN, "the reserved unit value is a gap, not an elevation")
        XCTAssertEqual(values[2], 3 * 0.25 - 85, "decoding continues across a gap")
    }

    /// Worst cases for the zoom floor: phones and iPads in both orientations, split view and heavy chrome. Every
    /// layout can show the whole park between its chrome, and no view at the floor, wherever it is panned, leaves
    /// the unfaded outer relief.
    func testZoomFloorKeepsEveryLayoutOnTerrainAndTheParkBetweenTheChrome() throws {
        let outer = try XCTUnwrap(scene.relief?.layers.first)
        let fadeX = CGFloat(outer.feather) * outer.footprint.width / CGFloat(outer.width), fadeY = CGFloat(outer.feather) * outer.footprint.height / CGFloat(outer.height)
        let solid = outer.footprint.insetBy(dx: fadeX, dy: fadeY)
        let layouts: [(String, CGSize, UIEdgeInsets)] = [
            ("SE portrait", CGSize(width: 320, height: 568), UIEdgeInsets(top: 124, left: 0, bottom: 140, right: 64)),
            ("SE landscape", CGSize(width: 568, height: 320), UIEdgeInsets(top: 92, left: 0, bottom: 120, right: 64)),
            ("Air portrait", CGSize(width: 420, height: 912), UIEdgeInsets(top: 170, left: 0, bottom: 165, right: 64)),
            ("Air landscape", CGSize(width: 912, height: 420), UIEdgeInsets(top: 110, left: 0, bottom: 140, right: 64)),
            ("phone landscape, tall chrome", CGSize(width: 844, height: 390), UIEdgeInsets(top: 120, left: 0, bottom: 150, right: 64)),
            ("iPad portrait", CGSize(width: 1032, height: 1376), UIEdgeInsets(top: 140, left: 0, bottom: 130, right: 64)),
            ("iPad landscape", CGSize(width: 1376, height: 1032), UIEdgeInsets(top: 130, left: 0, bottom: 120, right: 64)),
            ("iPad one-third split", CGSize(width: 320, height: 1366), UIEdgeInsets(top: 170, left: 0, bottom: 150, right: 64)),
            ("iPad slide over", CGSize(width: 320, height: 1024), UIEdgeInsets(top: 170, left: 0, bottom: 150, right: 64)),
        ]
        for (name, size, insets) in layouts {
            let m = model(size: size)
            m.obscuredInsets = insets
            let floor = m.scaleLimits.lowerBound
            let park = m.fitParkCamera(viewSize: size)
            XCTAssertGreaterThanOrEqual(park.scale, floor - 1e-12, "\(name): Fit park is reachable, so the whole park fits between the chrome")
            let boundary = try XCTUnwrap(scene.boundary.first?.bounds)
            XCTAssertTrue(park.visibleRect().contains(boundary), name)
            for corner in [CGPoint(x: -1e9, y: -1e9), CGPoint(x: 1e9, y: 1e9), CGPoint(x: -1e9, y: 1e9), CGPoint(x: 1e9, y: -1e9), .zero] {
                var camera = MapCamera(center: corner, scale: floor, viewSize: size)
                camera.clamp(to: try XCTUnwrap(m.clampRect))
                XCTAssertTrue(solid.contains(camera.visibleRect()), "\(name): a view panned to \(corner) at the floor leaves the relief")
            }
        }
        // Chrome leaving a band too thin to fit the park raises the floor to the terrain edge instead of showing bare ground.
        let cramped = model(size: CGSize(width: 844, height: 390))
        cramped.obscuredInsets = UIEdgeInsets(top: 150, left: 0, bottom: 160, right: 64)
        XCTAssertEqual(cramped.scaleLimits.lowerBound, cramped.terrainFloor(viewSize: CGSize(width: 844, height: 390)), accuracy: 1e-12)
        var camera = MapCamera(center: .zero, scale: cramped.scaleLimits.lowerBound, viewSize: CGSize(width: 844, height: 390))
        camera.clamp(to: try XCTUnwrap(cramped.clampRect))
        XCTAssertTrue(solid.insetBy(dx: -1, dy: -1).contains(camera.visibleRect()))
    }

    // MARK: Links and focus

    func testEveryKindOfLinkLandsOnTheOneMap() throws {
        let m = model()
        m.focus(on: .hikeRoute("dewey-point-rt"), animated: false)
        XCTAssertEqual(m.activeRouteId, "dewey-point-rt", "a park-pack route draws on the same map as Valley routes")
        let halfDome = try XCTUnwrap(content.defaultHikeRoute(for: "trail-half-dome"))
        m.focus(on: .hikeRoute(halfDome.id), animated: false)
        XCTAssertEqual(m.activeRouteId, halfDome.id)

        m.focus(on: .trail("trail-cathedral-lakes"), animated: false)
        XCTAssertNil(m.activeRouteId, "no line for a hike without a reviewed trace")
        let trailhead = ParkMapView.trailheadMarkerId(try XCTUnwrap(content.trail("trail-cathedral-lakes")))
        XCTAssertEqual(m.selection, .place(trailhead))
        XCTAssertTrue(m.frameContent.markers.contains { $0.id == trailhead }, "the picked trailhead is drawn whatever the filters")

        m.focus(on: .place("ev-tuolumne-meadows"), animated: false)
        XCTAssertEqual(m.selection, .place("ev-tuolumne-meadows"))
        XCTAssertTrue(m.frameContent.markers.contains { $0.id == "ev-tuolumne-meadows" })
        XCTAssertTrue(m.camera.visibleRect().contains(scene.projection.project(try XCTUnwrap(content.place("ev-tuolumne-meadows")).coordinate)))

        m.focus(on: .coordinate(latitude: 37.80, longitude: -119.70, label: "Shared point"), animated: false)
        XCTAssertEqual(m.shownPin?.title, "Shared point")
        XCTAssertEqual(m.selection, .place(ShownPin.markerId))
        XCTAssertTrue(m.frameContent.markers.contains { $0.id == ShownPin.markerId })
        m.clearShownPin()
        XCTAssertNil(m.shownPin)
        XCTAssertFalse(m.frameContent.markers.contains { $0.id == ShownPin.markerId })

        var saved = SavedState()
        saved.car = SavedCar(latitude: 37.5083, longitude: -119.6020, note: nil, basis: .manual, updatedAt: .stamp)
        m.update(saved: saved)
        m.focus(on: .coordinate(latitude: 37.5083, longitude: -119.6020, label: "My car"), animated: false)
        XCTAssertEqual(m.selection, .car, "the car keeps its own marker instead of a pin")
        XCTAssertNil(m.shownPin)
    }

    func testRegionAndWholeParkFramesWaitForLayoutAndFitTheirAreas() throws {
        let m = MapViewModel(restoresPreferences: true, defaults: UserDefaults(suiteName: "pfg-continuous-\(UUID().uuidString)")!)
        m.configure(content: content, saved: SavedState(), elementScale: 1, dark: false)
        m.focus(on: .region("hetch-hetchy"), animated: false)
        m.setScene(scene)
        let canvas = MapCanvas(camera: m.camera, options: m.frameOptions)
        canvas.onCameraChange = { [weak m] in m?.cameraDidChange($0) }
        m.attach(canvas)
        canvas.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        canvas.layoutIfNeeded()
        let region = try XCTUnwrap(ParkMapView.regionRect("hetch-hetchy", scene: scene, content: content))
        XCTAssertTrue(m.camera.visibleRect().contains(region), "a region link that arrived before the scene still frames the region")
        m.focus(on: .park, animated: false)
        let park = try XCTUnwrap(scene.boundary.first?.bounds)
        XCTAssertTrue(m.camera.visibleRect().insetBy(dx: -1, dy: -1).contains(park))
        XCTAssertGreaterThanOrEqual(m.camera.scale, m.scaleLimits.lowerBound - 1e-12)
    }

    func testCoverageAndDeepLinksUseOneMap() throws {
        XCTAssertTrue(MapCoverage.canShow(.hikeRoute("dewey-point-rt"), content: content))
        XCTAssertTrue(MapCoverage.canShow(.trail("trail-cathedral-lakes"), content: content), "untraced park hikes open at their trailhead")
        XCTAssertTrue(MapCoverage.canShow(.place("ahwahnee-hotel"), content: content))
        XCTAssertTrue(MapCoverage.canShow(.site(campground: "cg-upper-pines", ridbId: "76"), content: content))
        XCTAssertTrue(MapCoverage.canShow(.region("tioga-tuolumne"), content: content))
        XCTAssertFalse(MapCoverage.canShow(.coordinate(latitude: 36.7378, longitude: -119.7871, label: "Fresno"), content: content))
        XCTAssertFalse(MapCoverage.canShow(.place("no-such-place"), content: content))

        let router = AppRouter()
        for scheme in ["enveyosemite", "pettyfieldguide"] {
            router.open(url: try XCTUnwrap(URL(string: "\(scheme)://place/ev-tuolumne-meadows")))
            XCTAssertEqual(router.mapFocus, .place("ev-tuolumne-meadows"))
            XCTAssertEqual(router.section, .map)
            router.mapFocus = nil
        }
    }

    func testParkMarkersFollowTheirCategoriesAndRegionPointsDeferToTrailheads() {
        let all = ParkMapView.markers(mode: .overview, projection: scene.projection, content: content, focusTrailId: nil, categories: nil)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "region points have their own ids")
        let none = ParkMapView.markers(mode: .overview, projection: scene.projection, content: content, focusTrailId: nil, categories: [])
        XCTAssertFalse(none.contains { $0.id.hasPrefix(ParkMapView.trailheadPrefix) || $0.id.hasPrefix("campground-") })
        XCTAssertTrue(none.contains { $0.id.hasPrefix("town-") }, "gateway towns are not a place category")
        let trailheads = all.filter { $0.id.hasPrefix(ParkMapView.trailheadPrefix) }.map(\.point)
        for marker in all where marker.id.hasPrefix("region-") {
            XCTAssertFalse(trailheads.contains { hypot($0.x - marker.point.x, $0.y - marker.point.y) < 300 }, "\(marker.title) duplicates a trailhead pin")
        }
        XCTAssertEqual(ParkMapView.regionId(ofMarker: ParkMapView.regionPointId("hetch-hetchy", 1)), "hetch-hetchy")
        XCTAssertNil(ParkMapView.regionId(ofMarker: "ahwahnee-hotel"))
    }
}
