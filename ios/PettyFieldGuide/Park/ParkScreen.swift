import SwiftUI
import CoreLocation

struct ParkScreen: View {
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var conditions = ConditionsStore.shared

    var body: some View {
        if let c = content.content {
            FieldScroll {
                FieldCard(eyebrow: "Park map") {
                    ParkMapView(mode: .overview, onSelect: { id in
                        if let regionId = ParkMapView.regionId(ofMarker: id) { router.push(.region(regionId)) }
                        let hikes = ParkMapView.hikes(atMarker: id, content: c)
                        if hikes.count == 1 { router.push(.trail(hikes[0].id)) } else if let rid = hikes.first?.regionId { router.push(.region(rid)) }
                    }, height: 340)
                    Text("USGS 3DEP shaded relief with NPS roads, trails, buildings and parking, USGS NHD water and NPS trailhead points for the listed hikes. Orientation only: no navigation, routing or evacuation guidance.").font(.caption2).foregroundStyle(.secondary)
                    Button { router.showOnMap(.park) } label: { Label("Open the full-size map", systemImage: "mountain.2.fill").frame(minHeight: 44) }
                        .buttonStyle(.bordered).font(.fieldCaption)
                }
                FieldCard(eyebrow: "Hiking across the park") {
                    let parkHikes = c.trails.trails.filter { !$0.isValley }
                    Text("\(parkHikes.count) NPS-published day hikes outside the Valley, each with distances, trailheads and dated sources offline. Routes are highlighted only where the bundled NPS trail lines cover the whole hike.")
                        .font(.fieldCaption)
                    Button { HikeListState.shared.area = .all; router.show(.trails) } label: { Label("Browse all hikes", systemImage: "figure.hiking").frame(minHeight: 44) }
                        .buttonStyle(.borderedProminent).font(.fieldCaption)
                }
                Text("Regions").font(.fieldHeading)
                ForEach(c.regions.regions) { region in
                    NavigationLink(value: Route.region(region.id)) {
                        FieldCard {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(region.name).font(.fieldHeading)
                                    Text(region.tagline).font(.fieldCaption).foregroundStyle(.secondary)
                                    Text("\(region.elevationFt) ft · \(region.driveFromValley)").font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                                    let hikeCount = c.hikes(inRegion: region.id).count
                                    if hikeCount > 0 { Label("\(hikeCount) day hikes", systemImage: "figure.hiking").font(.caption2).foregroundStyle(Palette.accent) }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                roadStatus(c)
                chainControls(c)
                alertsAndWilderness(c)
                approaches(c)
            }
            .fieldNavigationTitle("Beyond the Valley")
        }
    }

    private func roadStatus(_ c: Content) -> some View {
        FieldCard {
            FeedHeader(title: "Official NPS road status", snapshot: conditions.conditions, refreshing: conditions.isRefreshing("conditions"), error: conditions.errors["conditions"], staleAfter: 6 * 3600) {
                Task { await conditions.refresh(.conditions) }
            }
            if let snap = conditions.conditions, !snap.isExpired {
                let roads = snap.payload.page.items.filter { $0.kind == "road" }
                if let note = snap.payload.page.roadTableNote { Text(note).font(.caption2).foregroundStyle(.secondary) }
                ForEach(roads) { NoticeRow(item: $0) }
                let work = snap.payload.page.items.filter { $0.kind == "roadwork" }
                if !work.isEmpty {
                    Text("Roadwork").font(.fieldEyebrow).foregroundStyle(.secondary)
                    ForEach(work) { NoticeRow(item: $0) }
                }
                let trails = snap.payload.page.items.filter { $0.kind == "trail" }
                if !trails.isEmpty {
                    Text("Trail notices").font(.fieldEyebrow).foregroundStyle(.secondary)
                    ForEach(trails) { NoticeRow(item: $0) }
                }
                if let updated = snap.payload.page.pageUpdated { Text("NPS page dated \(DateText.long(updated)); planned or long-term closures only.").font(.caption2).foregroundStyle(.secondary) }
                FeedStatusList(statuses: snap.payload.statuses)
            } else {
                Text("No current road table saved. Call 209-372-0200 (press 1, then 1) for recorded conditions.").font(.fieldCaption).foregroundStyle(.secondary)
            }
        }
    }

    private func chainControls(_ c: Content) -> some View {
        FieldCard {
            FeedHeader(title: "Caltrans chain signs · SR-41, SR-120, SR-140", snapshot: conditions.seasonal, refreshing: conditions.isRefreshing("seasonal"), error: conditions.errors["seasonal"], staleAfter: 3 * 3600) {
                Task { await conditions.refresh(.seasonal) }
            }
            if let snap = conditions.seasonal, !snap.isExpired {
                let chains = snap.payload.chains
                if chains.state == "ready" {
                    if chains.activeControls.isEmpty {
                        Text("No active chain controls on \(chains.signsChecked ?? 0) checked signs at \(DateText.long(chains.checkedAt)). Signs change with weather; this is not a forecast.").font(.fieldCaption)
                    } else {
                        ForEach(chains.activeControls, id: \.self) { ctl in
                            Text("\(ctl.route): \(ctl.requirement ?? "") \(ctl.text ?? "") \(ctl.location.map { "at \($0)" } ?? "")").font(.fieldCaption).foregroundStyle(Palette.ember)
                        }
                    }
                    ForEach(chains.districts, id: \.id) { d in
                        Text("District \(d.id): \(d.state), \(d.signsChecked ?? 0) signs\(d.feedRecordedAt.map { ", feed \(DateText.long($0))" } ?? "")").font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Chain sign feed \(chains.state)\(chains.detail.map { ": \($0)" } ?? "").").font(.fieldCaption).foregroundStyle(Palette.ember)
                }
            }
            if let u = c.status.links["quickmap"], let url = URL(string: u) { ExternalLinkRow(label: "Caltrans QuickMap", url: url) }
            if let u = c.status.links["tireChains"], let url = URL(string: u) { ExternalLinkRow(label: "NPS tire chain requirements", url: url) }
        }
    }

    @ViewBuilder private func alertsAndWilderness(_ c: Content) -> some View {
        if let snap = conditions.conditions, !snap.isExpired {
            FieldCard(eyebrow: "NPS alerts") {
                if snap.payload.alerts.items.isEmpty { Text("No NPS alerts in the saved snapshot (\(DateText.long(snap.payload.alerts.checkedAt))).").font(.fieldCaption).foregroundStyle(.secondary) }
                ForEach(snap.payload.alerts.items) { NoticeRow(item: $0) }
                if !snap.payload.roadEvents.items.isEmpty {
                    Text("NPS road events").font(.fieldEyebrow).foregroundStyle(.secondary)
                    ForEach(snap.payload.roadEvents.items) { NoticeRow(item: $0) }
                }
            }
            FieldCard(eyebrow: "Wilderness reports · dated field notes, not trail status") {
                if let rd = snap.payload.wilderness.reportDate { Text("Report dated \(DateText.long(rd))\(snap.payload.wilderness.pageUpdated.map { ", page updated \(DateText.long($0))" } ?? "")").font(.fieldCaption) }
                let groups = Dictionary(grouping: snap.payload.wilderness.items, by: { $0.area ?? "General" })
                ForEach(groups.keys.sorted(), id: \.self) { area in
                    Text(area).font(.fieldEyebrow).foregroundStyle(.secondary).padding(.top, 2)
                    ForEach(groups[area] ?? []) { item in Text(item.body).font(.caption2) }
                }
                Text("A water report never establishes that water is available.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func approaches(_ c: Content) -> some View {
        FieldCard(eyebrow: "Entrances & approach roads") {
            ForEach(c.regions.approaches) { road in
                VStack(alignment: .leading, spacing: 2) {
                    Text(road.name).font(.fieldBody.weight(.semibold))
                    Text("From \(road.from) · \(road.season)").font(.fieldCaption)
                    ForEach(road.notes, id: \.self) { Text("· \($0)").font(.caption2).foregroundStyle(.secondary) }
                    let notices = NoticeMatcher.notices(forRoad: road.caltransRoute, content: c, snapshot: conditions.conditions)
                    ForEach(notices) { n in Text("Notice: \(n.title)").font(.caption2).foregroundStyle(Palette.accent) }
                }
                .padding(.vertical, 2)
            }
            Text("Gateway towns").font(.fieldEyebrow).foregroundStyle(.secondary)
            ForEach(c.regions.gatewayTowns, id: \.name) { t in Text("\(t.name) · \(t.note ?? "")").font(.fieldCaption) }
        }
    }
}

struct RegionDetailView: View {
    let regionId: String
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var conditions = ConditionsStore.shared
    @State private var trailheadChoice: [Trail] = []

    var body: some View {
        if let c = content.content, let region = c.region(regionId) {
            FieldScroll {
                FieldCard {
                    Text(region.tagline).font(.fieldEyebrow).foregroundStyle(Palette.accent)
                    Text(region.summary).font(.fieldBody)
                    LabeledContent("Elevation", value: "\(region.elevationFt) ft").font(.fieldCaption)
                    LabeledContent("From the Valley", value: region.driveFromValley).font(.fieldCaption)
                    HStack {
                        Button { router.show(.status) } label: { Label("Weather · \(c.forecastPoint(region.weatherPoint)?.label ?? region.weatherPoint)", systemImage: "cloud.sun") }
                        if let url = AppRouter.url(for: .region(region.id)) { ShareLink(item: url, subject: Text(region.name)) { Label("Share", systemImage: "square.and.arrow.up") } }
                    }
                    .buttonStyle(.bordered).font(.fieldCaption)
                }
                FieldCard(eyebrow: "Map") {
                    ParkMapView(mode: .region(region.id), onSelect: { id in
                        let hikes = ParkMapView.hikes(atMarker: id, content: c)
                        if hikes.count == 1 { router.push(.trail(hikes[0].id)) } else if hikes.count > 1 { trailheadChoice = hikes }
                    }, height: 260)
                    ForEach(region.points, id: \.name) { p in
                        Text("\(p.name) · \(p.kind)\(p.note.map { " · \($0)" } ?? "")").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("Hiker pins are NPS trailhead points. Shaded relief is USGS 3DEP; NPS trail lines appear when zoomed in, and a drawn line does not mean the trail is open.").font(.caption2).foregroundStyle(.secondary)
                }
                hikesCard(region, c)
                FieldCard(eyebrow: "Seasonal road limitations") { Text(region.season).font(.fieldBody) }
                noticesCard(region, c)
                FieldCard(eyebrow: "Highlights") { ForEach(region.highlights, id: \.self) { Label($0, systemImage: "star").font(.fieldCaption) } }
                FieldCard(eyebrow: "Services") { ForEach(region.services, id: \.self) { Label($0, systemImage: "wrench.and.screwdriver").font(.fieldCaption) } }
                FieldCard(eyebrow: "Cautions") { ForEach(region.cautions, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.fieldCaption) } }
                let cams = c.webcams.webcams.filter { $0.regionId == region.id }
                if !cams.isEmpty {
                    FieldCard(eyebrow: "Webcams") { ForEach(cams) { cam in Button { router.push(.webcam(cam.id), in: .status) } label: { Label(cam.name, systemImage: "video") }.font(.fieldBody) } }
                }
                FieldCard(eyebrow: "Sources") { SourceList(sources: region.sources) }
            }
            .fieldNavigationTitle(region.name)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Hikes from this trailhead", isPresented: Binding(get: { !trailheadChoice.isEmpty }, set: { if !$0 { trailheadChoice = [] } }), titleVisibility: .visible) {
                ForEach(trailheadChoice) { t in Button(t.name) { router.push(.trail(t.id)) } }
            }
        } else {
            EmptyStateView(symbol: "mountain.2", title: "Region not found", message: "This link points to a region that is not in the guide.")
        }
    }

    @ViewBuilder private func hikesCard(_ region: ParkRegion, _ c: Content) -> some View {
        let hikes = c.hikes(inRegion: region.id)
        if !hikes.isEmpty {
            FieldCard(eyebrow: "Day hikes · \(hikes.count) published by NPS") {
                ForEach(hikes) { t in
                    NavigationLink(value: Route.trail(t.id)) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).font(.fieldBody.weight(.semibold))
                                Text(t.routes.map { "\(HikeFormat.miles($0.distanceMi)) \($0.kind)" }.joined(separator: " / ") + " · " + t.difficulty)
                                    .font(.fieldCaption).foregroundStyle(.secondary)
                                if !c.hikeRoutes(for: t.id).isEmpty { Label("Route mapped", systemImage: "point.topleft.down.to.point.bottomright.curvepath").font(.caption2).foregroundStyle(Palette.accent) }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if let advice = c.hikeAdvice(forRegion: region.id) {
                    Text("Before you go").font(.fieldEyebrow).foregroundStyle(.secondary).padding(.top, 4)
                    ForEach(advice.points, id: \.self) { Label($0, systemImage: "checkmark").font(.fieldCaption) }
                    SourceList(sources: [advice.source])
                }
                Button { HikeListState.shared.area = .region(region.id); router.show(.trails) } label: { Label("Filter in the hike list", systemImage: "line.3.horizontal.decrease.circle").frame(minHeight: 44) }
                    .font(.fieldCaption)
            }
        }
    }

    @ViewBuilder private func noticesCard(_ region: ParkRegion, _ c: Content) -> some View {
        let regionNotices = NoticeMatcher.notices(forRegion: region.id, content: c, snapshot: conditions.conditions)
        let roadNotices = region.roads.flatMap { NoticeMatcher.notices(forRoad: $0, content: c, snapshot: conditions.conditions) }
        let all = Array(Set(regionNotices + roadNotices)).sorted { $0.title < $1.title }
        FieldCard(eyebrow: "Official notices for this region") {
            if all.isEmpty {
                Text(conditions.conditions == nil ? "No saved NPS conditions snapshot." : "No saved notice names this region or its roads. That does not establish open access.").font(.fieldCaption).foregroundStyle(.secondary)
            } else {
                ForEach(all) { NoticeRow(item: $0) }
            }
            SnapshotFooter(snapshot: conditions.conditions, staleAfter: 6 * 3600)
        }
    }
}

struct ParkMapView: View {
    enum Mode: Equatable { case overview, region(String), fire }
    let mode: Mode
    var onSelect: (String) -> Void
    var frameContent: MapFrameContent? = nil
    /// Hike whose trailhead is emphasised.
    var focusTrailId: String? = nil
    /// A route traced on the park trail pack, drawn and framed like the Valley map's selected hike.
    var highlightRouteId: String? = nil
    var height: CGFloat = 260
    /// Describes the map canvas alone, so the control buttons keep their own labels.
    var canvasAccessibilityLabel: String? = nil

    nonisolated static let trailheadPrefix = "trailhead-"
    nonisolated static let scaleLimits: ClosedRange<CGFloat> = 0.002...0.6

    /// Park hikes sharing one NPS trailhead point get one pin; its id encodes the coordinate.
    nonisolated static func trailheadMarkerId(_ trail: Trail) -> String { trailheadPrefix + String(format: "%.6f,%.6f", trail.latitude, trail.longitude) }

    nonisolated static func hikes(atMarker id: String, content: Content) -> [Trail] {
        guard id.hasPrefix(trailheadPrefix) else { return [] }
        return content.trails.trails.filter { !$0.isValley && trailheadMarkerId($0) == id }
    }
    @StateObject private var model = MapViewModel()
    @ObservedObject private var packs = GeoPackStore.shared
    @ObservedObject private var tracker = LiveLocationTracker.shared
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.colorScheme) private var scheme

    private static let followScale: CGFloat = 0.03

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            mapArea
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            // Below the fixed-height map so long or enlarged status text never covers the map or its controls.
            LiveLocationBanner(model: model, note: limitsNote)
        }
        .liveLocationHost(model: model, followScale: Self.followScale)
        .task(id: highlightRouteId) { await load() }
        .onChange(of: frameContent?.markers.count) { _, _ in applyContent() }
        .onChange(of: frameContent?.routeCursor) { _, _ in applyContent() }
        .onChange(of: frameContent?.overlayAreas.count) { _, _ in applyContent() }
        .onChange(of: model.selection) { _, new in
            switch new {
            case .place(let id)?, .overlay(let id)?:
                onSelect(id)
                model.selection = nil
            default:
                break
            }
        }
    }

    private var mapArea: some View {
        ZStack(alignment: .bottomTrailing) {
            if case .ready = packs.map, model.scene != nil {
                MapCanvasView(model: model, scaleLimits: Self.scaleLimits, clampRect: model.scene?.extent.insetBy(dx: -5000, dy: -5000))
                    .accessibilityLabel(canvasAccessibilityLabel ?? "Park map")
            } else if case .failed(let m) = packs.map {
                Text("Park geometry unavailable: \(m)").font(.fieldCaption)
            } else {
                ProgressView("Loading park geometry…")
            }
            VStack(spacing: 6) {
                Button { LiveLocationControl.activate(model: model, tracker: tracker, followScale: Self.followScale) } label: {
                    Image(systemName: LiveLocationControl.symbol(isOn: tracker.state.isOn, following: model.followsUser))
                        .foregroundStyle(tracker.state.isOn ? Palette.river : Palette.accent)
                        .frame(width: 30, height: 30).background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel(LiveLocationControl.label(isOn: tracker.state.isOn, following: model.followsUser))
                Button { model.zoomIn() } label: { Image(systemName: "plus").frame(width: 30, height: 30).background(.regularMaterial, in: Circle()) }
                Button { model.zoomOut() } label: { Image(systemName: "minus").frame(width: 30, height: 30).background(.regularMaterial, in: Circle()) }
                Button { model.fitPark() } label: { Image(systemName: "arrow.down.left.and.arrow.up.right").frame(width: 30, height: 30).background(.regularMaterial, in: Circle()) }
                    .accessibilityLabel("Fit the whole park")
            }
            .padding(8)
        }
    }

    private var limitsNote: String {
        guard let c = content.content else { return "Orientation only, not navigation or rescue guidance." }
        let untraced = c.trails.trails.filter { !$0.isValley && c.hikeRoutes(for: $0.id).isEmpty }.count
        return "Orientation only, not navigation or rescue guidance. NPS trail lines appear when zoomed in; their positions are approximate and a line does not mean the trail is open. \(untraced) park hikes have no verified route trace."
    }

    private func load() async {
        await packs.loadMap()
        guard case .ready(let scene) = packs.map, let c = content.content else { return }
        model.setScene(scene)
        model.frameOptions = Self.frameOptions(dark: scheme == .dark, elementScale: theme.mapElementSize.scale)
        model.frameOptions.showFireScars = mode == .fire
        model.frameOptions.highlightedRouteId = highlightedTrace(in: scene)?.id
        applyContent()
        var target = scene.boundary.first?.bounds ?? scene.extent
        if let trace = highlightedTrace(in: scene) {
            target = Self.routeRect(trace)
        } else if case .region(let rid) = mode, let rect = Self.regionRect(rid, scene: scene, content: c) {
            target = rect
        }
        model.camera = MapCamera.fitting(target, in: CGSize(width: 360, height: 320), padding: 16)
    }

    static func frameOptions(dark: Bool, elementScale: CGFloat) -> MapFrameOptions {
        MapFrameOptions(dark: dark, elementScale: elementScale, showBuildings: false, buildingLabelMode: .off, showRoadNames: true, showOneWayArrows: false)
    }

    static func routeRect(_ trace: MapRouteTrace) -> CGRect {
        trace.bounds.insetBy(dx: -max(300, trace.bounds.width * 0.08), dy: -max(300, trace.bounds.height * 0.08))
    }

    /// The region's guide points and trailheads with a 4 km margin.
    static func regionRect(_ regionId: String, scene: MapScene, content c: Content) -> CGRect? {
        guard let region = c.region(regionId), !region.points.isEmpty else { return nil }
        let pts = region.points.map { scene.projection.project(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
            + c.hikes(inRegion: regionId).map { scene.projection.project($0.coordinate) }
        return GeometryOps.bounds(of: pts).insetBy(dx: -4000, dy: -4000)
    }

    private func highlightedTrace(in scene: MapScene) -> MapRouteTrace? {
        highlightRouteId.flatMap { scene.hikeRoutes[$0] }
    }

    private func applyContent() {
        guard let scene = model.scene, let c = content.content else { return }
        model.frameContent = model.withUser(Self.frame(mode: mode, scene: scene, content: c, dark: scheme == .dark, focusTrailId: focusTrailId,
                                                       highlightRouteId: highlightRouteId, base: frameContent ?? MapFrameContent()))
    }

    /// Region points, gateway towns, trailheads, campgrounds and fire-region labels over `base`, with the highlighted route's badges.
    static func frame(mode: Mode, scene: MapScene, content c: Content, dark: Bool, focusTrailId: String?, highlightRouteId: String?,
                      base: MapFrameContent = MapFrameContent()) -> MapFrameContent {
        var frame = base
        let p = scene.projection
        let trace = highlightRouteId.flatMap { scene.hikeRoutes[$0] }
        if let trace { frame.markers += MapMarker.routeMarkers(for: trace, compactLabels: true) }
        frame.markers += markers(mode: mode, projection: p, content: c, focusTrailId: trace == nil ? focusTrailId : nil, categories: nil)
        if mode != .fire {
            for town in c.regions.gatewayTowns {
                frame.labels.append(MapTextLabel(point: p.project(CLLocationCoordinate2D(latitude: town.latitude - 0.02, longitude: town.longitude)), text: town.name, size: 10, colorHex: dark ? "#E8E4D8" : "#2B2B2B", halo: true, priority: 2))
            }
        }
        for fr in c.status.fireRegions where fr.minor != true || mode == .fire {
            frame.labels.append(MapTextLabel(point: p.project(fr.coordinate), text: fr.mapLabel ?? fr.label, size: 11, colorHex: dark ? "#E8E4D8" : "#2B2B2B", halo: true, priority: fr.minor == true ? 1 : 4))
        }
        return frame
    }

    /// The place category that filters each kind of park marker on the Map tab; towns are always shown.
    nonisolated private static let regionPointCategories = ["entrance": "information", "visitor-center": "information", "fuel": "services", "store": "shopping",
                                                            "lodging": "lodging", "campground": "lodging", "viewpoint": "outdoors", "ski": "outdoors", "grove": "outdoors", "trailhead": "outdoors"]

    nonisolated static func regionPointId(_ regionId: String, _ index: Int) -> String { "region-\(regionId)#\(index)" }

    /// Region id of a region-point marker, nil for any other marker.
    nonisolated static func regionId(ofMarker id: String) -> String? {
        guard id.hasPrefix("region-") else { return nil }
        return String(id.dropFirst(7).prefix { $0 != "#" })
    }

    /// Region points, gateway towns, NPS trailheads of the listed park hikes and campgrounds beyond the Valley.
    /// A region point within 300 m of a trailhead or campground marker is left to that marker. With `categories`,
    /// each kind is kept only when its place category is on (towns always are).
    nonisolated static func markers(mode: Mode, projection p: LocalProjection, content c: Content, focusTrailId: String?, categories: Set<String>?) -> [MapMarker] {
        guard mode != .fire else { return [] }
        func allowed(_ category: String?) -> Bool { category.map { categories?.contains($0) ?? true } ?? true }
        var markers: [MapMarker] = []
        var anchors: [CGPoint] = []
        let shown = c.trails.trails.filter { trail in
            guard let rid = trail.regionId else { return false }
            if case .region(let id) = mode { return id == rid }
            return true
        }
        for (id, group) in Dictionary(grouping: shown, by: trailheadMarkerId).sorted(by: { $0.key < $1.key }) {
            anchors.append(p.project(group[0].coordinate))
            guard allowed("outdoors") else { continue }
            let focused = group.contains { $0.id == focusTrailId }
            let title = group.count == 1 ? "\(group[0].name) trailhead" : "Trailhead · \(group.count) hikes"
            markers.append(MapMarker(id: id, point: p.project(group[0].coordinate), title: focused ? "Start · " + (c.trail(focusTrailId ?? "")?.name ?? title) : title,
                                     symbol: "figure.hiking", colorHex: focused ? "#F5921A" : "#2d6c4f", priority: focused ? 20 : 3, shape: .badge,
                                     clusterable: !focused, minScale: focused || mode != .overview ? 0 : 0.02, labelMinScale: focused ? 0 : nil))
        }
        for cg in c.campgrounds.campgrounds where !cg.isValley {
            anchors.append(p.project(cg.coordinate))
            guard allowed("lodging") else { continue }
            markers.append(MapMarker(id: "campground-\(cg.id)", point: p.project(cg.coordinate), title: cg.name, symbol: "tent.fill", colorHex: "#545f31", priority: 2, shape: .badge, clusterable: true, minScale: 0.012))
        }
        for region in c.regions.regions {
            for (i, point) in region.points.enumerated() {
                let projected = p.project(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
                guard allowed(regionPointCategories[point.kind]), !anchors.contains(where: { hypot($0.x - projected.x, $0.y - projected.y) < 300 }) else { continue }
                let symbol: String = switch point.kind {
                case "entrance": "signpost.right.fill"
                case "campground": "tent.fill"
                case "town": "building.2.fill"
                case "grove": "tree.fill"
                case "fuel": "fuelpump.fill"
                case "viewpoint": "binoculars.fill"
                default: "mappin"
                }
                markers.append(MapMarker(id: regionPointId(region.id, i), point: projected, title: point.name, symbol: symbol, colorHex: "#1F4D3F",
                                         priority: point.kind == "entrance" ? 6 : 3, shape: .badge, clusterable: true, minScale: point.kind == "entrance" ? 0 : 0.012))
            }
        }
        for town in c.regions.gatewayTowns {
            markers.append(MapMarker(id: "town-\(town.name)", point: p.project(CLLocationCoordinate2D(latitude: town.latitude, longitude: town.longitude)), title: town.name, symbol: "building.2.fill", colorHex: "#73704a", priority: 2, shape: .badge, clusterable: false))
        }
        return markers
    }
}
