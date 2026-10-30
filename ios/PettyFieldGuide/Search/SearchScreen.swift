import SwiftUI

/// Global search. The query, filter and results persist while the app is open.
@MainActor
final class SearchState: ObservableObject {
    static let shared = SearchState()
    @Published var query = ""
    @Published var kinds: Set<SearchHit.Kind> = []
}

struct SearchScreen: View {
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var saved: SavedStore
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var state = SearchState.shared
    @Environment(\.bottomBarInset) private var inset

    private var results: [SearchHit] {
        guard let c = content.content else { return [] }
        return SearchIndex.shared(for: c).search(state.query, kinds: state.kinds.isEmpty ? nil : state.kinds, savedIds: Set(saved.state.places.keys))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ChipButton(title: "All", active: state.kinds.isEmpty) { state.kinds = [] }
                    ForEach(SearchHit.Kind.allCases, id: \.self) { kind in
                        ChipButton(title: kind.title, active: state.kinds.contains(kind)) {
                            if state.kinds.contains(kind) { state.kinds.remove(kind) } else { state.kinds.insert(kind) }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            List {
                if state.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section {
                        Text("Search names, areas, phone numbers, campsite numbers and planning topics. Try “Upper Pines site 18”, “Housekeeping 179”, “209-372-0200” or “chains”.")
                            .font(.fieldCaption).foregroundStyle(.secondary)
                    }
                } else if results.isEmpty {
                    EmptyStateView(symbol: "magnifyingglass", title: "No matches", message: "Try fewer words, a stop number, or a different spelling.")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(groupedResults, id: \.kind) { group in
                        Section(group.kind.title) {
                            ForEach(group.hits) { hit in
                                Button { open(hit) } label: { SearchHitRow(hit: hit, isSaved: isSaved(hit)) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Color.clear.frame(height: inset).listRowBackground(Color.clear)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .searchable(text: $state.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Places, sites, phones, topics")
        .fieldNavigationTitle("Search")
    }

    private struct Group { let kind: SearchHit.Kind; let hits: [SearchHit] }

    private var groupedResults: [Group] {
        let all = results
        var order: [SearchHit.Kind] = []
        var buckets: [SearchHit.Kind: [SearchHit]] = [:]
        for hit in all {
            if buckets[hit.kind] == nil { order.append(hit.kind) }
            buckets[hit.kind, default: []].append(hit)
        }
        return order.map { Group(kind: $0, hits: buckets[$0] ?? []) }
    }

    private func isSaved(_ hit: SearchHit) -> Bool {
        if case .place(let id)? = hit.route { return saved.isSaved(id) }
        return false
    }

    private func open(_ hit: SearchHit) {
        if let focus = hit.mapFocus, hit.kind == .campsite || hit.kind == .place {
            router.showOnMap(focus)
        } else if let tool = hit.mapTool {
            router.openMapTool(tool)
        } else if let sheet = hit.sheet {
            router.sheet = sheet
        } else if let route = hit.route {
            router.push(route, in: hit.section ?? router.section)
        } else if let section = hit.section {
            router.show(section)
        }
    }
}

struct SearchHitRow: View {
    let hit: SearchHit
    let isSaved: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Palette.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(hit.title).font(.fieldBody.weight(.semibold))
                    if isSaved { Image(systemName: "star.fill").font(.caption).foregroundStyle(Palette.accent) }
                }
                Text(hit.subtitle).font(.fieldCaption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Image(systemName: hit.mapFocus != nil ? "map" : "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var symbol: String {
        switch hit.kind {
        case .place: "mappin"
        case .saved: "star"
        case .contact: "phone"
        case .campsite: "tent"
        case .region: "mountain.2"
        case .trail: "figure.hiking"
        case .permit: "checkmark.seal"
        case .event: "calendar"
        case .document: "doc.text"
        case .webcam: "video"
        case .topic: "lightbulb"
        }
    }
}
