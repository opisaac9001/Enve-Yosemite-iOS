import SwiftUI

/// Regions, park hikes and campgrounds beyond the Valley, each framed on the map.
struct ParkMapFinderSheet: View {
    let content: Content
    @ObservedObject var model: MapViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section {
                        Button { dismiss(); model.focus(on: .park) } label: { Label("Whole park", systemImage: "mountain.2.fill") }
                        Button { dismiss(); model.fitValley() } label: { Label("Yosemite Valley", systemImage: "map.fill") }
                    } footer: {
                        Text("Valley places, campsites and shuttle stops are in the map's search.")
                    }
                }
                let regions = content.regions.regions.filter { matches($0.name + " " + $0.tagline) }
                if !regions.isEmpty {
                    Section("Regions") {
                        ForEach(regions) { region in
                            Button { dismiss(); model.focus(on: .region(region.id)) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(region.name).font(.fieldBody.weight(.semibold))
                                    Text(region.tagline).font(.fieldCaption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                ForEach(content.regions.regions) { region in
                    let hikes = content.hikes(inRegion: region.id).filter { matches([$0.name, region.name, $0.start].joined(separator: " ")) }
                    if !hikes.isEmpty {
                        Section("Hikes · \(region.name)") {
                            ForEach(hikes) { trail in hikeRow(trail) }
                        }
                    }
                }
                let campgrounds = content.campgrounds.campgrounds.filter { !$0.isValley && matches($0.name + " " + $0.area + " campground") }
                if !campgrounds.isEmpty {
                    Section("Campgrounds beyond the Valley") {
                        ForEach(campgrounds) { cg in
                            Button {
                                dismiss()
                                model.selection = .place("campground-\(cg.id)")
                                model.focus(on: cg.coordinate, scale: max(model.camera.scale, 0.12))
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cg.name).font(.fieldBody.weight(.semibold))
                                    Text("\(cg.area) · \(cg.sites) sites").font(.fieldCaption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .foregroundStyle(.primary)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Region, hike or campground")
            .navigationTitle("Find in the park")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .overlay {
                if !query.isEmpty && !hasResults { EmptyStateView(symbol: "magnifyingglass", title: "Nothing beyond the Valley matches", message: "Valley places and hikes are found with the map's search.") }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func hikeRow(_ trail: Trail) -> some View {
        let route = content.defaultHikeRoute(for: trail.id)
        return Button {
            dismiss()
            model.focus(on: .trail(trail.id))
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(trail.name).font(.fieldBody.weight(.semibold))
                Text((trail.routes.first.map { "\(HikeFormat.miles($0.distanceMi)) \($0.kind) · " } ?? "") + Self.coverage(route))
                    .font(.fieldCaption).foregroundStyle(.secondary)
            }
        }
        .accessibilityHint(route == nil ? "Shows the trailhead on the map" : "Draws the route on the map")
    }

    static func coverage(_ route: HikeRoute?) -> String {
        route == nil ? "trailhead only, no route trace" : "route mapped"
    }

    private var hasResults: Bool {
        content.regions.regions.contains { matches($0.name + " " + $0.tagline) }
            || content.trails.trails.contains { t in t.regionId.flatMap { content.region($0) }.map { matches([t.name, $0.name, t.start].joined(separator: " ")) } ?? false }
            || content.campgrounds.campgrounds.contains { !$0.isValley && matches($0.name + " " + $0.area + " campground") }
    }

    private func matches(_ text: String) -> Bool {
        let tokens = SearchIndex.tokens(query)
        guard !tokens.isEmpty else { return true }
        let haystack = SearchIndex.tokens(text)
        return tokens.allSatisfy { token in haystack.contains { $0.hasPrefix(token) } }
    }
}
