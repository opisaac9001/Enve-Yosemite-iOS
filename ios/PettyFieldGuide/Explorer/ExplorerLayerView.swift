import SwiftUI
import CoreLocation

/// "catalog" lists the packs; any other id opens that layer on the park map.
struct ExplorerLayerView: View {
    let layerId: String
    @ObservedObject private var store = ExplorerStore.shared
    @ObservedObject private var server = ServerConfig.shared

    var body: some View {
        if layerId == "catalog" { catalog } else if let layer = store.catalog?.layers.first(where: { $0.id == layerId }) { ExplorerMapView(layer: layer) } else {
            EmptyStateView(symbol: "square.stack.3d.up", title: "Layer not found", message: "")
        }
    }

    private var catalog: some View {
        FieldScroll {
            Text("Optional NPS GIS packs for the whole park. Counts are the publisher's snapshot, not live expectations. Packs download from the companion server and stay on this device until removed.").font(.fieldCaption).foregroundStyle(.secondary)
            if !server.isConfigured { Text("Downloads need the companion server address (Settings).").font(.fieldCaption).foregroundStyle(Palette.ember) }
            ForEach(store.catalog?.layers ?? []) { layer in
                FieldCard {
                    HStack {
                        Circle().fill(Color(hex: layer.color)).frame(width: 12, height: 12)
                        Text(layer.title).font(.fieldHeading)
                        Spacer()
                        stateView(layer)
                    }
                    Text(layer.description).font(.fieldCaption)
                    Text("\(layer.count) records · \(ByteCountFormatter.string(fromByteCount: Int64(layer.compressedBytes), countStyle: .file)) download, \(ByteCountFormatter.string(fromByteCount: Int64(layer.unpackedBytes), countStyle: .file)) unpacked").font(.caption2).foregroundStyle(.secondary)
                    Text("\(layer.publisher) · source updated \(DateText.long(layer.sourceUpdatedAt)) · pack fetched \(DateText.long(layer.fetchedAt))").font(.caption2).foregroundStyle(.secondary)
                    Text(layer.updatePolicy).font(.caption2).foregroundStyle(.tertiary)
                    HStack {
                        switch store.state(layer.id) {
                        case .ready:
                            NavigationLink(value: Route.explorerLayer(layer.id)) { Label("Show on map", systemImage: "map") }
                            Button(role: .destructive) { store.remove(layer) } label: { Label("Remove", systemImage: "trash") }
                        case .downloading:
                            ProgressView()
                        default:
                            Button { Task { await store.download(layer) } } label: { Label("Download", systemImage: "arrow.down.circle") }.disabled(!server.isConfigured)
                        }
                        if let url = URL(string: layer.sourceUrl) { Link(destination: url) { Label("Source service", systemImage: "arrow.up.right.square") } }
                    }
                    .buttonStyle(.bordered).font(.fieldCaption)
                }
            }
            FieldCard(eyebrow: "Project notes · public NPS planning records") {
                Text("Historical project areas are planning boundaries, not the mapped geometry above, and public comments on those projects are not imported here.").font(.fieldCaption)
                if let url = URL(string: "https://parkplanning.nps.gov/projectHome.cfm?projectID=87715") { ExternalLinkRow(label: "Wapama Falls footbridge safety project (PEPC 87715)", url: url) }
                if let url = URL(string: "https://parkplanning.nps.gov/showFile.cfm?projectID=89467&sfid=407325") { ExternalLinkRow(label: "Concessions planning document (PEPC 89467)", url: url) }
            }
            Text("Stored: \(ByteCountFormatter.string(fromByteCount: Int64(store.downloadedBytes), countStyle: .file)) · catalogue generated \(store.catalog.map { DateText.long($0.generatedAt) } ?? "–")").font(.caption2).foregroundStyle(.secondary)
        }
        .fieldNavigationTitle("GIS explorer")
        .task { await store.refreshCatalog() }
    }

    @ViewBuilder private func stateView(_ layer: ExplorerLayer) -> some View {
        switch store.state(layer.id) {
        case .absent: StatusPill(state: .none, text: "not downloaded")
        case .downloading: StatusPill(state: .unknown, text: "downloading…")
        case .ready(let bytes): StatusPill(state: .ready, text: "offline · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
        case .failed(let m): StatusPill(state: .unavailable, text: m)
        }
    }
}

struct ExplorerMapView: View {
    let layer: ExplorerLayer
    @ObservedObject private var store = ExplorerStore.shared
    @StateObject private var model = MapViewModel()
    @ObservedObject private var packs = GeoPackStore.shared
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.colorScheme) private var scheme
    @State private var document: GeoJSON.Document?
    @State private var query = ""
    @State private var valleyOnly = false
    @State private var inspected: [GeoFeature] = []
    @State private var loading = true

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if model.scene != nil, document != nil { MapCanvasView(model: model, scaleLimits: 0.002...6, clampRect: model.scene?.extent.insetBy(dx: -5000, dy: -5000)) } else { ProgressView(loading ? "Unpacking \(layer.count) records…" : "Layer unavailable") }
            }
            .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Search visible records", text: $query).textFieldStyle(.roundedBorder)
                    Toggle("Valley", isOn: $valleyOnly).toggleStyle(.button).font(.fieldCaption)
                }
                Text(countText).font(.caption2).foregroundStyle(.secondary)
                if !inspected.isEmpty {
                    ScrollView {
                        ForEach(Array(inspected.prefix(6).enumerated()), id: \.offset) { _, f in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.string("MAPLABEL") ?? f.string(primaryName) ?? f.id ?? "Record").font(.fieldCaption.weight(.semibold))
                                ForEach(layer.fields.keys.sorted(), id: \.self) { key in
                                    if let v = f.properties[key], v != .null { Text("\(layer.fields[key] ?? key): \(v.displayText)").font(.caption2).foregroundStyle(.secondary) }
                                }
                            }
                            .padding(.vertical, 2)
                            Divider()
                        }
                    }
                    .frame(maxHeight: 180)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .fieldNavigationTitle(layer.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: query) { _, _ in applyContent() }
        .onChange(of: valleyOnly) { _, on in
            guard let scene = model.scene else { return }
            model.camera = MapCamera.fitting(on ? scene.projection.projectedRect(YosemiteGeo.valleyBounds) : scene.extent, in: model.camera.viewSize == .zero ? CGSize(width: 360, height: 400) : model.camera.viewSize, padding: 12)
            applyContent()
        }
        .onChange(of: model.lastTap) { _, tap in if let tap { inspect(at: tap.projected) } }
    }

    private var primaryName: String { ["TRLNAME", "RDNAME", "BLDGNAME", "StructureName", "POINAME", "MAPLABEL"].first { layer.fields[$0] != nil } ?? "MAPLABEL" }

    private var countText: String {
        guard let document else { return "" }
        let visible = visibleFeatures(document).count
        return "\(visible) of \(document.features.count) records match · tap the map to inspect overlapping records"
    }

    private func load() async {
        await packs.loadPark()
        guard case .ready(let scene) = packs.park else { loading = false; return }
        model.setScene(scene)
        model.frameOptions = MapFrameOptions(dark: scheme == .dark, elementScale: theme.mapElementSize.scale, showBuildings: false, buildingLabelMode: .off, showRoadNames: false, showOneWayArrows: false)
        model.camera = MapCamera.fitting(scene.extent, in: CGSize(width: 360, height: 400), padding: 12)
        document = await store.document(for: layer)
        loading = false
        applyContent()
    }

    private func visibleFeatures(_ doc: GeoJSON.Document) -> [GeoFeature] {
        let q = SearchIndex.normalise(query)
        return doc.features.filter { f in
            if valleyOnly, !featureIntersectsValley(f) { return false }
            guard !q.isEmpty else { return true }
            return f.properties.values.contains { SearchIndex.normalise($0.displayText).contains(q) }
        }
    }

    private func featureIntersectsValley(_ f: GeoFeature) -> Bool {
        let b = YosemiteGeo.valleyBounds
        func any(_ coords: [CLLocationCoordinate2D]) -> Bool { coords.contains { b.contains(latitude: $0.latitude, longitude: $0.longitude) } }
        switch f.geometry {
        case .point(let c): return b.contains(latitude: c.latitude, longitude: c.longitude)
        case .lineString(let l): return any(l)
        case .multiLineString(let ls): return ls.contains(where: any)
        case .polygon(let rings): return rings.first.map(any) ?? false
        case .multiPolygon(let polys): return polys.contains { $0.first.map(any) ?? false }
        }
    }

    private func applyContent() {
        guard let scene = model.scene, let document else { return }
        var frame = MapFrameContent()
        let p = scene.projection
        for (i, f) in visibleFeatures(document).enumerated() {
            let id = "x-\(i)"
            switch f.geometry {
            case .point(let c):
                frame.markers.append(MapMarker(id: id, point: p.project(c), title: f.string("MAPLABEL") ?? f.string(primaryName) ?? "Record", colorHex: layer.color, priority: 1, shape: .dot, clusterable: true, minScale: 0))
            case .lineString(let l):
                frame.overlayLines.append(MapOverlayLine(id: id, points: p.project(l), colorHex: layer.color, width: 2, dashed: false, directional: false))
            case .multiLineString(let ls):
                for (j, l) in ls.enumerated() { frame.overlayLines.append(MapOverlayLine(id: "\(id)-\(j)", points: p.project(l), colorHex: layer.color, width: 2, dashed: false, directional: false)) }
            case .polygon(let rings):
                frame.overlayAreas.append(MapOverlayArea(id: id, rings: rings.map(p.project), fillHex: layer.color, fillAlpha: 0.35, strokeHex: layer.color, title: f.string("MAPLABEL")))
            case .multiPolygon(let polys):
                for (j, rings) in polys.enumerated() { frame.overlayAreas.append(MapOverlayArea(id: "\(id)-\(j)", rings: rings.map(p.project), fillHex: layer.color, fillAlpha: 0.35, strokeHex: layer.color, title: f.string("MAPLABEL"))) }
            }
        }
        model.frameContent = frame
    }

    /// All records overlapping the tapped point (polygons containing it, lines/points within tolerance).
    private func inspect(at point: CGPoint) {
        guard let document, let scene = model.scene else { return }
        let tolerance = 12 / max(model.camera.scale, 0.001)
        let p = scene.projection
        inspected = visibleFeatures(document).filter { f in
            switch f.geometry {
            case .point(let c): return hypot(p.project(c).x - point.x, p.project(c).y - point.y) <= tolerance
            case .lineString(let l): return GeometryOps.distance(point, toPolyline: p.project(l)) <= tolerance
            case .multiLineString(let ls): return ls.contains { GeometryOps.distance(point, toPolyline: p.project($0)) <= tolerance }
            case .polygon(let rings): return rings.first.map { GeometryOps.pointInRing(point, p.project($0)) } ?? false
            case .multiPolygon(let polys): return polys.contains { $0.first.map { GeometryOps.pointInRing(point, p.project($0)) } ?? false }
            }
        }
    }
}
