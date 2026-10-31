import XCTest
import CoreGraphics
import CoreLocation
import UIKit
@testable import PettyFieldGuide

@MainActor
final class MapEngineTests: XCTestCase {
    private func grid(width: Int, height: Int, cell: Double = 20, _ f: (Int, Int) -> Float) -> TerrainGrid {
        var values = [Float](repeating: 0, count: width * height)
        for r in 0..<height { for c in 0..<width { values[r * width + c] = f(c, r) } }
        let bounds = GeoBounds(west: -119.6, south: 37.7, east: -119.6 + Double(width - 1) * cell / 88_000, north: 37.7 + Double(height - 1) * cell / 111_000)
        return TerrainGrid(width: width, height: height, bounds: bounds, cellSizeMeters: (cell, cell),
                           minElevation: Double(values.min()!), maxElevation: Double(values.max()!), elevations: values, source: "test", fetchedAt: "2026-10-27")
    }

    private func emptyValleyScene() -> MapScene {
        let projection = LocalProjection(origin: YosemiteGeo.valleyCenter)
        return MapScene(projection: projection, extent: projection.projectedRect(YosemiteGeo.valleyBounds), roads: [], trails: [], waterLines: [], waterAreas: [],
                        buildings: [], parking: [], pois: [], boundary: [], fireScars: [], contours: [], sources: [])
    }

    private func valleyModel() -> MapViewModel {
        let model = MapViewModel(restoresPreferences: true, defaults: UserDefaults(suiteName: "pfg-map-engine-\(UUID().uuidString)")!)
        model.obscuredInsets = UIEdgeInsets(top: 150, left: 0, bottom: 120, right: 64)
        return model
    }

    private func layOut(_ model: MapViewModel, _ size: CGSize) {
        var camera = model.camera
        camera.viewSize = size
        model.cameraDidChange(camera)
    }

    // MARK: Relief

    func testHillshadeLightsNorthWestFacingSlopesAndShadesSouthEastFacingOnes() {
        // Elevation rising toward the south-east gives a surface that faces the north-west light.
        let nwFacing = grid(width: 21, height: 21) { c, r in Float(c + r) * 10 }
        let seFacing = grid(width: 21, height: 21) { c, r in Float(40 - c - r) * 10 }
        let flat = grid(width: 21, height: 21) { _, _ in 1500 }
        let centre = 10 * 21 + 10
        let nw = Int(ReliefRenderer.shade(grid: nwFacing)[centre])
        let se = Int(ReliefRenderer.shade(grid: seFacing)[centre])
        let level = Int(ReliefRenderer.shade(grid: flat)[centre])
        XCTAssertEqual(level, 128, accuracy: 2, "flat ground is the neutral tone")
        XCTAssertGreaterThan(nw, level + 38)
        XCTAssertLessThan(se, level - 38)
    }

    func testReliefLayerIsNorthUpCoversTheCellFootprintAndFeathersItsEdge() throws {
        let g = grid(width: 12, height: 10) { _, r in r < 4 ? 2000 : 1200 }
        let projection = LocalProjection(origin: g.bounds.center)
        let layer = ReliefLayer(grid: g, projection: projection, feather: 3)
        XCTAssertEqual(layer.levels.count, 1, "a grid within one tile needs no pyramid")
        let centres = projection.projectedRect(g.bounds)
        XCTAssertEqual(layer.footprint.width, centres.width * 12 / 11, accuracy: 1e-6, "edge cells extend half a cell past their sample")
        XCTAssertEqual(layer.footprint.midY, centres.midY, accuracy: 1e-6)
        XCTAssertEqual(layer.tileRect(level: 0, col: 0, row: 0), layer.footprint)
        XCTAssertGreaterThan(layer.footprint.maxY, layer.footprint.minY, "maxY is the north edge, which the renderer maps to image row 0")
        let light = try XCTUnwrap(layer.tile(level: 0, col: 0, row: 0, dark: false))
        let bytes = try XCTUnwrap(light.dataProvider?.data as Data?)
        XCTAssertEqual(bytes.count, 12 * 10 * 4)
        func pixel(_ c: Int, _ r: Int) -> (r: Int, a: Int) { (Int(bytes[(r * 12 + c) * 4]), Int(bytes[(r * 12 + c) * 4 + 3])) }
        // Interior: the high northern block is tinted toward cool granite and its south-facing edge is shaded.
        XCTAssertLessThan(pixel(5, 3).r, pixel(5, 6).r)
        XCTAssertEqual(pixel(5, 6).a, 255)
        // Border cells fade out so the tier blends into whatever lies beneath instead of ending in a hard rectangle.
        XCTAssertEqual(pixel(0, 5).a, 0)
        XCTAssertEqual(pixel(5, 9).a, 0)
        XCTAssertEqual(pixel(1, 5).a, 85, accuracy: 1)
        XCTAssertLessThan(pixel(1, 5).r, pixel(5, 5).r, "premultiplied colour follows the alpha ramp")
        let dark = try XCTUnwrap(layer.tile(level: 0, col: 0, row: 0, dark: true)?.dataProvider?.data as Data?)
        XCTAssertLessThan(Int(dark[(6 * 12 + 5) * 4]), pixel(5, 6).r, "the dark palette is darker than the light one for the same cell")
    }

    func testBundledReliefTiersCoverTheParkAndCameraEnvelopeAndMatchKnownElevations() throws {
        let detail = try TerrainGrid.load(file: TerrainGrid.basemapFile)
        let park = try TerrainGrid.load(file: TerrainGrid.parkFile)
        let surround = try TerrainGrid.load(file: TerrainGrid.surroundFile)
        let outer = try TerrainGrid.load(file: TerrainGrid.outerFile)
        let v = YosemiteGeo.valleyBounds
        XCTAssertLessThan(detail.bounds.west, v.west)
        XCTAssertGreaterThan(detail.bounds.east, v.east)
        XCTAssertLessThan(detail.bounds.south, v.south)
        XCTAssertGreaterThan(detail.bounds.north, v.north)
        XCTAssertEqual(park.bounds, YosemiteGeo.parkBounds, "the 3DEP park grid covers every sample of the park extent")
        XCTAssertLessThan(detail.cellSizeMeters.x, 25)
        XCTAssertLessThan(max(park.cellSizeMeters.x, park.cellSizeMeters.y), 36)
        // Spacing must match the on-both-edges sampling the loader assumes.
        for grid in [detail, park, surround, outer] {
            let projection = LocalProjection(origin: grid.bounds.center)
            let span = projection.projectedRect(grid.bounds)
            XCTAssertEqual(span.width / Double(grid.width - 1), grid.cellSizeMeters.x, accuracy: 0.3, grid.source)
            XCTAssertEqual(span.height / Double(grid.height - 1), grid.cellSizeMeters.y, accuracy: 0.3, grid.source)
        }

        // The outermost tier must hold phones and iPads zoomed out to the floor (0.8 × whole-view fit), centred on the park.
        let projection = LocalProjection(origin: YosemiteGeo.valleyCenter)
        let extent = projection.projectedRect(YosemiteGeo.parkBounds)
        let outerRect = projection.projectedRect(outer.bounds)
        XCTAssertTrue(outerRect.contains(projection.projectedRect(surround.bounds)) && projection.projectedRect(surround.bounds).contains(extent), "tiers nest")
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390), CGSize(width: 1024, height: 1366), CGSize(width: 1366, height: 1024)] {
            let floor = 0.8 * min(size.width / extent.width, size.height / extent.height)
            let needed = CGRect(x: extent.midX - size.width / floor / 2, y: extent.midY - size.height / floor / 2, width: size.width / floor, height: size.height / floor)
            XCTAssertTrue(outerRect.contains(needed), "\(size): outer relief \(outerRect) must contain \(needed)")
        }
        // Only open ocean beyond 3DEP coverage is missing, and Death Valley's floor keeps its negative elevation.
        let gaps = outer.elevations.enumerated().filter { $0.element.isNaN }.map { outer.coordinate(col: Double($0.offset % outer.width), row: Double($0.offset / outer.width)) }
        XCTAssertFalse(gaps.isEmpty)
        XCTAssertTrue(gaps.allSatisfy { $0.longitude < -121.0 && $0.latitude < 37.1 }, "gaps lie only in the Pacific south-west of the Bay Area")
        XCTAssertTrue(park.elevations.allSatisfy { !$0.isNaN } && surround.elevations.allSatisfy { !$0.isNaN })
        XCTAssertLessThan(try XCTUnwrap(outer.elevation(at: .init(latitude: 36.2400, longitude: -116.8300))), 0, "Badwater Basin lies below sea level")

        let halfDome = try XCTUnwrap(detail.elevation(at: .init(latitude: 37.7459, longitude: -119.5332)))
        XCTAssertGreaterThan(halfDome, 2600, "Half Dome's summit is 2,693 m")
        let floor = try XCTUnwrap(detail.elevation(at: YosemiteGeo.valleyCenter))
        XCTAssertGreaterThan(floor, 1150)
        XCTAssertLessThan(floor, 1300)
        XCTAssertEqual(try XCTUnwrap(park.elevation(at: .init(latitude: 37.7459, longitude: -119.5332))), halfDome, accuracy: 150, "the 3DEP park grid agrees with the Valley tier")
        XCTAssertEqual(try XCTUnwrap(park.elevation(at: YosemiteGeo.valleyCenter)), floor, accuracy: 25)
        // Known points beyond the Valley: Mount Lyell's summit is 3,997 m and the Tuolumne Meadows visitor center about 2,620 m.
        XCTAssertGreaterThan(try XCTUnwrap(park.elevation(at: .init(latitude: 37.7393, longitude: -119.2716))), 3900)
        XCTAssertEqual(try XCTUnwrap(park.elevation(at: .init(latitude: 37.8735, longitude: -119.3590))), 2620, accuracy: 40)
        XCTAssertEqual(try XCTUnwrap(surround.elevation(at: .init(latitude: 37.7459, longitude: -119.5332))), halfDome, accuracy: 500, "the coarse surround is the same terrain")
        let sun = try TerrainGrid.load()
        XCTAssertEqual(sun.width, 320, "the sun/shadow crop is a separate, unchanged asset")
        XCTAssertEqual(sun.height, 152)
    }

    func testSubsampledGridKeepsSamplesOnTheirOriginalCoordinates() {
        // 11 columns subsampled by 3 keep columns 0, 3, 6, 9; the east edge moves to column 9's longitude.
        let g = grid(width: 11, height: 8) { c, r in Float(c * 100 + r) }
        let coarse = g.subsampled(by: 3)
        XCTAssertEqual(coarse.width, 4)
        XCTAssertEqual(coarse.height, 3)
        XCTAssertEqual(coarse.elevation(col: 3, row: 2), g.elevation(col: 9, row: 6))
        XCTAssertEqual(coarse.coordinate(col: 3, row: 2).longitude, g.coordinate(col: 9, row: 6).longitude, accuracy: 1e-12)
        XCTAssertEqual(coarse.coordinate(col: 3, row: 2).latitude, g.coordinate(col: 9, row: 6).latitude, accuracy: 1e-12)
        XCTAssertEqual(coarse.coordinate(col: 1, row: 1).longitude, g.coordinate(col: 3, row: 3).longitude, accuracy: 1e-12)
        XCTAssertEqual(coarse.cellSizeMeters.x, 60)
        XCTAssertEqual(coarse.bounds.north, g.bounds.north)
        XCTAssertEqual(coarse.bounds.west, g.bounds.west)
    }

    // MARK: Framing

    func testValleyMapFramesTheVisitorCoreOnlyAfterRealLayoutAndNeverAgain() {
        let phone = CGSize(width: 390, height: 844)
        let core = LocalProjection(origin: YosemiteGeo.valleyCenter).projectedRect(YosemiteGeo.valleyCore)

        let sceneFirst = valleyModel()
        let nominal = sceneFirst.camera
        sceneFirst.setScene(emptyValleyScene())
        XCTAssertFalse(sceneFirst.hasFramed, "a scene alone, with the nominal pre-layout camera, must not frame")
        XCTAssertEqual(sceneFirst.camera, nominal)
        layOut(sceneFirst, phone)
        XCTAssertTrue(sceneFirst.hasFramed)
        XCTAssertTrue(sceneFirst.camera.visibleRect().contains(core), "the whole visitor core is on screen")
        XCTAssertGreaterThan(sceneFirst.camera.scale, 0.05, "a phone opens on the core, not the whole-Valley diagram")
        let coreTop = sceneFirst.camera.screenPoint(for: CGPoint(x: core.midX, y: core.maxY)).y
        let coreBottom = sceneFirst.camera.screenPoint(for: CGPoint(x: core.midX, y: core.minY)).y
        XCTAssertGreaterThan(coreTop, 150, "clear of the top chrome")
        XCTAssertLessThan(coreBottom, 844 - 120, "clear of the app bar")

        let layoutFirst = valleyModel()
        layOut(layoutFirst, phone)
        XCTAssertFalse(layoutFirst.hasFramed, "no scene yet")
        layoutFirst.setScene(emptyValleyScene())
        XCTAssertEqual(layoutFirst.camera, sceneFirst.camera, "framing does not depend on arrival order")

        // A pan, a rotation and a re-delivered scene never snap the camera back.
        var panned = sceneFirst.camera
        panned.pan(byScreen: CGPoint(x: -120, y: 40))
        sceneFirst.cameraDidChange(panned)
        XCTAssertEqual(sceneFirst.camera, panned)
        layOut(sceneFirst, CGSize(width: 844, height: 390))
        XCTAssertEqual(sceneFirst.camera.center, panned.center)
        XCTAssertEqual(sceneFirst.camera.scale, panned.scale)
        sceneFirst.setScene(emptyValleyScene())
        XCTAssertEqual(sceneFirst.camera.center, panned.center)

        let pad = valleyModel()
        pad.setScene(emptyValleyScene())
        layOut(pad, CGSize(width: 1024, height: 1366))
        XCTAssertLessThanOrEqual(pad.camera.scale, 0.14 + 1e-9, "a tablet shows more context instead of zooming into the core")
        XCTAssertTrue(pad.camera.visibleRect().contains(core))
    }

    func testEveryArrivalOrderOfSceneLayoutContentAndDeepLinkEndsOnTheLinkedPlace() throws {
        let content = try BundleContent.load()
        let place = try XCTUnwrap(content.place("ahwahnee-hotel"))
        let expected = LocalProjection(origin: YosemiteGeo.valleyCenter).project(place.coordinate)
        enum Event: CaseIterable { case scene, layout, content, link }
        func permutations(_ items: [Event]) -> [[Event]] {
            guard items.count > 1 else { return [items] }
            return items.flatMap { item in permutations(items.filter { $0 != item }).map { [item] + $0 } }
        }
        for order in permutations(Event.allCases) {
            let model = valleyModel()
            for event in order {
                switch event {
                case .scene: model.setScene(emptyValleyScene())
                case .layout: layOut(model, CGSize(width: 390, height: 844))
                case .content: model.configure(content: content, saved: SavedState(), elementScale: 1, dark: false)
                case .link: model.focus(on: .place("ahwahnee-hotel"))
                }
            }
            XCTAssertTrue(model.hasFramed, "\(order)")
            XCTAssertEqual(model.camera.center.x, expected.x, accuracy: 0.5, "\(order)")
            XCTAssertEqual(model.camera.center.y, expected.y, accuracy: 0.5, "\(order)")
            XCTAssertEqual(model.camera.scale, 1.2, accuracy: 1e-9, "\(order)")
            XCTAssertEqual(model.selection, .place("ahwahnee-hotel"), "\(order)")
            XCTAssertTrue(model.activeCategories.isSuperset(of: place.categories), "a deep-linked place is never hidden by the filters \(order)")
        }
        // Without a link, every order of the other three frames the core identically.
        var cameras: [MapCamera] = []
        for order in permutations([.scene, .layout, .content]) {
            let model = valleyModel()
            for event in order {
                switch event {
                case .scene: model.setScene(emptyValleyScene())
                case .layout: layOut(model, CGSize(width: 390, height: 844))
                case .content: model.configure(content: content, saved: SavedState(), elementScale: 1, dark: false)
                case .link: break
                }
            }
            cameras.append(model.camera)
        }
        XCTAssertEqual(Set(cameras.map { "\($0.center) \($0.scale)" }).count, 1)
    }

    func testFitParkAndFitValleyKeepTheirAreasBetweenTheChromeAndTheFloorAllowsBoth() throws {
        let model = valleyModel()
        XCTAssertEqual(model.scaleLimits.lowerBound, 0.002, "before layout the generic floor applies")
        let projection = LocalProjection(origin: YosemiteGeo.valleyCenter)
        model.setScene(MapScene(projection: projection, extent: projection.projectedRect(YosemiteGeo.parkBounds), roads: [], trails: [], waterLines: [], waterAreas: [],
                                buildings: [], parking: [], pois: [], boundary: [], fireScars: [], contours: [], sources: []))
        let outer = projection.projectedRect(try TerrainGrid.load(file: TerrainGrid.outerFile).bounds)
        for (size, insets) in [(CGSize(width: 390, height: 844), UIEdgeInsets(top: 150, left: 0, bottom: 120, right: 64)),
                               (CGSize(width: 844, height: 390), UIEdgeInsets(top: 100, left: 0, bottom: 100, right: 64)),
                               (CGSize(width: 1366, height: 1024), UIEdgeInsets(top: 120, left: 0, bottom: 110, right: 64))] {
            model.obscuredInsets = insets
            layOut(model, size)
            for (fit, area) in [(model.fitParkCamera(viewSize: size), model.scene!.extent), (model.fitValleyCamera(viewSize: size), projection.projectedRect(YosemiteGeo.valleyBounds))] {
                XCTAssertGreaterThanOrEqual(fit.scale, model.scaleLimits.lowerBound - 1e-12, "\(size): the floor never forces a fit to crop")
                let topLeft = fit.screenPoint(for: CGPoint(x: area.minX, y: area.maxY))
                let bottomRight = fit.screenPoint(for: CGPoint(x: area.maxX, y: area.minY))
                XCTAssertGreaterThanOrEqual(topLeft.x, insets.left - 1e-6, "\(size)")
                XCTAssertGreaterThanOrEqual(topLeft.y, insets.top - 1e-6, "\(size)")
                XCTAssertLessThanOrEqual(bottomRight.x, size.width - insets.right + 1e-6, "\(size)")
                XCTAssertLessThanOrEqual(bottomRight.y, size.height - insets.bottom + 1e-6, "\(size)")
            }
            // The whole canvas at the floor, centred on the park, still lies on bundled terrain.
            var floored = model.fitParkCamera(viewSize: size)
            floored.scale = model.scaleLimits.lowerBound
            floored.center = CGPoint(x: model.scene!.extent.midX, y: model.scene!.extent.midY)
            XCTAssertTrue(outer.contains(floored.visibleRect()), "\(size): \(floored.visibleRect()) outside \(outer)")
        }
    }

    func testHiddenBaseGeometryNeverInterceptsTaps() throws {
        let projection = LocalProjection(origin: YosemiteGeo.valleyCenter)
        let origin = YosemiteGeo.valleyCenter
        let east = CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude + 0.01)
        let service = try XCTUnwrap(SceneBuilder.lineFeature(id: "svc", coords: [origin, east], projection: projection, name: "Service Road", label: nil, attributes: [:], styleKey: "road-service"))
        // The trail runs a couple of metres north of the road, so distance decides once both are drawn.
        let north = { (c: CLLocationCoordinate2D) in CLLocationCoordinate2D(latitude: c.latitude + 2 / 111_000, longitude: c.longitude) }
        let trail = try XCTUnwrap(SceneBuilder.lineFeature(id: "mist", coords: [north(origin), north(east)], projection: projection, name: "Mist Trail", label: nil, attributes: [:], styleKey: "trail"))
        let ring = [origin, CLLocationCoordinate2D(latitude: origin.latitude + 0.002, longitude: origin.longitude - 0.01),
                    CLLocationCoordinate2D(latitude: origin.latitude - 0.002, longitude: origin.longitude - 0.01)]
        let building = try XCTUnwrap(SceneBuilder.areaFeature(id: "bldg", rings: [ring], projection: projection, name: "Lodge", label: nil, attributes: [:], styleKey: "building"))
        let scene = MapScene(projection: projection, extent: projection.projectedRect(YosemiteGeo.valleyBounds), roads: [service], trails: [trail], waterLines: [], waterAreas: [],
                             buildings: [building], parking: [], pois: [], boundary: [], fireScars: [], contours: [], sources: [])
        let onLine = projection.project(CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude + 0.005))
        let inBuilding = projection.project(CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude - 0.006))
        func hit(_ p: CGPoint, scale: CGFloat, options: MapFrameOptions = MapFrameOptions(dark: false)) -> MapHit {
            let camera = MapCamera(center: p, scale: scale, viewSize: CGSize(width: 390, height: 844))
            return MapHitTester.hit(at: camera.screenPoint(for: p), scene: scene, camera: camera, content: MapFrameContent(), options: options)
        }
        // Below 0.07 the service road is not drawn, so the named trail beside it is what a tap on the road reaches.
        XCTAssertEqual(hit(onLine, scale: 0.05), .trail(id: "mist"))
        XCTAssertEqual(hit(onLine, scale: 0.2), .road(id: "svc"), "once drawn, the exact road wins over the trail 2 m away by real distance")
        XCTAssertEqual(hit(onLine, scale: 0.02), .none, "with both hidden, the tap is blank")
        XCTAssertEqual(hit(inBuilding, scale: 0.5), .building(id: "bldg"))
        var footprintsOff = MapFrameOptions(dark: false)
        footprintsOff.showBuildings = false
        XCTAssertEqual(hit(inBuilding, scale: 0.5, options: footprintsOff), .none, "hidden footprints are not tappable")
        XCTAssertEqual(hit(inBuilding, scale: 0.05), .none, "below the footprint zoom either")
    }

    func testFittingWithInsetsCentresTheTargetInTheUncoveredArea() {
        let rect = CGRect(x: -500, y: -300, width: 1000, height: 600)
        let insets = UIEdgeInsets(top: 200, left: 0, bottom: 100, right: 60)
        let camera = MapCamera.fitting(rect, in: CGSize(width: 390, height: 844), insets: insets, padding: 0)
        let centre = camera.screenPoint(for: CGPoint(x: rect.midX, y: rect.midY))
        XCTAssertEqual(centre.x, (0 + 390 - 60) / 2, accuracy: 1e-6)
        XCTAssertEqual(centre.y, (200 + 844 - 100) / 2, accuracy: 1e-6)
        XCTAssertEqual(camera.scale, (390 - 60) / 1000, accuracy: 1e-9, "limited by the uncovered width")
    }

    // MARK: Markers and labels

    func testMarkerLayoutIsDeterministicAndHitTestingUsesTheSameFootprints() throws {
        let camera = MapCamera(center: .zero, scale: 0.1, viewSize: CGSize(width: 390, height: 844))
        var markers: [MapMarker] = []
        for n in 1...4 {
            markers.append(MapMarker(id: "stop-\(n)", point: CGPoint(x: Double(n) * 10, y: 0), title: "Stop \(n)", glyph: "\(n)", colorHex: "#2d6c4f", priority: 5, shape: .stop))
        }
        markers.append(MapMarker(id: "food-a", point: CGPoint(x: 400, y: 400), title: "Food A", colorHex: "#a44c2a", priority: 6))
        markers.append(MapMarker(id: "food-b", point: CGPoint(x: 460, y: 400), title: "Food B", colorHex: "#a44c2a", priority: 3))
        markers.append(MapMarker(id: "toilet", point: CGPoint(x: 430, y: 400), title: "Toilet", colorHex: "#4f5b66", priority: 2, shape: .badge))
        markers.append(MapMarker(id: "car", point: CGPoint(x: 20, y: 0), title: "My car", symbol: "car.fill", colorHex: "#F5921A", priority: 60, shape: .car, clusterable: false))
        markers.append(MapMarker(id: "lone", point: CGPoint(x: -1200, y: -2000), title: "Lone place", colorHex: "#36736d", priority: 4))

        let layout = MarkerLayout.compute(markers, camera: camera, elementScale: 1, selectedId: nil)
        let reordered = MarkerLayout.compute(markers.reversed(), camera: camera, elementScale: 1, selectedId: nil)
        XCTAssertEqual(layout.map(\.id), reordered.map(\.id), "input order never changes the layout")
        XCTAssertEqual(layout.map { $0.members.map(\.id) }, reordered.map { $0.members.map(\.id) })
        XCTAssertEqual(layout.map(\.anchor), reordered.map(\.anchor))

        let stops = try XCTUnwrap(layout.first { $0.id == "cluster-stop-1" })
        XCTAssertEqual(stops.members.map(\.id), ["stop-1", "stop-2", "stop-3", "stop-4"], "stops merge among themselves, highest priority then id first")
        XCTAssertEqual(stops.anchor, camera.screenPoint(for: CGPoint(x: 10, y: 0)), "a cluster stays on its leading member instead of drifting to a centroid")
        let places = try XCTUnwrap(layout.first { $0.id == "cluster-food-a" })
        XCTAssertEqual(places.members.map(\.id), ["food-a", "food-b", "toilet"], "places and facilities merge together by priority, but never with stops at wide zoom")
        XCTAssertNotNil(layout.first { $0.id == "car" }, "a non-clusterable marker stays alone even on top of a cluster")
        XCTAssertEqual(layout.first { $0.id == "lone" }?.count, 1)

        let content = MapFrameContent(markers: markers)
        for item in layout {
            let overlapped = layout.contains { $0.id != item.id && $0.frame.insetBy(dx: -6, dy: -6).intersects(item.frame) }
            guard !overlapped else { continue }
            let hit = MapHitTester.hit(at: item.center, scene: nil, camera: camera, content: content, options: MapFrameOptions(dark: false))
            if item.isCluster {
                XCTAssertEqual(hit, .cluster(ids: item.members.map(\.id), screenPoint: item.anchor), item.id)
            } else {
                XCTAssertEqual(hit, .marker(id: item.representative.id), item.id)
            }
            let farAway = CGPoint(x: item.frame.maxX + 40, y: item.frame.maxY + 40)
            XCTAssertNotEqual(MapHitTester.hit(at: farAway, scene: nil, camera: camera, content: content, options: MapFrameOptions(dark: false)), hit, "footprints are bounded")
        }

        // Zoomed in, the stops 10 m apart separate and keep their numbers.
        let close = MapCamera(center: CGPoint(x: 25, y: 0), scale: 3, viewSize: camera.viewSize)
        let closeLayout = MarkerLayout.compute(markers, camera: close, elementScale: 1, selectedId: nil)
        XCTAssertEqual(closeLayout.filter { $0.representative.shape == .stop && !$0.isCluster }.count, 4)
    }

    func testCoincidentMarkersStayGroupedAndReachableAtAnyZoom() throws {
        // A shuttle stop and a toilet at exactly the same coordinate, plus a place 6 m away.
        let markers = [MapMarker(id: "stop-1", point: .zero, title: "Stop 1", glyph: "1", colorHex: "#2d6c4f", priority: 5, shape: .stop),
                       MapMarker(id: "toilet", point: .zero, title: "Toilet", colorHex: "#4f5b66", priority: 2, shape: .badge),
                       MapMarker(id: "store", point: CGPoint(x: 6, y: 0), title: "Store", colorHex: "#75518a", priority: 4)]
        for scale: CGFloat in [0.5, 1.5, 6] {
            let camera = MapCamera(center: .zero, scale: scale, viewSize: CGSize(width: 390, height: 844))
            let layout = MarkerLayout.compute(markers, camera: camera, elementScale: 1, selectedId: nil)
            let group = try XCTUnwrap(layout.first { $0.isCluster }, "scale \(scale)")
            XCTAssertTrue(group.members.map(\.id).contains("toilet"), "the hidden coincident member is reachable through the group at scale \(scale)")
            XCTAssertEqual(group.anchor, camera.screenPoint(for: .zero), "the group sits on its leading member's exact anchor")
            let hit = MapHitTester.hit(at: group.center, scene: nil, camera: camera, content: MapFrameContent(markers: markers), options: MapFrameOptions(dark: false))
            XCTAssertEqual(hit, .cluster(ids: group.members.map(\.id), screenPoint: group.anchor))
            if scale >= 6 {
                XCTAssertFalse(group.members.map(\.id).contains("store"), "6 m is 36 points here, so the store stands alone")
            }
        }
    }

    func testSelectedMarkerStaysVisibleSeparateAndOnTopRegardlessOfZoomRules() {
        let camera = MapCamera(center: .zero, scale: 0.03, viewSize: CGSize(width: 390, height: 844))
        let markers = [MapMarker(id: "big", point: .zero, title: "Big", colorHex: "#000000", priority: 10),
                       MapMarker(id: "small", point: CGPoint(x: 30, y: 0), title: "Small", colorHex: "#000000", priority: 1, minScale: 0.08),
                       MapMarker(id: "saved", point: CGPoint(x: 60, y: 0), title: "Saved", colorHex: "#F5921A", priority: 21)]
        let plain = MarkerLayout.compute(markers, camera: camera, elementScale: 1, selectedId: nil)
        XCTAssertNil(plain.flatMap(\.members).first { $0.id == "small" }, "below its minScale the small pin is hidden")
        XCTAssertEqual(plain.first?.representative.id, "saved", "the saved place leads the cluster")

        let selected = MarkerLayout.compute(markers, camera: camera, elementScale: 1, selectedId: "small")
        let item = selected.first { $0.members.contains { $0.id == "small" } }
        XCTAssertEqual(item?.id, "small", "the selected marker never merges into a cluster")
        XCTAssertEqual(item?.anchor, camera.screenPoint(for: CGPoint(x: 30, y: 0)))
        XCTAssertEqual(selected.last?.id, "small", "the selection draws last so it sits on top")
        XCTAssertGreaterThan(item!.radius, MarkerLayout.baseRadius(.pin) * MarkerLayout.symbolScale(0.03))
        let other = selected.first { $0.id != "small" }
        XCTAssertEqual(other?.members.map(\.id), ["saved", "big"], "the remaining markers still cluster by priority")
        let hit = MapHitTester.hit(at: item!.center, scene: nil, camera: camera, content: MapFrameContent(markers: markers, selectedMarkerId: "small"), options: MapFrameOptions(dark: false))
        XCTAssertEqual(hit, .marker(id: "small"))
    }

    func testLabelPlacerHonoursPriorityReservedFootprintsAndBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        let marker = CGRect(x: 140, y: 140, width: 20, height: 20)
        let important = LabelCandidate(id: "a", text: "El Capitan", kind: .landform, point: CGPoint(x: 100, y: 100), size: CGSize(width: 80, height: 14), priority: 10)
        let rival = LabelCandidate(id: "b", text: "Overlaps A", kind: .road, point: CGPoint(x: 110, y: 104), size: CGSize(width: 80, height: 14), priority: 2)
        let underMarker = LabelCandidate(id: "c", text: "Under pin", kind: .place, point: CGPoint(x: 150, y: 150), size: CGSize(width: 40, height: 12), priority: 50,
                                         offsets: [.zero, CGPoint(x: 40, y: 0)])
        let offscreen = LabelCandidate(id: "d", text: "Edge", kind: .road, point: CGPoint(x: 295, y: 20), size: CGSize(width: 60, height: 12), priority: 99)
        let placed = LabelPlacer.place([rival, important, underMarker, offscreen], reserved: [marker], bounds: bounds)
        XCTAssertEqual(placed.map(\.candidate.id), ["c", "a"], "priority order; the overlapping rival and the off-screen label are dropped")
        XCTAssertEqual(placed.first { $0.candidate.id == "c" }?.center, CGPoint(x: 190, y: 150), "falls back to the next offset clear of the marker footprint")
        XCTAssertFalse(placed.contains { $0.footprint.intersects(marker) })

        let rotated = LabelCandidate(id: "r", text: "Northside Drive", kind: .road, point: .zero, size: CGSize(width: 80, height: 14), priority: 1, angle: .pi / 2)
        let footprint = rotated.footprint(centredAt: .zero)
        XCTAssertEqual(footprint.width, 14, accuracy: 1e-6)
        XCTAssertEqual(footprint.height, 80, accuracy: 1e-6)
    }

    func testLineLabelAnchorSitsAtTheArcLengthMidpointAndReadsLeftToRight() throws {
        let camera = MapCamera(center: .zero, scale: 1, viewSize: CGSize(width: 400, height: 400))
        // A line digitized from east to west still yields an angle in (-90°, 90°].
        let westward = [CGPoint(x: 200, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: -50, y: -50)]
        let anchor = try XCTUnwrap(MapRenderer.lineLabelAnchor(westward, camera: camera))
        XCTAssertEqual(anchor.angle, 0, accuracy: 1e-6, "the midpoint of the 270.7 m line lies on the first, horizontal segment")
        XCTAssertEqual(anchor.point.x, 200 + (200 - 270.71 / 2), accuracy: 0.1)
        XCTAssertEqual(anchor.point.y, 200, accuracy: 1e-6)
        let diagonal = [CGPoint(x: 0, y: 0), CGPoint(x: -100, y: -100)]
        let d = try XCTUnwrap(MapRenderer.lineLabelAnchor(diagonal, camera: camera))
        XCTAssertGreaterThan(d.angle, -.pi / 2)
        XCTAssertLessThanOrEqual(d.angle, .pi / 2)
    }
}
