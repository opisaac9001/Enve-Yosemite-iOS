import SwiftUI

enum HikeDistanceFilter: String, CaseIterable, Identifiable {
    case any, short, medium, long
    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: "Any length"
        case .short: "Under 3 mi"
        case .medium: "3–8 mi"
        case .long: "Over 8 mi"
        }
    }

    func matches(_ route: TrailRoute) -> Bool {
        switch self {
        case .any: true
        case .short: route.distanceMi < 3
        case .medium: route.distanceMi >= 3 && route.distanceMi <= 8
        case .long: route.distanceMi > 8
        }
    }
}

enum HikeDifficultyFilter: String, CaseIterable, Identifiable {
    case all, easy, moderate, strenuous
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .easy: "Easy"
        case .moderate: "Moderate"
        case .strenuous: "Strenuous"
        }
    }

    func matches(rank: Int) -> Bool {
        switch self {
        case .all: true
        case .easy: rank <= 1
        case .moderate: (2...3).contains(rank)
        case .strenuous: rank >= 4
        }
    }
}

/// Query, filter and sort state for the hikes list; kept across navigation like the global search.
@MainActor
final class HikeListState: ObservableObject {
    static let shared = HikeListState()
    @Published var query = ""
    @Published var difficulty: HikeDifficultyFilter = .all
    @Published var distance: HikeDistanceFilter = .any
    @Published var savedOnly = false
    @Published var sort: TrailSort = .difficulty
}

/// A hike that passed the filters together with the one published variant that satisfied them.
struct HikeMatch: Identifiable {
    let trail: Trail
    let route: TrailRoute
    /// True when a difficulty or length filter chose the variant, so opening the hike should land on it.
    let filtered: Bool
    var id: String { trail.id }
}

enum HikeFilters {
    /// Difficulty and length are tested against the same variant: a hike matches when one of its published
    /// routes satisfies both. The default route wins ties so an unfiltered list opens the usual variant.
    static func apply(_ trails: [Trail], query: String, difficulty: HikeDifficultyFilter, distance: HikeDistanceFilter, savedOnly: Bool, savedIds: Set<String>, sort: TrailSort,
                      defaultRouteId: (Trail) -> String?) -> [HikeMatch] {
        let tokens = SearchIndex.tokens(query)
        let filtering = difficulty != .all || distance != .any
        var matches: [HikeMatch] = []
        for trail in trails {
            if savedOnly && !savedIds.contains(trail.id) { continue }
            if !tokens.isEmpty {
                let text = Set(SearchIndex.tokens(([trail.name, trail.summary, trail.start, trail.difficulty] + trail.routes.map(\.label)).joined(separator: " ")))
                guard tokens.allSatisfy({ token in text.contains(token) || text.contains { $0.hasPrefix(token) } }) else { continue }
            }
            let preferred = defaultRouteId(trail)
            let candidates = trail.routes.filter { difficulty.matches(rank: $0.difficultyRank ?? trail.difficultyRank) && distance.matches($0) }
            guard let route = candidates.first(where: { $0.id == preferred }) ?? candidates.first else { continue }
            matches.append(HikeMatch(trail: trail, route: route, filtered: filtering))
        }
        switch sort {
        case .difficulty: return matches.sorted { ($0.route.difficultyRank ?? $0.trail.difficultyRank, $0.route.distanceMi) < ($1.route.difficultyRank ?? $1.trail.difficultyRank, $1.route.distanceMi) }
        case .distance: return matches.sorted { $0.route.distanceMi != $1.route.distanceMi ? $0.route.distanceMi < $1.route.distanceMi : $0.trail.longestDistanceMi < $1.trail.longestDistanceMi }
        case .gain: return matches.sorted { ($0.route.gainFt ?? 0, $0.route.distanceMi) < ($1.route.gainFt ?? 0, $1.route.distanceMi) }
        }
    }
}

struct HikesListView: View {
    let content: Content
    @EnvironmentObject private var saved: SavedStore
    @ObservedObject private var state = HikeListState.shared
    @ObservedObject private var conditions = ConditionsStore.shared
    @State private var noticesExpanded = false

    private var hikes: [HikeMatch] {
        HikeFilters.apply(content.trails.trails, query: state.query, difficulty: state.difficulty, distance: state.distance,
                          savedOnly: state.savedOnly, savedIds: Set(saved.state.places.keys), sort: state.sort) { content.defaultHikeRoute(for: $0.id)?.id }
    }

    private var trailNotices: [NoticeItem] {
        conditions.conditions.map { snap in snap.isExpired ? [] : snap.payload.page.items.filter { $0.kind == "trail" } } ?? []
    }

    var body: some View {
        searchField
        filterChips
        noticesStrip
        HStack {
            Text(hikes.count == content.trails.trails.count ? "\(hikes.count) Valley hikes · \(content.hikeRoutes.routes.count) mapped routes" : "\(hikes.count) of \(content.trails.trails.count) hikes")
                .font(.fieldEyebrow).foregroundStyle(.secondary)
            Spacer()
            Picker("Sort", selection: $state.sort) { ForEach(TrailSort.allCases) { Text($0.title).tag($0) } }.pickerStyle(.menu).font(.fieldCaption)
        }
        if hikes.isEmpty {
            EmptyStateView(symbol: "figure.hiking", title: "No hikes match", message: state.savedOnly ? "Star a hike to keep it here." : "Try fewer words or a wider length band.")
        }
        ForEach(hikes) { match in
            NavigationLink(value: match.filtered ? Route.hikeRoute(trailId: match.trail.id, routeId: match.route.id) : Route.trail(match.trail.id)) {
                HikeCard(match: match, isSaved: saved.isSaved(match.trail.id),
                         noticeCount: NoticeMatcher.notices(forTrail: match.trail.id, content: content, snapshot: conditions.conditions).count)
            }
            .buttonStyle(.plain)
        }
        FieldCard(eyebrow: "Before you go") {
            ForEach(content.trails.preparationTips, id: \.self) { Label($0, systemImage: "checkmark").font(.fieldCaption) }
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search hikes", text: $state.query)
                .textFieldStyle(.plain).autocorrectionDisabled().textInputAutocapitalization(.never)
            if !state.query.isEmpty {
                Button { state.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 32, height: 32) }.accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(minHeight: 44)
        .background(.regularMaterial, in: Capsule())
    }

    private var filterChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(HikeDifficultyFilter.allCases) { f in
                        ChipButton(title: f.title, active: state.difficulty == f) { state.difficulty = f }
                    }
                    ChipButton(title: "Saved", symbol: "star.fill", active: state.savedOnly) { state.savedOnly.toggle() }
                }
            }
            .accessibilityLabel("Difficulty filters")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(HikeDistanceFilter.allCases) { f in
                        ChipButton(title: f.title, symbol: f == .any ? nil : "ruler", active: state.distance == f, color: Palette.pine) { state.distance = f }
                    }
                }
            }
            .accessibilityLabel("Length filters")
        }
    }

    /// One line that never hides the list; expands to the official items and the dated corridor notices.
    private var noticesStrip: some View {
        let items = trailNotices
        return VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation { noticesExpanded.toggle() } } label: {
                HStack {
                    Image(systemName: items.isEmpty ? "info.circle" : "exclamationmark.triangle.fill").foregroundStyle(items.isEmpty ? Color.secondary : Palette.accent)
                    Text(items.isEmpty ? (conditions.conditions == nil ? "No saved NPS trail notices. Nothing here means a trail is open." : "No trail items in the saved snapshot; that is not confirmation a trail is open.")
                         : "\(items.count) official trail notice\(items.count == 1 ? "" : "s") in the saved snapshot")
                        .font(.fieldCaption).multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: noticesExpanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(noticesExpanded ? "Hide trail notices" : "Show trail notices")
            if noticesExpanded {
                ForEach(items) { NoticeRow(item: $0) }
                SnapshotFooter(snapshot: conditions.conditions, staleAfter: 6 * 3600)
                Text(content.trails.corridorRepairNotice).font(.fieldCaption)
                Text(content.trails.iceClosureNotice).font(.fieldCaption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct HikeCard: View {
    let match: HikeMatch
    var isSaved: Bool
    var noticeCount: Int

    private var trail: Trail { match.trail }

    var body: some View {
        FieldCard {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(trail.name).font(.fieldHeading)
                        if isSaved { Image(systemName: "star.fill").font(.caption).foregroundStyle(Palette.accent).accessibilityLabel("Saved") }
                        if noticeCount > 0 { Label("\(noticeCount)", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(Palette.accent) }
                    }
                    Text(match.filtered ? "\(trail.difficulty(for: match.route)) · \(match.route.label)" : trail.difficulty).font(.fieldCaption.weight(.semibold)).foregroundStyle(Palette.accent)
                    ForEach(trail.routes, id: \.id) { r in
                        Text("\(r.label): \(HikeFormat.miles(r.distanceMi)) \(r.kind)\(r.gainFt.map { ", \(HikeFormat.feet($0)) gain" } ?? "")\(r.difficulty.map { " · \($0)" } ?? "")")
                            .font(.fieldCaption.weight(match.filtered && r.id == match.route.id ? .semibold : .regular))
                    }
                    Text("Start: \(trail.start)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
        }
    }
}
