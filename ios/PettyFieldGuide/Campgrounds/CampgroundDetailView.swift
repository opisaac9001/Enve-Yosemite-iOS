import SwiftUI

struct CampgroundDetailView: View {
    let campgroundId: String
    var initialSite: String?
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var saved: SavedStore
    @EnvironmentObject private var router: AppRouter
    @State private var siteQuery = ""
    @State private var selectedSite: String?

    var body: some View {
        if let c = content.content, let cg = c.campground(campgroundId) {
            let sites = c.sites(in: cg.id)
            FieldScroll {
                FieldCard {
                    Text("\(cg.area) · \(Int(cg.elevationFt)) ft").font(.fieldEyebrow).foregroundStyle(.secondary)
                    LabeledContent("Sites", value: "\(cg.sites) (\(cg.accessibleSites) accessible)")
                    LabeledContent("Season", value: cg.season)
                    LabeledContent("Reservations", value: cg.reservation)
                    LabeledContent("Fee snapshot", value: cg.fee)
                    LabeledContent("RV / trailer", value: cg.rvLimit)
                    LabeledContent("Water & restrooms", value: cg.water)
                    ForEach(cg.notes, id: \.self) { Label($0, systemImage: "info.circle").font(.fieldCaption) }
                    if let closures = cg.loopClosures {
                        ForEach(closures, id: \.closes) { lc in
                            Label("Loops \(lc.loops.joined(separator: ", ")) close for the season \(DateText.long(lc.closes)) (\(lc.source)).", systemImage: "calendar.badge.exclamationmark").font(.fieldCaption)
                        }
                    }
                    HStack {
                        if let pid = cg.placeId, c.place(pid) != nil {
                            Button { router.showOnMap(.place(pid)) } label: { Label("Show on map", systemImage: "map") }
                        }
                        if let url = URL(string: "https://www.recreation.gov/camping/campgrounds/\(recreationFacilityId(cg.id) ?? "")"), recreationFacilityId(cg.id) != nil {
                            Link(destination: url) { Label("Recreation.gov", systemImage: "arrow.up.right.square") }
                        }
                    }
                    .buttonStyle(.bordered).font(.fieldCaption)
                }
                .font(.fieldCaption)

                if !cg.isValley && !sites.isEmpty {
                    FieldCard(eyebrow: "Numbered site map") {
                        SiteMapView(campgroundId: cg.id, sites: sites, selectedSite: $selectedSite, mySiteId: saved.state.campsite?.siteId)
                            .frame(height: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Text("Campground roads and restrooms from NPS GIS; site points from Recreation.gov. Positions are inventory records, not reservation availability or surveyed pads.").font(.caption2).foregroundStyle(.secondary)
                    }
                } else if cg.isValley {
                    FieldCard(eyebrow: "Site map") {
                        Text("Valley campsites are drawn on the main map when zoomed in. Search a site number or pick one below to jump there.").font(.fieldCaption)
                    }
                }

                FieldCard(eyebrow: "Sites · \(sites.count) inventory points") {
                    TextField("Site number, loop or type", text: $siteQuery).textFieldStyle(.roundedBorder)
                    let shown = filteredSites(sites)
                    ForEach(shown.prefix(60)) { site in
                        SiteRow(site: site, isMine: saved.state.campsite?.siteId == site.ridbId, isSelected: selectedSite == site.ridbId) {
                            selectedSite = site.ridbId
                            router.push(.site(campground: cg.id, ridbId: site.ridbId))
                        }
                    }
                    if shown.count > 60 { Text("Showing 60 of \(shown.count); narrow the search.").font(.caption2).foregroundStyle(.secondary) }
                    if sites.isEmpty { Text("Recreation.gov lists no inventory for this campground in the bundled snapshot.").font(.fieldCaption).foregroundStyle(.secondary) }
                }
            }
            .fieldNavigationTitle(cg.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { if let initialSite { selectedSite = initialSite } }
        } else {
            EmptyStateView(symbol: "tent", title: "Campground not found", message: "This link points to a campground that is not in the guide.")
        }
    }

    private func filteredSites(_ sites: [Campsite]) -> [Campsite] {
        let q = siteQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let base = sites.sorted { (Int($0.site) ?? 0, $0.site) < (Int($1.site) ?? 0, $1.site) }
        guard !q.isEmpty else { return base }
        let number = q.filter(\.isNumber)
        return base.filter { s in
            (!number.isEmpty && s.displayNumber == String(Int(number) ?? -1)) || (number.isEmpty && (s.loop?.lowercased().contains(q) == true || s.typeTitle.lowercased().contains(q)))
                || (!number.isEmpty && s.site.hasPrefix(number) && q.count <= 3)
        }
    }

    /// Recreation.gov facility ids published for Yosemite campgrounds.
    private func recreationFacilityId(_ id: String) -> String? {
        switch id {
        case "cg-upper-pines": "232447"
        case "cg-lower-pines": "232450"
        case "cg-north-pines": "232449"
        case "cg-camp-4": "10004152"
        case "cg-wawona": "232446"
        case "cg-bridalveil-creek": "232453"
        case "cg-hodgdon-meadow": "232451"
        case "cg-crane-flat": "232452"
        case "cg-tamarack-flat": "10093459"
        case "cg-white-wolf": "10093455"
        case "cg-yosemite-creek": "10093456"
        case "cg-porcupine-flat": "10093458"
        case "cg-tuolumne-meadows": "232448"
        default: nil
        }
    }
}

struct SiteRow: View {
    let site: Campsite
    let isMine: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(site.displayNumber).font(.fieldBody.weight(.bold)).frame(width: 44, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(site.typeTitle)\(site.loop.map { " · loop \($0)" } ?? "")").font(.fieldCaption)
                    Text([site.maxPeople.map { "up to \($0) people" }, site.maxVehicleFt.map { "vehicles to \($0) ft" }, site.accessible ? "accessible" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if isMine { Image(systemName: "tent.fill").foregroundStyle(Palette.accent) }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
            .background(isSelected ? Palette.accent.opacity(0.12) : .clear)
        }
        .buttonStyle(.plain)
    }
}

struct SiteDetailView: View {
    let campgroundId: String
    let ridbId: String
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var saved: SavedStore
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        if let c = content.content, let cg = c.campground(campgroundId), let site = c.campsites.first(where: { $0.ridbId == ridbId }) {
            FieldScroll {
                FieldCard {
                    Text(cg.name).font(.fieldEyebrow).foregroundStyle(.secondary)
                    Text("Site \(site.displayNumber)").font(.fieldTitle)
                    LabeledContent("Type", value: site.typeTitle)
                    if let loop = site.loop { LabeledContent("Loop", value: loop) }
                    if let p = site.maxPeople { LabeledContent("Capacity", value: "\(p) people") }
                    if let v = site.maxVehicleFt { LabeledContent("Vehicle length", value: "up to \(v) ft") }
                    LabeledContent("Accessible", value: site.accessible ? "Listed accessible" : "Not listed")
                    LabeledContent("RIDB id", value: site.ridbId)
                    Text("Inventory position from Recreation.gov. It says nothing about current availability or reservation status.").font(.caption2).foregroundStyle(.secondary)
                }
                .font(.fieldCaption)
                HStack {
                    Button {
                        saved.setCampsite(SavedCampsite(campgroundId: cg.id, siteId: site.ridbId, label: "\(cg.name) · site \(site.displayNumber)", placeId: cg.placeId,
                                                        latitude: site.latitude, longitude: site.longitude, updatedAt: .stamp))
                    } label: { Label(saved.state.campsite?.siteId == site.ridbId ? "This is my campsite" : "Mark as my campsite", systemImage: "tent") }
                    .disabled(saved.state.campsite?.siteId == site.ridbId)
                    if cg.isValley {
                        Button { router.showOnMap(.site(campground: cg.id, ridbId: site.ridbId)) } label: { Label("Show on map", systemImage: "map") }
                    }
                    if let url = site.recreationGovURL { Link(destination: url) { Label("Recreation.gov", systemImage: "arrow.up.right.square") } }
                }
                .buttonStyle(.bordered).font(.fieldCaption)
                if !cg.isValley {
                    FieldCard(eyebrow: "Site map") {
                        SiteMapView(campgroundId: cg.id, sites: c.sites(in: cg.id), selectedSite: .constant(site.ridbId), mySiteId: saved.state.campsite?.siteId)
                            .frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .fieldNavigationTitle("Site \(site.displayNumber)")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            EmptyStateView(symbol: "tent", title: "Site not found", message: "This site is not in the bundled Recreation.gov inventory.")
        }
    }
}
