import SwiftUI
import CoreLocation

enum QuickFilter: String, CaseIterable, Identifiable {
    case saved, toilets, water, ice, accessible, showers
    var id: String { rawValue }
    var title: String {
        switch self {
        case .saved: "Saved"
        case .toilets: "Toilets"
        case .water: "Water"
        case .ice: "Ice"
        case .accessible: "Accessible"
        case .showers: "Showers"
        }
    }
    var symbol: String {
        switch self {
        case .saved: "star.fill"
        case .toilets: "toilet"
        case .water: "drop"
        case .ice: "snowflake"
        case .accessible: "figure.roll"
        case .showers: "shower"
        }
    }
    var noteKey: String? {
        switch self {
        case .toilets: "toilets"
        case .water: "water"
        case .ice: "ice"
        case .accessible: "accessible"
        case .showers: "showers"
        case .saved: nil
        }
    }
}

enum DirectorySort: String, CaseIterable, Identifiable {
    case region, name, distance
    var id: String { rawValue }
    var title: String {
        switch self {
        case .region: "By area"
        case .name: "By name"
        case .distance: "By distance"
        }
    }
}

@MainActor
final class DirectoryState: ObservableObject {
    static let shared = DirectoryState()
    @Published var query = ""
    @Published var category: String?
    @Published var quick: QuickFilter?
    @Published var sort: DirectorySort = .region
}

struct DirectoryScreen: View {
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var saved: SavedStore
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var state = DirectoryState.shared
    @StateObject private var location = LocationService()
    @Environment(\.bottomBarInset) private var inset

    var body: some View {
        Group {
            if let c = content.content {
                list(c)
            }
        }
        .searchable(text: $state.query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search \(content.content?.places.filter(\.listed).count ?? 0) places")
        .fieldNavigationTitle("Places")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    Button { router.sheet = .waterIceGuide } label: { Image(systemName: "drop.fill") }
                        .accessibilityLabel("Open the water and ice guide")
                    Menu {
                        Picker("Sort", selection: $state.sort) {
                            ForEach(DirectorySort.allCases) { Text($0.title).tag($0) }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down.circle") }
                    .accessibilityLabel("Sort")
                }
            }
        }
        .onChange(of: state.sort) { _, new in
            if new == .distance && location.lastLocation == nil { location.request(.sortByDistance) }
        }
    }

    private func list(_ c: Content) -> some View {
        let places = filtered(c)
        return List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(QuickFilter.allCases) { q in
                            ChipButton(title: q.title, symbol: q.symbol, active: state.quick == q) { state.quick = state.quick == q ? nil : q }
                        }
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ChipButton(title: "All categories", active: state.category == nil) { state.category = nil }
                        ForEach(c.categories.categories) { cat in
                            ChipButton(title: cat.label, symbol: cat.symbol, active: state.category == cat.id, color: Color(hex: cat.color)) {
                                state.category = state.category == cat.id ? nil : cat.id
                            }
                        }
                    }
                }
                if let q = state.quick, let key = q.noteKey, let note = c.categories.quickFilterNotes[key] {
                    Text(note).font(.fieldCaption).foregroundStyle(.secondary)
                }
                if state.quick == .water || state.quick == .ice {
                    Button { router.sheet = .waterIceGuide } label: { Label("Open the water & ice guide: all 46 taps, fillers and ice machines with directions and sources", systemImage: "drop.fill") }
                        .font(.fieldCaption)
                }
                if state.sort == .distance {
                    Text(location.lastLocation == nil ? (location.message ?? "Distance sorting needs your position once; allow location when asked.") : "Distances are straight-line from your last position, not walking routes.")
                        .font(.fieldCaption).foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

            if places.isEmpty {
                EmptyStateView(symbol: "mappin.slash", title: "Nothing matches", message: "Clear a filter or try another spelling.")
                    .listRowBackground(Color.clear)
            } else if state.sort == .region {
                ForEach(grouped(places), id: \.campus) { group in
                    Section("\(group.campus) · \(group.places.count)") {
                        ForEach(group.places) { place in row(place, c) }
                    }
                }
            } else {
                Section("\(places.count) places") {
                    ForEach(places) { place in row(place, c) }
                }
            }
            Color.clear.frame(height: inset).listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func row(_ place: Place, _ c: Content) -> some View {
        NavigationLink(value: Route.place(place.id)) {
            PlaceRow(place: place, category: place.categories.first.flatMap { c.category($0) }, isSaved: saved.isSaved(place.id),
                     distance: location.lastLocation.map { haversineMeters($0.coordinate, place.coordinate) })
        }
    }

    private func filtered(_ c: Content) -> [Place] {
        var places = c.places.filter(\.listed)
        if let cat = state.category { places = places.filter { $0.categories.contains(cat) } }
        switch state.quick {
        case .saved: places = c.places.filter { saved.isSaved($0.id) }
        case .toilets: places = places.filter { $0.facility == "toilet" || $0.categories.contains("facilities") }
        case .water: places = places.filter { $0.isWater }
        case .ice: places = places.filter { $0.isIce }
        case .accessible: places = places.filter { $0.isAccessibleListed }
        case .showers: places = places.filter { $0.facility == "shower" || $0.glyph == "SH" }
        case nil: break
        }
        let q = state.query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let ids = Set(SearchIndex.shared(for: c).places(matching: q, limit: 400, content: c).map(\.id))
            let order = SearchIndex.shared(for: c).places(matching: q, limit: 400, content: c)
            places = order.filter { p in ids.contains(p.id) && places.contains(where: { $0.id == p.id }) }
            return places
        }
        switch state.sort {
        case .name: return places.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .distance:
            guard let here = location.lastLocation?.coordinate else { return places.sorted { $0.mapPriority > $1.mapPriority } }
            return places.sorted { haversineMeters(here, $0.coordinate) < haversineMeters(here, $1.coordinate) }
        case .region:
            return places.sorted { ($0.campus, -$0.mapPriority, $0.name) < ($1.campus, -$1.mapPriority, $1.name) }
        }
    }

    private struct CampusGroup { let campus: String; let places: [Place] }

    private func grouped(_ places: [Place]) -> [CampusGroup] {
        var order: [String] = []
        var buckets: [String: [Place]] = [:]
        for p in places {
            if buckets[p.campus] == nil { order.append(p.campus) }
            buckets[p.campus, default: []].append(p)
        }
        return order.map { CampusGroup(campus: $0, places: buckets[$0] ?? []) }
    }
}

struct PlaceRow: View {
    let place: Place
    let category: PlaceCategory?
    let isSaved: Bool
    var distance: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color(hex: isSaved ? "#F5921A" : (category?.color ?? "#4F5B66"))).frame(width: 34, height: 34)
                if let glyph = place.glyph ?? place.stopNumber.map(String.init) {
                    Text(glyph).font(.system(size: glyph.count > 2 ? 9 : 12, weight: .bold)).foregroundStyle(.white)
                } else {
                    Image(systemName: category?.symbol ?? "mappin").font(.caption.weight(.bold)).foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(place.name).font(.fieldBody.weight(.semibold))
                    if isSaved { Image(systemName: "star.fill").font(.caption2).foregroundStyle(Palette.accent) }
                }
                Text(place.summary).font(.fieldCaption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 8) {
                    if let first = place.hours.first { Text(first).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                    if let distance { Text(Measurement<UnitLength>.milesText(meters: distance)).font(.caption2.weight(.semibold)).foregroundStyle(Palette.accent) }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
