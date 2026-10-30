import SwiftUI
import CoreLocation

struct ParkScreen: View {
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var conditions = ConditionsStore.shared

    var body: some View {
        if let c = content.content {
            FieldScroll {
                FieldCard(eyebrow: "Park-wide schematic") {
                    ParkMapView(mode: .overview) { id in
                        if id.hasPrefix("region-") { router.push(.region(String(id.dropFirst(7)))) }
                    }
                    .frame(height: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("NPS park roads and boundary with CAL FIRE historical burn outlines. Orientation only: no navigation, routing or evacuation guidance.").font(.caption2).foregroundStyle(.secondary)
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
                    ParkMapView(mode: .region(region.id)) { _ in }.frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 12))
                    ForEach(region.points, id: \.name) { p in
                        Text("\(p.name) · \(p.kind)\(p.note.map { " · \($0)" } ?? "")").font(.caption2).foregroundStyle(.secondary)
                    }
                }
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
        } else {
            EmptyStateView(symbol: "mountain.2", title: "Region not found", message: "This link points to a region that is not in the guide.")
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
    @StateObject private var model = MapViewModel()
    @ObservedObject private var packs = GeoPackStore.shared
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if case .ready = packs.park, model.scene != nil {
                MapCanvasView(model: model, scaleLimits: 0.002...0.6, clampRect: model.scene?.extent.insetBy(dx: -5000, dy: -5000))
            } else if case .failed(let m) = packs.park {
                Text("Park geometry unavailable: \(m)").font(.fieldCaption)
            } else {
                ProgressView("Loading park geometry…")
            }
            VStack(spacing: 6) {
                Button { model.zoomIn() } label: { Image(systemName: "plus").frame(width: 30, height: 30).background(.regularMaterial, in: Circle()) }
                Button { model.zoomOut() } label: { Image(systemName: "minus").frame(width: 30, height: 30).background(.regularMaterial, in: Circle()) }
                Button { model.fitValley() } label: { Image(systemName: "arrow.down.left.and.arrow.up.right").frame(width: 30, height: 30).background(.regularMaterial, in: Circle()) }
            }
            .padding(8)
        }
        .task { await load() }
        .onChange(of: frameContent?.markers.count) { _, _ in applyContent() }
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

    private func load() async {
        await packs.loadPark()
        guard case .ready(let scene) = packs.park, let c = content.content else { return }
        model.setScene(scene)
        model.frameOptions = MapFrameOptions(dark: scheme == .dark, elementScale: theme.mapElementSize.scale, showBuildings: false, buildingLabelMode: .off, showRoadNames: true, showOneWayArrows: false)
        applyContent()
        var target = scene.extent
        if case .region(let rid) = mode, let region = c.region(rid), !region.points.isEmpty {
            let pts = region.points.map { scene.projection.project(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
            target = GeometryOps.bounds(of: pts).insetBy(dx: -4000, dy: -4000)
        }
        model.camera = MapCamera.fitting(target, in: CGSize(width: 360, height: 320), padding: 16)
    }

    private func applyContent() {
        guard let scene = model.scene, let c = content.content else { return }
        var frame = frameContent ?? MapFrameContent()
        let p = scene.projection
        if mode != .fire {
            for region in c.regions.regions {
                for point in region.points {
                    let symbol: String = switch point.kind {
                    case "entrance": "signpost.right.fill"
                    case "campground": "tent.fill"
                    case "town": "building.2.fill"
                    case "grove": "tree.fill"
                    case "fuel": "fuelpump.fill"
                    case "viewpoint": "binoculars.fill"
                    default: "mappin"
                    }
                    frame.markers.append(MapMarker(id: "region-\(region.id)", point: p.project(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)), title: point.name,
                                                   symbol: symbol, colorHex: "#1F4D3F", priority: point.kind == "entrance" ? 6 : 3, shape: .badge, clusterable: true, minScale: point.kind == "entrance" ? 0 : 0.012))
                }
            }
            for town in c.regions.gatewayTowns {
                frame.markers.append(MapMarker(id: "town-\(town.name)", point: p.project(CLLocationCoordinate2D(latitude: town.latitude, longitude: town.longitude)), title: town.name, symbol: "building.2.fill", colorHex: "#73704a", priority: 2, shape: .badge, clusterable: false))
                frame.labels.append(MapTextLabel(point: p.project(CLLocationCoordinate2D(latitude: town.latitude - 0.02, longitude: town.longitude)), text: town.name, size: 10, colorHex: scheme == .dark ? "#E8E4D8" : "#2B2B2B", halo: true, priority: 2))
            }
            for cg in c.campgrounds.campgrounds where !cg.isValley {
                frame.markers.append(MapMarker(id: "campground-\(cg.id)", point: p.project(cg.coordinate), title: cg.name, symbol: "tent.fill", colorHex: "#545f31", priority: 2, shape: .badge, clusterable: true, minScale: 0.012))
            }
        }
        for fr in c.status.fireRegions where fr.minor != true || mode == .fire {
            frame.labels.append(MapTextLabel(point: p.project(fr.coordinate), text: fr.mapLabel ?? fr.label, size: 11, colorHex: scheme == .dark ? "#E8E4D8" : "#2B2B2B", halo: true, priority: fr.minor == true ? 1 : 4))
        }
        model.frameContent = frame
    }
}
