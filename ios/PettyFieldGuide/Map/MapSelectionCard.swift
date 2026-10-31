import SwiftUI

struct MapSelectionCard: View {
    let selection: MapSelection
    let content: Content
    let scene: MapScene?
    @ObservedObject var model: MapViewModel
    let dismiss: () -> Void
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var saved: SavedStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.fieldHeading)
                    Text(subtitle).font(.fieldCaption).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }
                    .accessibilityLabel("Close")
            }
            actions
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.cardStroke(scheme)))
    }

    private var place: Place? {
        if case .place(let id) = selection { return content.place(id) }
        return nil
    }

    private var site: Campsite? {
        if case .campsite(let id) = selection { return content.campsites.first { $0.ridbId == id } }
        return nil
    }

    private var title: String {
        switch selection {
        case .place: place?.name ?? "Place"
        case .campsite:
            if let site, let cg = content.campground(site.campground) { "\(cg.name) · site \(site.displayNumber)" } else { "Campsite" }
        case .building(let id): scene?.buildings.first { $0.id == id }?.name ?? "Building"
        case .parking(let id): scene?.parking.first { $0.id == id }?.name ?? "Parking area"
        case .trail(let id): scene?.trails.first { $0.id == id }?.name ?? "Trail segment"
        case .hike(let routeId): content.hikeRoute(routeId).flatMap { content.trail($0.trailId)?.name } ?? "Hike"
        case .road(let id): scene?.roads.first { $0.id == id }?.name ?? "Road segment"
        case .car: "My car"
        case .campsitePin: saved.state.campsite?.label ?? "My campsite"
        case .cluster(let ids): "\(ids.count) places here"
        case .overlay(let id): model.frameContent.overlayAreas.first { $0.id == id }?.title ?? "Map overlay"
        }
    }

    private var subtitle: String {
        switch selection {
        case .place: place.map { "\($0.campus) · \($0.summary)" } ?? ""
        case .campsite:
            site.map { s in "\(s.typeTitle)\(s.loop.map { " · loop \($0)" } ?? "")\(s.accessible ? " · accessible" : ""). Inventory point only; availability is not shown." } ?? ""
        case .building(let id):
            if let b = scene?.buildings.first(where: { $0.id == id }) {
                [b.attributes["BLDGTYPE"]?.displayText, b.attributes["BLDGSTATUS"]?.displayText, b.numericId.map { "NPS building \($0)" }].compactMap { $0 }.joined(separator: " · ")
            } else { "" }
        case .parking: "NPS parking polygon. A mapped lot does not establish current access or free spaces."
        case .trail(let id):
            if let t = scene?.trails.first(where: { $0.id == id }) {
                ["NPS feature \(t.id)", t.attributes["TRLUSE"]?.displayText, t.attributes["TRLSURFACE"]?.displayText, t.attributes["TRLCLASS"]?.displayText].compactMap { $0 }.joined(separator: " · ")
            } else { "" }
        case .hike(let routeId): content.hikeRoute(routeId)?.label ?? ""
        case .road(let id):
            if let r = scene?.roads.first(where: { $0.id == id }) {
                [r.attributes["RDCLASS"]?.displayText, r.attributes["RDSURFACE"]?.displayText, r.oneWay != 0 ? "one-way" : nil, r.seasonal].compactMap { $0 }.joined(separator: " · ")
            } else { "" }
        case .car:
            saved.state.car.map { "Pinned \(DateText.short($0.updatedAt)) · \($0.basis == .location ? "from your position" : "placed by hand")\($0.note.map { " · \($0)" } ?? "")" } ?? ""
        case .campsitePin: "Saved on this device. Inventory position, not a reservation."
        case .cluster: "Zoom in further or pick one below."
        case .overlay(let id): id.hasPrefix("plume") ? "NOAA HMS smoke analysis polygon from the saved snapshot; not a ground-level air-quality reading." : (id.hasPrefix("route") ? "Shuttle route shape from the NPS GTFS feed." : "Overlay from the saved snapshot.")
        }
    }

    @ViewBuilder private var actions: some View {
        switch selection {
        case .place(let id):
            HStack {
                Button { router.push(.place(id), in: .directory) } label: { Label("Details", systemImage: "info.circle") }
                Button { saved.toggleSaved(id) } label: { Label(saved.isSaved(id) ? "Saved" : "Save", systemImage: saved.isSaved(id) ? "star.fill" : "star") }
                if let p = place, p.kind == .shuttleStop, let n = p.stopNumber {
                    Button { router.push(.stop(n), in: .navigation) } label: { Label("Times", systemImage: "clock") }
                }
            }
            .buttonStyle(.bordered).font(.fieldCaption)
        case .campsite(let ridb):
            HStack {
                if let site {
                    Button { router.push(.site(campground: site.campground, ridbId: ridb), in: .trails) } label: { Label("Site details", systemImage: "info.circle") }
                    Button { markCampsite(site) } label: { Label(saved.state.campsite?.siteId == ridb ? "My campsite" : "Set as my campsite", systemImage: "tent") }
                }
            }
            .buttonStyle(.bordered).font(.fieldCaption)
        case .car:
            HStack {
                Button { dismiss(); router.openMapTool(.parkedCar) } label: { Label("Edit note or spot", systemImage: "square.and.pencil") }
                Button(role: .destructive) { saved.setCar(nil); dismiss() } label: { Label("Remove pin", systemImage: "trash") }
            }
            .buttonStyle(.bordered).font(.fieldCaption)
        case .campsitePin:
            HStack {
                if let camp = saved.state.campsite {
                    Button { router.push(.campground(camp.campgroundId), in: .trails) } label: { Label("Campground", systemImage: "info.circle") }
                }
                Button(role: .destructive) { saved.setCampsite(nil); dismiss() } label: { Label("Clear", systemImage: "trash") }
            }
            .buttonStyle(.bordered).font(.fieldCaption)
        case .cluster(let ids):
            // Every member, including trailheads, region points and pins that have no directory record.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(model.frameContent.markers.filter { ids.contains($0.id) }, id: \.id) { marker in
                        Button(marker.accessibleName) { model.selection = Self.selection(forMarker: marker.id) }.buttonStyle(.bordered).font(.fieldCaption)
                    }
                }
            }
        case .building(let id):
            if let b = scene?.buildings.first(where: { $0.id == id }), let match = content.places.first(where: { $0.npsBuildingId == b.numericId }) {
                Button { model.selection = .place(match.id) } label: { Label("Open \(match.name)", systemImage: "arrow.right.circle") }
                    .buttonStyle(.bordered).font(.fieldCaption)
            }
        case .trail(let id):
            // Every hike that walks this exact NPS feature; a shared corridor lists them all and picks none.
            let hikes = hikesUsing(segmentId: id)
            if !hikes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(hikes.count == 1 ? "Part of this hike" : "Part of \(hikes.count) hikes").font(.fieldEyebrow).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(hikes, id: \.route.id) { item in
                                Button { model.selectHike(item.route.id) } label: { Label(item.trail.name, systemImage: "figure.hiking").frame(minHeight: 44) }
                                    .buttonStyle(.bordered).font(.fieldCaption)
                            }
                        }
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    /// One entry per hike that walks the feature, offering that hike's default variant when it does, else the first that does.
    private func hikesUsing(segmentId: String) -> [(trail: Trail, route: HikeRoute)] {
        guard let featureId = Int(segmentId) else { return [] }
        let using = content.hikeRoutes(usingFeature: featureId)
        var out: [(Trail, HikeRoute)] = []
        for trail in content.trails.trails {
            let routes = using.filter { $0.trailId == trail.id }
            guard let route = routes.first(where: \.isDefault) ?? routes.first else { continue }
            out.append((trail, route))
        }
        return out
    }

    static func selection(forMarker id: String) -> MapSelection {
        switch id {
        case "car": .car
        case "campsite": .campsitePin
        default: id.hasPrefix("site-") ? .campsite(ridbId: String(id.dropFirst(5))) : .place(id)
        }
    }

    private func markCampsite(_ site: Campsite) {
        guard let cg = content.campground(site.campground) else { return }
        saved.setCampsite(SavedCampsite(campgroundId: cg.id, siteId: site.ridbId, label: "\(cg.name) · site \(site.displayNumber)", placeId: cg.placeId,
                                        latitude: site.latitude, longitude: site.longitude, updatedAt: .stamp))
    }
}
