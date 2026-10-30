import SwiftUI

struct SiteMapView: View {
    let campgroundId: String
    let sites: [Campsite]
    @Binding var selectedSite: String?
    var mySiteId: String?
    @StateObject private var model = MapViewModel()
    @ObservedObject private var packs = GeoPackStore.shared
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.colorScheme) private var scheme
    @State private var scene: MapScene?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if scene != nil {
                MapCanvasView(model: model, scaleLimits: 0.05...8, clampRect: scene?.extent.insetBy(dx: -300, dy: -300))
            } else {
                ProgressView("Loading site map…")
            }
            VStack(spacing: 6) {
                Button { model.zoomIn() } label: { Image(systemName: "plus").frame(width: 30, height: 30).background(.regularMaterial, in: Circle()) }
                Button { model.zoomOut() } label: { Image(systemName: "minus").frame(width: 30, height: 30).background(.regularMaterial, in: Circle()) }
                Button { model.fitValley() } label: { Image(systemName: "arrow.down.left.and.arrow.up.right").frame(width: 30, height: 30).background(.regularMaterial, in: Circle()) }
            }
            .padding(8)
        }
        .task { await load() }
        .onChange(of: selectedSite) { _, new in
            model.selection = new.map { .campsite(ridbId: $0) }
            if let new, let site = sites.first(where: { $0.ridbId == new }) { model.focus(on: site.coordinate, scale: max(model.camera.scale, 1.5)) }
        }
        .onChange(of: model.selection) { _, new in
            if case .campsite(let id)? = new { selectedSite = id }
        }
    }

    private func load() async {
        guard scene == nil, let built = await packs.campgroundScene(campgroundId) else { return }
        scene = built
        model.setScene(built)
        model.frameOptions = MapFrameOptions(dark: scheme == .dark, elementScale: theme.mapElementSize.scale, showBuildings: false, buildingLabelMode: .off, showRoadNames: true)
        var frame = MapFrameContent()
        for site in sites {
            let mine = site.ridbId == mySiteId
            frame.markers.append(MapMarker(id: "site-\(site.ridbId)", point: built.projection.project(site.coordinate), title: "Site \(site.displayNumber)",
                                           glyph: site.displayNumber, colorHex: mine ? "#F5921A" : (site.accessible ? "#2d6c4f" : "#545f31"),
                                           priority: mine ? 50 : 1, shape: .site, clusterable: false))
        }
        for poi in built.pois {
            frame.markers.append(MapMarker(id: "restroom-\(poi.id)", point: poi.point, title: poi.name ?? "Restroom", symbol: "toilet.fill", colorHex: "#4f5b66", priority: 2, shape: .badge, clusterable: false))
        }
        frame.selectedMarkerId = selectedSite.map { "site-\($0)" }
        model.frameContent = frame
        model.camera = MapCamera.fitting(built.extent, in: CGSize(width: 360, height: 320), padding: 16)
        model.selection = selectedSite.map { .campsite(ridbId: $0) }
    }
}
