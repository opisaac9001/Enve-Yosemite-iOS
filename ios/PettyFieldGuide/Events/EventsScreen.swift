import SwiftUI

enum EventsMode: String, CaseIterable, Identifiable {
    case calendar, programs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .programs: "Programs"
        }
    }
}

@MainActor
final class EventsState: ObservableObject {
    static let shared = EventsState(defaults: .standard, saved: SavedStore.shared.state)
    static let filterKey = "events.filter"
    static let customCategoriesKey = "events.custom"

    @Published var mode: EventsMode = .calendar
    @Published var month: Date = Date()
    @Published var selectedDay: String = EventCalendar.day(Date())
    @Published var filter: EventFilter { didSet { if let data = try? JSONEncoder().encode(filter) { defaults.set(data, forKey: Self.filterKey) } } }
    @Published var customCategories: [CustomEventCategory] { didSet { if let data = try? JSONEncoder().encode(customCategories) { defaults.set(data, forKey: Self.customCategoriesKey) } } }

    private let defaults: UserDefaults

    /// A saved view marked as default applies at launch; otherwise the last-used filter returns.
    init(defaults: UserDefaults, saved: SavedState) {
        self.defaults = defaults
        if let view = saved.eventViews.first(where: \.isDefault), let f = EventFilter.decode(view.encodedFilter) {
            filter = f
        } else if let data = defaults.data(forKey: Self.filterKey), let f = try? JSONDecoder().decode(EventFilter.self, from: data) {
            filter = f
        } else {
            filter = EventFilter()
        }
        if let data = defaults.data(forKey: Self.customCategoriesKey), let c = try? JSONDecoder().decode([CustomEventCategory].self, from: data) { customCategories = c } else { customCategories = [] }
    }
}

struct EventsScreen: View {
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var saved: SavedStore
    @ObservedObject private var state = EventsState.shared
    @ObservedObject private var conditions = ConditionsStore.shared
    @State private var showFilters = false
    @State private var importedFilterMessage: String?

    var body: some View {
        if let c = content.content {
            FieldScroll {
                Picker("View", selection: $state.mode) {
                    ForEach(EventsMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Events view: calendar or programs")
                switch state.mode {
                case .calendar:
                    let all = allOccurrences(c)
                    let visible = all.filter { EventCalendar.matches($0, filter: state.filter, custom: state.customCategories) }
                    header(c, total: all.count, visible: visible.count)
                    MonthGrid(month: state.month, selectedDay: $state.selectedDay, counts: countsByDay(visible))
                    dayAgenda(visible, c)
                    npsFooter
                case .programs:
                    HStack {
                        Toggle("Show ended", isOn: $state.filter.showEnded).font(.fieldCaption).toggleStyle(.button)
                        Spacer()
                        Text("Same filters as the calendar").font(.caption2).foregroundStyle(.secondary)
                    }
                    ProgramCatalogView(content: c, filter: state.filter, customCategories: state.customCategories)
                }
            }
            .fieldNavigationTitle("Events")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFilters = true } label: { Label("Filters", systemImage: state.filter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") }
                }
            }
            .sheet(isPresented: $showFilters) { EventFiltersSheet(content: c).nightVision() }
            .onAppear { applyPendingFilter() }
            .onChange(of: router.pendingEventFilter) { _, _ in applyPendingFilter() }
            .alert("Filter view imported", isPresented: Binding(get: { importedFilterMessage != nil }, set: { if !$0 { importedFilterMessage = nil } })) {
                Button("OK") { importedFilterMessage = nil }
            } message: { Text(importedFilterMessage ?? "") }
        }
    }

    private func applyPendingFilter() {
        guard let encoded = router.pendingEventFilter else { return }
        router.pendingEventFilter = nil
        if let f = EventFilter.decode(encoded) {
            state.filter = f
            importedFilterMessage = "The shared filter now applies. Save it as a named view from Filters if you want to keep it."
        } else {
            importedFilterMessage = "The shared filter could not be read, so nothing changed."
        }
    }

    private func allOccurrences(_ c: Content) -> [EventOccurrence] {
        var list = c.events.events.flatMap { EventCalendar.occurrences(of: $0) }
        if let snap = conditions.programs, !snap.isExpired {
            list += snap.payload.events.items.flatMap { EventCalendar.occurrences(ofNPS: $0, mapping: c.events.npsMapping, areaRegions: c.events.npsAreaRegions) }
        }
        return list
    }

    private func countsByDay(_ occ: [EventOccurrence]) -> [String: Int] {
        occ.reduce(into: [:]) { $0[$1.day, default: 0] += 1 }
    }

    private func header(_ c: Content, total: Int, visible: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(monthTitle).font(.fieldHeading)
                Spacer()
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.bordered)
            HStack {
                Button("Today") { state.month = Date(); state.selectedDay = EventCalendar.day(Date()) }.buttonStyle(.bordered).font(.fieldCaption)
                Toggle("Show ended", isOn: $state.filter.showEnded).font(.fieldCaption).toggleStyle(.button)
                Spacer()
                Text("\(c.events.events.count) curated · \(visible) of \(total) dates shown").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.timeZone = YosemiteGeo.timeZone
        f.dateFormat = "MMMM yyyy"
        return f.string(from: state.month)
    }

    private func shiftMonth(_ delta: Int) {
        state.month = EventCalendar.calendar.date(byAdding: .month, value: delta, to: state.month) ?? state.month
    }

    @ViewBuilder private func dayAgenda(_ visible: [EventOccurrence], _ c: Content) -> some View {
        let dayItems = visible.filter { $0.day == state.selectedDay }.sorted { ($0.startMinutes ?? 1441, $0.title) < ($1.startMinutes ?? 1441, $1.title) }
        FieldCard(title: dayItems.isEmpty ? "Nothing listed" : "\(dayItems.count) listing\(dayItems.count == 1 ? "" : "s")", eyebrow: DateText.long(state.selectedDay)) {
            if dayItems.isEmpty {
                Text("No curated or saved NPS listing matches this day and filter. Curated schedules are not a universal live feed; check provider calendars for anything missing.").font(.fieldCaption).foregroundStyle(.secondary)
            }
            ForEach(dayItems) { occ in
                Button { open(occ) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text(occ.timeLabel).font(.fieldCaption.weight(.semibold)).frame(width: 92, alignment: .leading).foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(occ.title).font(.fieldBody.weight(.semibold)).strikethrough(occ.ended)
                            Text("\(occ.category) · \(occ.area) · \(occ.admission)").font(.caption2).foregroundStyle(.secondary)
                            if case .nps = occ.source { Text("NPS calendar listing").font(.caption2).foregroundStyle(.tertiary) }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func open(_ occ: EventOccurrence) {
        switch occ.source {
        case .curated(let id): router.push(.event(id))
        case .nps(let id): router.push(.event("nps:\(id)"))
        }
    }

    private var npsFooter: some View {
        FieldCard(eyebrow: "NPS calendar · next 45 days") {
            if let snap = conditions.programs {
                Text("\(snap.payload.events.items.count) NPS listings saved (\(snap.payload.window.start) to \(snap.payload.window.end)); those already curated are shown once.").font(.fieldCaption)
                SnapshotFooter(snapshot: snap, staleAfter: 12 * 3600)
            } else {
                Text("No saved NPS calendar snapshot. Refresh from Trip prep with the companion server to merge live NPS listings.").font(.fieldCaption).foregroundStyle(.secondary)
            }
            if let c = content.content {
                ForEach(["calendar", "conservancyEvents", "facelift"], id: \.self) { key in
                    if let u = c.status.links[key], let url = URL(string: u) {
                        ExternalLinkRow(label: key == "calendar" ? "NPS calendar" : key == "conservancyEvents" ? "Yosemite Conservancy events" : "Yosemite Facelift", url: url)
                    }
                }
            }
        }
    }
}

struct MonthGrid: View {
    let month: Date
    @Binding var selectedDay: String
    let counts: [String: Int]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        let days = EventCalendar.gridDays(for: month)
        let monthValue = EventCalendar.calendar.component(.month, from: month)
        let today = EventCalendar.day(Date())
        VStack(spacing: 4) {
            HStack {
                ForEach(Array(EventCalendar.calendar.veryShortStandaloneWeekdaySymbols.enumerated()), id: \.offset) { _, letter in
                    Text(letter).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(days, id: \.self) { date in
                    let key = EventCalendar.day(date)
                    let inMonth = EventCalendar.calendar.component(.month, from: date) == monthValue
                    let n = counts[key] ?? 0
                    Button { selectedDay = key } label: {
                        VStack(spacing: 2) {
                            Text("\(EventCalendar.calendar.component(.day, from: date))").font(.fieldCaption.weight(key == today ? .bold : .regular))
                            if n > 0 { Text("\(n)").font(.system(size: 9, weight: .bold)).foregroundStyle(selectedDay == key ? .white : Palette.accent) } else { Text(" ").font(.system(size: 9)) }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(selectedDay == key ? Palette.accent : (key == today ? Palette.accent.opacity(0.15) : Color.secondary.opacity(0.08)), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(selectedDay == key ? Color.white : (inMonth ? Color.primary : Color.secondary))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(DateText.long(key)), \(n) listings")
                }
            }
        }
    }
}
