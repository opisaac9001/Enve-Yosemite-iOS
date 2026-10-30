import SwiftUI

enum TrailSort: String, CaseIterable, Identifiable {
    case difficulty, distance, gain
    var id: String { rawValue }
    var title: String {
        switch self {
        case .difficulty: "Difficulty"
        case .distance: "Distance"
        case .gain: "Elevation gain"
        }
    }
}

struct TrailsScreen: View {
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var saved: SavedStore
    @EnvironmentObject private var router: AppRouter
    @State private var tab = 0

    var body: some View {
        if let c = content.content {
            FieldScroll {
                Picker("Section", selection: $tab) {
                    Text("Hikes").tag(0)
                    Text("Campgrounds").tag(1)
                    Text("Camping rules").tag(2)
                }
                .pickerStyle(.segmented)
                switch tab {
                case 0: hikes(c)
                case 1: campgrounds(c)
                default: rules(c)
                }
            }
            .fieldNavigationTitle("Trails & camping")
        }
    }

    @ViewBuilder private func hikes(_ c: Content) -> some View {
        HikesListView(content: c)
    }

    @ViewBuilder private func campgrounds(_ c: Content) -> some View {
        if let mine = saved.state.campsite {
            FieldCard(eyebrow: "My campsite") {
                Text(mine.label).font(.fieldHeading)
                HStack {
                    Button { router.push(.campground(mine.campgroundId)) } label: { Label("Campground", systemImage: "tent") }
                    if mine.latitude != nil { Button { router.showOnMap(mine.placeId != nil && c.campground(mine.campgroundId)?.isValley == true ? .site(campground: mine.campgroundId, ridbId: mine.siteId ?? "") : .coordinate(latitude: mine.latitude!, longitude: mine.longitude!, label: mine.label)) } label: { Label("Map", systemImage: "map") } }
                    Button(role: .destructive) { saved.setCampsite(nil) } label: { Label("Clear", systemImage: "trash") }
                }
                .buttonStyle(.bordered).font(.fieldCaption)
            }
        }
        Text("\(c.campgrounds.campgrounds.count) campgrounds · \(c.campsites.count) inventory sites").font(.fieldEyebrow).foregroundStyle(.secondary)
        ForEach(c.campgrounds.campgrounds) { cg in
            NavigationLink(value: Route.campground(cg.id)) {
                FieldCard {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cg.name).font(.fieldHeading)
                            Text("\(cg.area) · \(Int(cg.elevationFt)) ft").font(.fieldCaption).foregroundStyle(.secondary)
                            Text("\(cg.sites) sites (\(cg.accessibleSites) accessible) · \(cg.season)").font(.fieldCaption)
                            Text("\(cg.reservation) · \(cg.fee)").font(.fieldCaption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        FieldCard(eyebrow: "Source") {
            SourceList(sources: [c.campgrounds.source], checked: c.campgrounds.checked)
            Text("Site counts are Recreation.gov inventory points; a mapped site is never evidence of availability.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func rules(_ c: Content) -> some View {
        ForEach(c.campgrounds.guidance, id: \.label) { item in
            FieldCard(eyebrow: item.label) {
                Text(item.detail).font(.fieldBody)
                if let u = item.url, let url = URL(string: u) { ExternalLinkRow(label: "Official page", url: url) }
            }
        }
        FieldCard(eyebrow: "Housekeeping Camp") {
            LabeledTextList(items: c.housekeeping.details)
            SourceList(sources: c.housekeeping.sources)
        }
    }
}
