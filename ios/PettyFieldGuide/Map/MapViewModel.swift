import SwiftUI
import Combine
import CoreLocation

/// What the map is currently showing on top of the base geometry.
struct MapLayerToggles: Codable, Equatable {
    var shuttleRoutes = true
    var emphasizeShuttle = false
    var contours = false
    var smoke = false
    var buildings = true
    var buildingLabels: BuildingLabelMode = .callouts
}

enum MapSelection: Equatable {
    case place(String)
    case campsite(ridbId: String)
    case building(id: String)
    case parking(id: String)
    case trail(id: String)
    case hike(routeId: String)
    case road(id: String)
    case car
    case campsitePin
    case cluster(ids: [String])
    case overlay(id: String)
}

/// Main-actor state for a map screen: the Map tab's continuous park map, or a secondary map. The scene itself is immutable and shared.
@MainActor
final class MapViewModel: ObservableObject {
    @Published var camera: MapCamera
    @Published var scene: MapScene?
    @Published var frameOptions: MapFrameOptions
    @Published var frameContent = MapFrameContent()
    @Published var zoomLocked = false
    @Published var layers: MapLayerToggles { didSet { rebuildOptions(); rebuildContent(); persistLayers() } }
    @Published var activeCategories: Set<String> { didSet { rebuildContent(); persistCategories() } }
    @Published var selection: MapSelection? {
        didSet {
            // The hike overlay lives only while its card is up; any other selection or a dismissal clears it.
            if case .hike = selection {} else if activeRouteId != nil { activeRouteId = nil }
            rebuildContent()
        }
    }
    /// The hike route drawn above the base trails, with its start, destination and waypoint markers.
    @Published private(set) var activeRouteId: String? {
        didSet {
            if activeRouteId != oldValue {
                inspectedMetres = nil
                if let activeRouteId, let route = content?.hikeRoute(activeRouteId), let trace = scene?.hikeRoutes[activeRouteId] {
                    activeLandmarks = HikeLandmark.landmarks(for: route, trace: trace)
                } else {
                    activeLandmarks = []
                }
            }
            if activeRouteId == nil {
                routeFitCamera = nil; routeViewport = nil; refitRouteOnInsetChange = false
                if !focusesHike { focusesHike = true }
            }
            rebuildOptions()
            rebuildContent()
        }
    }
    /// Presentation only: never written to the persisted category/layer choices; resets when the hike clears.
    @Published var focusesHike = true { didSet { if focusesHike != oldValue { rebuildContent() } } }
    @Published private(set) var inspectedMetres: Double?
    private(set) var activeLandmarks: [HikeLandmark] = []
    @Published var sunPreview: SunPreviewState? { didSet { rebuildContent() } }
    /// Live GPS position; the Map tab rebuilds around it, secondary maps patch it into their own frame.
    @Published var userFix: MapUserFix? {
        didSet {
            guard userFix != oldValue else { return }
            if content != nil { rebuildContent() } else { frameContent = withUser(frameContent) }
        }
    }
    /// Re-centres on each new fix until the person moves the map or another focus takes over.
    @Published var followsUser = false
    @Published var smokePolygons: [MapOverlayArea] = [] { didSet { rebuildContent() } }
    /// A point a link or search asked to show that has no marker of its own.
    @Published private(set) var shownPin: ShownPin?
    @Published var statusMessage: String?
    /// Canvas points covered by chrome; framing and labels keep clear of them.
    @Published var obscuredInsets: UIEdgeInsets = .zero {
        didSet {
            guard obscuredInsets != oldValue else { return }
            // Patched rather than rebuilt: secondary maps set their own options, which a rebuild would replace with the Valley's.
            frameOptions.obscuredInsets = obscuredInsets
            // The hike card raises the bottom inset after the route was framed; refit once so the whole route stays clear of it.
            if refitRouteOnInsetChange { fitActiveRoute(animated: false) }
            if areaFit?.camera != nil { applyAreaFit(animated: false) }
        }
    }

    /// Camera the last route fit produced; the fit follows layout changes until the user moves the map.
    private var routeFitCamera: MapCamera?
    /// Projected area the route fit showed; the pan clamp keeps covering it while the route is up.
    private var routeViewport: CGRect?
    private var refitRouteOnInsetChange = false
    /// Area the last `fit(_:)` asked for, and the camera it produced; nil camera means it waits for the first layout.
    /// Layout and inset changes refit it until the camera is moved some other way.
    private var areaFit: (rect: CGRect, maxScale: CGFloat, camera: MapCamera?)?

    var cameraFromCanvas = false
    private weak var canvas: MapCanvas?
    private var content: Content?
    private var saved: SavedState?
    private var elementScale: CGFloat = 1
    private var dark = false
    private var shuttleRoutes: [MapOverlayLine] = []
    private var projection = LocalProjection(origin: YosemiteGeo.valleyCenter)
    private let preferences: UserDefaults?
    private var importObserver: AnyCancellable?

    private let framesValleyCoreOnFirstLayout: Bool
    /// Set by the canvas's first real layout; the nominal camera size before that never counts as laid out.
    private(set) var hasLaidOut = false
    private(set) var hasFramed = false
    private var pendingFocus: MapFocus?

    static let defaultCategories: Set<String> = ["parking", "shuttle", "information", "food", "lodging", "outdoors", "waterfalls", "services", "shopping"]
    static let layersKey = "map.layers"
    static let categoriesKey = "map.categories"

    /// The Map tab restores and persists its layer and category choices and frames the Valley visitor core
    /// on first layout; secondary maps start from defaults, leave preferences alone and set their own cameras.
    init(restoresPreferences: Bool = false, defaults: UserDefaults = .standard) {
        let projection = LocalProjection(origin: YosemiteGeo.valleyCenter)
        let extent = projection.projectedRect(YosemiteGeo.valleyBounds)
        camera = MapCamera.fitting(extent, in: CGSize(width: 390, height: 600))
        frameOptions = MapFrameOptions(dark: false)
        preferences = restoresPreferences ? defaults : nil
        framesValleyCoreOnFirstLayout = restoresPreferences
        layers = Self.storedLayers(in: preferences) ?? MapLayerToggles()
        activeCategories = Self.storedCategories(in: preferences) ?? Self.defaultCategories
        rebuildOptions()
        if restoresPreferences {
            importObserver = NotificationCenter.default.publisher(for: .mapPreferencesImported).sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.reloadPreferences() }
            }
        }
    }

    private static func storedLayers(in defaults: UserDefaults?) -> MapLayerToggles? {
        guard let data = defaults?.data(forKey: layersKey) else { return nil }
        return try? JSONDecoder().decode(MapLayerToggles.self, from: data)
    }

    private static func storedCategories(in defaults: UserDefaults?) -> Set<String>? {
        (defaults?.array(forKey: categoriesKey) as? [String]).map(Set.init)
    }

    /// Applies layer/category preferences a backup import just wrote, so a map already on screen follows.
    func reloadPreferences() {
        if let stored = Self.storedLayers(in: preferences) { layers = stored }
        if let stored = Self.storedCategories(in: preferences) { activeCategories = stored }
    }

    func attach(_ canvas: MapCanvas) { self.canvas = canvas }

    func configure(content: Content, saved: SavedState, elementScale: CGFloat, dark: Bool) {
        self.content = content
        self.saved = saved
        self.elementScale = elementScale
        self.dark = dark
        shuttleRoutes = content.transit.feeds.flatMap { feed in
            feed.routes.compactMap { route -> MapOverlayLine? in
                guard route.appRoute != nil else { return nil }
                let points = route.shape.map { projection.project(CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1])) }
                return MapOverlayLine(id: "route-\(route.id)", points: points, colorHex: route.color, width: route.appRoute == "valleywide" ? 2.6 : 2.2,
                                      dashed: route.appRoute != "valleywide", directional: true)
            }
        }
        rebuildOptions()
        rebuildContent()
        resolvePendingFocus()
    }

    func setScene(_ scene: MapScene) {
        self.scene = scene
        projection = scene.projection
        if userFix != nil { frameContent = withUser(frameContent) }
        if !framesValleyCoreOnFirstLayout, camera.viewSize == .zero {
            camera = MapCamera.fitting(scene.extent, in: CGSize(width: 390, height: 600))
        }
        applyFirstFramingIfNeeded()
        resolvePendingFocus()
    }

    /// The zoom floor is a little past a whole-view fit of the scene's extent, and never above what
    /// "Fit the whole park" needs between the chrome. It is raised only where that would show ground past the
    /// outermost relief tier, which is sized so this never happens on supported phone and iPad layouts.
    var scaleLimits: ClosedRange<CGFloat> {
        guard framesValleyCoreOnFirstLayout, let scene, hasLaidOut else { return 0.002...6 }
        let whole = min(camera.viewSize.width / scene.extent.width, camera.viewSize.height / scene.extent.height)
        let floor = max(0.001, min(whole * 0.8, fitParkCamera(viewSize: camera.viewSize).scale), terrainFloor(viewSize: camera.viewSize))
        return floor...6
    }

    /// The smallest scale at which the view stays on unfaded outermost relief. A view wider than the pan clamp is
    /// centred on it, and a narrower one stays inside it, so the clamp's centre and the relief edge bound every view.
    func terrainFloor(viewSize: CGSize) -> CGFloat {
        guard let scene, let clamp = clampRect, let outer = scene.relief?.layers.first else { return 0 }
        let fade = CGFloat(outer.feather)
        let solid = outer.footprint.insetBy(dx: fade * outer.footprint.width / CGFloat(outer.width), dy: fade * outer.footprint.height / CGFloat(outer.height))
        let halfWidth = min(clamp.midX - solid.minX, solid.maxX - clamp.midX), halfHeight = min(clamp.midY - solid.minY, solid.maxY - clamp.midY)
        guard halfWidth > 0, halfHeight > 0 else { return 0 }
        return max(viewSize.width / (2 * halfWidth), viewSize.height / (2 * halfHeight))
    }

    /// The Valley's detailed extent inside the chrome insets plus padding.
    func fitValleyCamera(viewSize: CGSize) -> MapCamera {
        MapCamera.fitting(projection.projectedRect(YosemiteGeo.valleyBounds), in: viewSize, insets: obscuredInsets, padding: 8)
    }

    /// The park boundary (the scene extent when a scene has none) inside the chrome insets plus padding.
    func fitParkCamera(viewSize: CGSize) -> MapCamera {
        MapCamera.fitting(parkRect, in: viewSize, insets: obscuredInsets, padding: 8)
    }

    private var parkRect: CGRect {
        guard let scene else { return camera.visibleRect() }
        let boundary = scene.boundary.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
        return boundary.isNull ? scene.extent : boundary
    }

    /// Pan limits: the scene extent, widened to hold a selected hike that leaves it and the whole viewport
    /// its fit showed, so the framed route is never pushed off or cut by the clamp.
    var clampRect: CGRect? {
        guard let scene else { return nil }
        var rect = scene.extent
        if let activeRouteId, let route = scene.hikeRoutes[activeRouteId] { rect = rect.union(route.bounds) }
        rect = rect.insetBy(dx: -2000, dy: -2000)
        if let routeViewport { rect = rect.union(routeViewport) }
        return rect
    }

    // MARK: Camera

    func cameraDidChange(_ camera: MapCamera) {
        cameraFromCanvas = true
        let resized = camera.viewSize != self.camera.viewSize
        self.camera = camera
        if camera.viewSize.width > 0, camera.viewSize.height > 0 { hasLaidOut = true }
        applyFirstFramingIfNeeded()
        if let fit = areaFit {
            if fit.camera == nil || resized { applyAreaFit(animated: false) } else if camera != fit.camera { areaFit = nil }
        }
        if let fit = routeFitCamera {
            if resized {
                fitActiveRoute(animated: false)
            } else if camera.center != fit.center || camera.scale != fit.scale {
                routeFitCamera = nil
                refitRouteOnInsetChange = false
            }
        }
    }

    private func applyFirstFramingIfNeeded() {
        guard framesValleyCoreOnFirstLayout, !hasFramed, scene != nil, hasLaidOut else { return }
        hasFramed = true
        if pendingFocus != nil, content != nil {
            resolvePendingFocus()
            return
        }
        apply(camera: initialCamera(viewSize: camera.viewSize))
    }

    func initialCamera(viewSize: CGSize) -> MapCamera {
        MapCamera.fitting(projection.projectedRect(YosemiteGeo.valleyCore), in: viewSize, insets: obscuredInsets, padding: 12, maxScale: 0.14)
    }

    private func apply(camera target: MapCamera) {
        canvas?.stopAnimation()
        canvas?.camera = target
        cameraFromCanvas = false
        camera = target
    }

    private func resolvePendingFocus() {
        guard hasFramed || !framesValleyCoreOnFirstLayout, content != nil, let focus = pendingFocus else { return }
        pendingFocus = nil
        self.focus(on: focus, animated: false)
    }

    func fitValley() {
        guard scene != nil, let canvas else { return }
        followsUser = false
        areaFit = nil
        canvas.animate(to: fitValleyCamera(viewSize: canvas.bounds.size))
    }

    func fitPark() {
        guard scene != nil else { return }
        fit(parkRect)
    }

    /// Frames `rect` inside the unobscured part of the view.
    func fit(_ rect: CGRect, maxScale: CGFloat = .infinity, animated: Bool = true) {
        followsUser = false
        areaFit = (rect, maxScale, nil)
        applyAreaFit(animated: animated)
    }

    private func applyAreaFit(animated: Bool) {
        guard let fit = areaFit, let canvas, canvas.bounds.width > 0, canvas.bounds.height > 0 else { return }
        let target = MapCamera.fitting(fit.rect, in: canvas.bounds.size, insets: obscuredInsets, padding: 12, maxScale: fit.maxScale)
        areaFit?.camera = target
        if animated { canvas.animate(to: target) } else { apply(camera: target) }
    }

    func zoomIn() { canvas?.animateZoom(by: 1.8) }
    func zoomOut() { canvas?.animateZoom(by: 1 / 1.8) }

    func focus(on coordinate: CLLocationCoordinate2D, scale: CGFloat? = nil, animated: Bool = true) {
        followsUser = false
        areaFit = nil
        guard let canvas else {
            camera.center = projection.project(coordinate)
            if let scale { camera.scale = scale }
            hasFramed = true
            return
        }
        var target = camera
        target.viewSize = canvas.bounds.size
        target.center = projection.project(coordinate)
        if let scale { target.scale = scale }
        if animated { canvas.animate(to: target) } else { apply(camera: target) }
    }

    func focus(on focus: MapFocus, animated: Bool = true) {
        guard let content, hasFramed || !framesValleyCoreOnFirstLayout else {
            pendingFocus = focus
            return
        }
        switch focus {
        case .place(let id):
            // A hike's place record is its trailhead pin; the map shows the whole default route instead.
            if let route = content.defaultHikeRoute(for: id) {
                selectHike(route.id, animated: animated, pending: focus)
                return
            }
            guard let place = content.place(id) else { return }
            if !activeCategories.isSuperset(of: place.categories) { activeCategories.formUnion(place.categories) }
            selection = .place(id)
            self.focus(on: place.coordinate, scale: max(camera.scale, 1.2), animated: animated)
        case .site(_, let ridb):
            guard let site = content.campsites.first(where: { $0.ridbId == ridb }) else { return }
            selection = .campsite(ridbId: ridb)
            self.focus(on: site.coordinate, scale: max(camera.scale, 2.5), animated: animated)
        case .coordinate(let lat, let lon, let label):
            if let car = saved?.car, car.latitude == lat, car.longitude == lon {
                selection = .car
            } else {
                shownPin = ShownPin(title: label, latitude: lat, longitude: lon)
                selection = .place(ShownPin.markerId)
            }
            self.focus(on: CLLocationCoordinate2D(latitude: lat, longitude: lon), scale: max(camera.scale, 1.0), animated: animated)
        case .trail(let id):
            if let route = content.defaultHikeRoute(for: id) {
                selectHike(route.id, animated: animated, pending: focus)
            } else if let trail = content.trail(id), !trail.isValley {
                // No reviewed trace: the trailhead is picked and nothing is drawn.
                selection = .place(ParkMapView.trailheadMarkerId(trail))
                self.focus(on: trail.coordinate, scale: max(camera.scale, 0.12), animated: animated)
            }
        case .hikeRoute(let id):
            selectHike(id, animated: animated, pending: focus)
        case .region(let id):
            guard let scene, let rect = ParkMapView.regionRect(id, scene: scene, content: content) else { return }
            selection = nil
            fit(rect, animated: animated)
        case .park:
            selection = nil
            fit(parkRect, animated: animated)
        }
    }

    func clearShownPin() {
        shownPin = nil
        if selection == .place(ShownPin.markerId) { selection = nil }
        rebuildContent()
    }

    // MARK: Hike routes

    /// Draws the route, opens its card and frames the whole trace between the chrome. Until the scene
    /// exists the request waits, so a link that arrives before the geometry still lands on the route.
    func selectHike(_ routeId: String, animated: Bool = true, pending: MapFocus? = nil) {
        guard let content, content.hikeRoute(routeId) != nil else { return }
        guard let scene else {
            pendingFocus = pending ?? .hikeRoute(routeId)
            return
        }
        // A scene without the trace means the route could not be resolved; nothing to draw or wait for.
        guard scene.hikeRoutes[routeId] != nil else { return }
        followsUser = false
        selection = .hike(routeId: routeId)
        activeRouteId = routeId
        refitRouteOnInsetChange = true
        fitActiveRoute(animated: animated)
    }

    func clearHike() {
        selection = nil
    }

    /// The camera that shows the whole active route inside the unobscured part of the view.
    func routeFitCamera(viewSize: CGSize) -> MapCamera? {
        guard let scene, let activeRouteId, let route = scene.hikeRoutes[activeRouteId] else { return nil }
        let bounds = route.bounds.insetBy(dx: -max(60, route.bounds.width * 0.06), dy: -max(60, route.bounds.height * 0.06))
        var target = MapCamera.fitting(bounds, in: viewSize, insets: obscuredInsets, padding: 20, maxScale: 1.6)
        target.scale = max(target.scale, scaleLimits.lowerBound)
        return target
    }

    func fitActiveRoute(animated: Bool = true) {
        let size = canvas?.bounds.size ?? camera.viewSize
        guard size.width > 0, size.height > 0, let target = routeFitCamera(viewSize: size) else { return }
        areaFit = nil
        routeFitCamera = target
        routeViewport = target.visibleRect()
        if animated, let canvas { canvas.animate(to: target) } else { apply(camera: target) }
    }

    // MARK: Route inspection

    /// Moves only the cursor; camera and fit-following are untouched so scrubbing never fights a user pan.
    func inspect(metres: Double?) {
        guard let activeRouteId, let route = scene?.hikeRoutes[activeRouteId], let metres else {
            inspectedMetres = nil
            frameContent.routeCursor = nil
            return
        }
        let clamped = min(max(metres, 0), route.chainage.totalMetres)
        inspectedMetres = clamped
        frameContent.routeCursor = route.chainage.point(at: clamped)
    }

    func inspect(landmarkId: String) {
        guard let landmark = activeLandmarks.first(where: { $0.id == landmarkId }) else { return }
        inspect(metres: landmark.metres)
    }

    /// Recentres on the cursor at the current zoom; ends fit-following like any other camera move.
    func centerOnInspection() {
        guard let inspectedMetres, let activeRouteId, let route = scene?.hikeRoutes[activeRouteId], let canvas else { return }
        let size = canvas.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        followsUser = false
        canvas.animate(to: centringCamera(on: route.chainage.point(at: inspectedMetres), in: size))
    }

    /// The camera at `scale` (default: current) that puts `point` in the middle of the unobscured area.
    private func centringCamera(on point: CGPoint, in size: CGSize, scale: CGFloat? = nil) -> MapCamera {
        let usable = CGPoint(x: (obscuredInsets.left + size.width - obscuredInsets.right) / 2, y: (obscuredInsets.top + size.height - obscuredInsets.bottom) / 2)
        var target = camera
        target.viewSize = size
        if let scale { target.scale = scale }
        target.center = CGPoint(x: point.x - (usable.x - size.width / 2) / target.scale, y: point.y + (usable.y - size.height / 2) / target.scale)
        return target
    }

    // MARK: Live position

    /// Whether a position falls inside the area this map can show; outside it the map cannot centre on it.
    func isOnMap(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard let rect = clampRect else { return false }
        return rect.contains(projection.project(coordinate))
    }

    /// Centres on the live position, zooming in to at least `minScale`; a fix off this map leaves the camera alone.
    func centerOnUser(minScale: CGFloat? = nil) {
        guard let fix = userFix?.fix, isOnMap(fix.coordinate), let canvas else { return }
        let size = canvas.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let target = centringCamera(on: projection.project(fix.coordinate), in: size, scale: minScale.map { max(camera.scale, $0) })
        // GPS jitter while standing still should not keep nudging the map.
        guard target.scale != camera.scale || hypot(target.center.x - camera.center.x, target.center.y - camera.center.y) * camera.scale > 3 else { return }
        areaFit = nil
        canvas.animate(to: target, duration: 0.45)
    }

    /// `frame` with this map's live-position marker and accuracy ring replaced by the current fix.
    func withUser(_ frame: MapFrameContent) -> MapFrameContent {
        var frame = frame
        frame.markers.removeAll { $0.id == "user" }
        frame.userAccuracy = nil
        guard let userFix else { return frame }
        let point = projection.project(userFix.fix.coordinate)
        let accuracy = String(format: "%.0f", userFix.fix.horizontalAccuracy)
        frame.markers.append(MapMarker(id: "user", point: point, title: userFix.stale ? "Last GPS fix" : "Your position",
                                       colorHex: userFix.stale ? "#7D8389" : "#3B7EA8", priority: 70, shape: .user, clusterable: false,
                                       accessibilityTitle: userFix.stale ? "Last GPS fix, out of date, accuracy about \(accuracy) metres" : "Your position, accuracy about \(accuracy) metres"))
        frame.userAccuracy = MapAccuracyRing(center: point, radius: userFix.fix.horizontalAccuracy, stale: userFix.stale)
        return frame
    }

    // MARK: Interaction

    struct Tap: Equatable {
        let projected: CGPoint
        let hit: MapHit
        let sequence: Int
    }

    @Published private(set) var lastTap: Tap?

    func handleTap(_ hit: MapHit, at point: CGPoint) {
        lastTap = Tap(projected: camera.projectedPoint(for: point), hit: hit, sequence: (lastTap?.sequence ?? 0) + 1)
        switch hit {
        case .marker(let id):
            if id == "car" { selection = .car }
            else if id == "campsite" { selection = .campsitePin }
            else if id.hasPrefix("site-") { selection = .campsite(ridbId: String(id.dropFirst(5))) }
            else if id == "user" { selection = nil }
            else if id == MapMarker.routeStartId || id == MapMarker.routeDestinationId {
                // The route's own badges belong to the hike that is already up; they never open a place.
                if let activeRouteId { selection = .hike(routeId: activeRouteId) }
            }
            else if id.hasPrefix(MapMarker.routeMilestonePrefix) {
                if let activeRouteId {
                    selection = .hike(routeId: activeRouteId)
                    inspect(landmarkId: String(id.dropFirst(MapMarker.routeMilestonePrefix.count)))
                }
            }
            else if let route = content?.defaultHikeRoute(for: id) { selectHike(route.id) }
            else { selection = .place(id) }
        case .cluster(let ids, _):
            revealCluster(ids)
        case .building(let id): selection = .building(id: id)
        case .parking(let id): selection = .parking(id: id)
        case .trail(let id): selection = .trail(id: id)
        case .route(let id): selection = .hike(routeId: id)
        case .road(let id): selection = .road(id: id)
        case .overlayArea(let id), .overlayLine(let id): selection = .overlay(id: id)
        case .fireScar, .none: selection = nil
        }
    }

    /// Zooms until the members separate; members sharing one spot get the pick list instead.
    private func revealCluster(_ ids: [String]) {
        let members = Set(ids)
        let points = frameContent.markers.filter { members.contains($0.id) }.map(\.point)
        let bounds = GeometryOps.bounds(of: points)
        guard let canvas, !zoomLocked, camera.scale < scaleLimits.upperBound * 0.9, bounds.width + bounds.height > 5 else {
            selection = .cluster(ids: ids)
            return
        }
        followsUser = false
        var target = MapCamera.fitting(bounds.insetBy(dx: -max(30, bounds.width * 0.2), dy: -max(30, bounds.height * 0.2)),
                                       in: canvas.bounds.size, insets: obscuredInsets, padding: 48)
        target.scale = min(scaleLimits.upperBound, max(target.scale, camera.scale * 1.8))
        canvas.animate(to: target)
    }

    /// A long-pressed spot proposed for the parked-car pin; nothing is saved until the panel confirms it.
    struct ProposedSpot: Equatable {
        let latitude: Double
        let longitude: Double
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    }

    @Published var pendingCarPlacement: ProposedSpot?

    func handleLongPress(at point: CGPoint) {
        let c = projection.unproject(camera.projectedPoint(for: point))
        pendingCarPlacement = ProposedSpot(latitude: c.latitude, longitude: c.longitude)
    }

    func coordinate(forScreen point: CGPoint) -> CLLocationCoordinate2D {
        projection.unproject(camera.projectedPoint(for: point))
    }

    /// Geographic point under the crosshair at the centre of the view.
    var centerCoordinate: CLLocationCoordinate2D { projection.unproject(camera.center) }

    func update(saved: SavedState) {
        self.saved = saved
        rebuildContent()
    }

    /// NOAA HMS plume polygons from the saved smoke snapshot, projected for this map.
    func update(smoke snapshot: Snapshot<SmokeFeed>?) {
        guard let snapshot, !snapshot.isExpired, let polygons = snapshot.payload.plumes.polygons else { smokePolygons = []; return }
        smokePolygons = polygons.enumerated().map { index, poly in
            let ring = poly.ring.map { projection.project(CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0])) }
            let holes = (poly.holes ?? []).map { $0.map { projection.project(CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0])) } }
            let alpha: CGFloat = poly.density == "Heavy" ? 0.45 : poly.density == "Medium" ? 0.3 : 0.18
            return MapOverlayArea(id: "plume-\(index)", rings: [ring] + holes, fillHex: "#555555", fillAlpha: alpha, strokeHex: nil,
                                  title: "\(poly.density) smoke · HMS analysis \(snapshot.payload.plumes.analysisDate ?? "")")
        }
    }

    func update(elementScale: CGFloat, dark: Bool) {
        self.elementScale = elementScale
        self.dark = dark
        rebuildOptions()
    }

    // MARK: Frame building

    private func rebuildOptions() {
        var o = MapFrameOptions(dark: dark)
        o.elementScale = elementScale
        o.showBuildings = layers.buildings
        o.buildingLabelMode = layers.buildingLabels
        o.showContours = layers.contours
        o.emphasizeShuttle = layers.emphasizeShuttle
        o.highlightedRouteId = activeRouteId
        o.dimBase = sunPreview != nil
        o.showsScaleBar = !framesValleyCoreOnFirstLayout
        o.obscuredInsets = obscuredInsets
        frameOptions = o
    }

    private static func labelScale(priority: Int, saved: Bool) -> CGFloat {
        if saved || priority >= 9 { return 0.06 }
        if priority >= 7 { return 0.12 }
        if priority >= 4 { return 0.3 }
        return 0.6
    }

    private func rebuildContent() {
        guard let content else { return }
        var frame = MapFrameContent()
        let savedIds = Set(saved?.places.keys ?? [:].keys)
        let selectedPlaceId: String? = if case .place(let id) = selection { id } else { nil }
        let activeRoute = activeRouteId.flatMap { scene?.hikeRoutes[$0] }
        // Focus quiets ordinary places; the hike's anchors, its shuttle stops, saved places and personal pins stay.
        let focused = activeRoute != nil && focusesHike
        let focusStops = Set(activeRoute.flatMap { content.trail($0.trailId)?.shuttleStops } ?? [])
        let focusAnchors = Set(activeRouteId.flatMap { content.hikeRoute($0)?.orderedMilestones.map(\.anchor) } ?? [])

        for place in content.places {
            let isSaved = savedIds.contains(place.id)
            let visibleByCategory = !activeCategories.isDisjoint(with: place.categories)
            guard visibleByCategory || isSaved || place.id == selectedPlaceId else { continue }
            if place.kind == .housekeepingUnit && !(isSaved || place.id == selectedPlaceId) { continue }
            // The selected hike's own place pin sits at its trailhead; the route's start marker replaces it.
            if place.kind == .trail && place.id == activeRoute?.trailId { continue }
            if focused && !isSaved {
                let isTrailStop = place.kind == .shuttleStop && place.stopNumber.map(focusStops.contains) == true
                guard isTrailStop || focusAnchors.contains(place.id) else { continue }
            }
            let category = place.categories.first.flatMap { content.category($0) }
            let color = isSaved ? "#F5921A" : (category?.color ?? "#4F5B66")
            let isStop = place.kind == .shuttleStop
            let glyph: String? = isStop ? place.stopNumber.map(String.init) : place.glyph
            let shape: MapMarker.Shape = isStop ? .stop : (place.kind == .facility || place.kind == .water || place.kind == .ice ? .badge : .pin)
            let title = place.kind == .trail ? "\(place.name) · trailhead" : place.name
            frame.markers.append(MapMarker(id: place.id, point: projection.project(place.coordinate), title: title,
                                           glyph: glyph, symbol: glyph == nil ? category?.symbol : nil, colorHex: color,
                                           priority: place.mapPriority + (isSaved ? 20 : 0), shape: shape,
                                           clusterable: true, minScale: place.mapPriority >= 8 || isSaved ? 0 : 0.08,
                                           labelMinScale: isStop ? 0.5 : Self.labelScale(priority: place.mapPriority, saved: isSaved)))
        }

        if camera.scale >= 1.2 {
            for site in content.campsites {
                let isMine = saved?.campsite?.siteId == site.ridbId
                if focused && !isMine { continue }
                frame.markers.append(MapMarker(id: "site-\(site.ridbId)", point: projection.project(site.coordinate), title: "Site \(site.displayNumber)",
                                               glyph: site.displayNumber, colorHex: isMine ? "#F5921A" : (site.accessible ? "#2d6c4f" : "#545f31"),
                                               priority: isMine ? 50 : 1, shape: .site, clusterable: false, minScale: 1.2))
            }
        }

        // Trailheads, campgrounds and region points beyond the Valley; a picked one stays up whatever the filters or hike focus.
        var parkMarkers = focused ? [] : ParkMapView.markers(mode: .overview, projection: projection, content: content, focusTrailId: nil, categories: activeCategories)
        if let selectedPlaceId, !parkMarkers.contains(where: { $0.id == selectedPlaceId }),
           let picked = ParkMapView.markers(mode: .overview, projection: projection, content: content, focusTrailId: nil, categories: nil).first(where: { $0.id == selectedPlaceId }) {
            parkMarkers.append(picked)
        }
        frame.markers += parkMarkers
        if let shownPin {
            frame.markers.append(MapMarker(id: ShownPin.markerId, point: projection.project(shownPin.coordinate), title: shownPin.title, symbol: "mappin",
                                           colorHex: "#F5921A", priority: 50, shape: .pin, clusterable: false, labelMinScale: 0))
        }
        if let car = saved?.car {
            frame.markers.append(MapMarker(id: "car", point: projection.project(car.coordinate), title: "My car", symbol: "car.fill", colorHex: "#F5921A",
                                           priority: 60, shape: .car, clusterable: false, labelMinScale: 0))
        }
        if let camp = saved?.campsite, let lat = camp.latitude, let lon = camp.longitude {
            frame.markers.append(MapMarker(id: "campsite", point: projection.project(CLLocationCoordinate2D(latitude: lat, longitude: lon)), title: camp.label,
                                           symbol: "tent.fill", colorHex: "#F5921A", priority: 61, shape: .campsite, clusterable: false, labelMinScale: 0))
        }
        if let route = activeRoute {
            frame.markers += MapMarker.routeMarkers(for: route, compactLabels: focused) + MapMarker.milestoneMarkers(for: activeLandmarks, labelled: true)
            frame.routeCursor = inspectedMetres.map { route.chainage.point(at: $0) }
        }

        if layers.shuttleRoutes && !focused { frame.overlayLines = shuttleRoutes }
        if case .place(let id) = selection, let place = content.place(id), let bridge = place.bridge {
            for (i, seg) in bridge.segments.enumerated() {
                let pts = seg.map { projection.project(CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1])) }
                frame.overlayLines.append(MapOverlayLine(id: "bridge-\(i)", points: pts, colorHex: "#F5921A", width: 6, dashed: false, directional: false))
            }
        }
        if layers.smoke { frame.overlayAreas = smokePolygons }
        if let sunPreview { frame.overlayImages = [sunPreview.overlay] }

        for landmark in content.regions.valleyLandmarks {
            frame.labels.append(MapTextLabel(point: projection.project(CLLocationCoordinate2D(latitude: landmark.latitude, longitude: landmark.longitude)),
                                             text: landmark.name, size: 12.5, colorHex: dark ? "#E0DCD0" : "#4A4336", halo: true, priority: 5, kind: .landform))
        }
        frame.selectedMarkerId = selectedPlaceId ?? { if case .campsite(let r) = selection { return "site-\(r)" }; return nil }()
        frameContent = withUser(frame)
    }

    private func persistCategories() {
        preferences?.set(Array(activeCategories), forKey: Self.categoriesKey)
    }

    private func persistLayers() {
        guard let preferences, let data = try? JSONEncoder().encode(layers) else { return }
        preferences.set(data, forKey: Self.layersKey)
    }

    func cameraScaleChanged() {
        // Site markers appear above a zoom threshold; rebuild when crossing it.
        rebuildContent()
    }
}

extension Notification.Name {
    /// Posted after a backup import rewrote the stored map layer/category preferences.
    static let mapPreferencesImported = Notification.Name("dev.petty.fieldguide.mapPreferencesImported")
}

struct MapUserFix: Equatable {
    let fix: LiveFix
    let stale: Bool
}

struct SunPreviewState: Equatable {
    var date: Date
    var altitude: Double
    var azimuth: Double
    var overlay: MapOverlayImage

    static func == (lhs: SunPreviewState, rhs: SunPreviewState) -> Bool { lhs.date == rhs.date }
}

/// A point a link or search asked to show, with the label it came with; not a checked location.
struct ShownPin: Equatable {
    static let markerId = "pin"
    let title: String
    let latitude: Double
    let longitude: Double
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
