import SwiftUI

/// One curated program with its published Pacific dates expanded once.
struct ProgramCatalogEntry: Identifiable, Hashable, Sendable {
    struct Session: Hashable, Sendable {
        let day: String          // yyyy-MM-dd
        let startMinutes: Int?
    }

    let event: CuratedEvent
    let sessions: [Session]      // ascending, one per published date
    let endInstant: Date?
    /// Later of the final published date and the listing's own end day; drives day-based visibility.
    let lastDay: String

    var id: String { event.id }
    var firstDay: String? { sessions.first?.day }
}

enum ProgramStatus: Hashable, Sendable {
    case upcoming(next: String)
    case inProgress(next: String?)
    case ended
}

struct ProgramCard: Identifiable, Hashable, Sendable {
    let entry: ProgramCatalogEntry
    let status: ProgramStatus

    var id: String { entry.id }
    var event: CuratedEvent { entry.event }

    var nextDay: String? {
        switch status {
        case .upcoming(let next): next
        case .inProgress(let next): next
        case .ended: nil
        }
    }

    var badgeDay: String { nextDay ?? entry.lastDay }

    func statusLabel(today: String) -> String {
        switch status {
        case .ended: "Ended \(DateText.long(event.end))"
        case .upcoming(let next): "Next \(DateText.long(next))"
        case .inProgress(let next?): next == today ? "Today" : "Under way · next \(DateText.long(next))"
        case .inProgress(nil): "Under way today"
        }
    }
}

struct ProgramCatalogResult: Sendable {
    let visible: [ProgramCard]
    let hiddenEnded: Int
}

enum ProgramCatalog {
    static func entries(for events: [CuratedEvent]) -> [ProgramCatalogEntry] {
        events.map { event in
            let sessions = EventCalendar.occurrences(of: event)
                .map { ProgramCatalogEntry.Session(day: $0.day, startMinutes: $0.startMinutes) }
                .sorted { ($0.day, $0.startMinutes ?? -1) < ($1.day, $1.startMinutes ?? -1) }
            let endInstant = DateText.parse(event.end)
            let lastDay = [sessions.last?.day, endInstant.map(EventCalendar.day)].compactMap { $0 }.max() ?? ""
            return ProgramCatalogEntry(event: event, sessions: sessions, endInstant: endInstant, lastDay: lastDay)
        }
    }

    /// Clock-based status in Pacific time. A session counts as next until its published start minute has passed.
    static func status(of entry: ProgramCatalogEntry, now: Date) -> ProgramStatus {
        let today = EventCalendar.day(now)
        if let end = entry.endInstant {
            if end <= now { return .ended }
        } else if entry.lastDay < today {
            return .ended
        }
        if let first = entry.firstDay, first > today { return .upcoming(next: first) }
        let parts = EventCalendar.calendar.dateComponents([.hour, .minute], from: now)
        let nowMinutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let next = entry.sessions.first { s in s.day > today || (s.day == today && (s.startMinutes.map { $0 > nowMinutes } ?? true)) }
        return .inProgress(next: next?.day)
    }

    /// Shared title/region/cost/custom rules apply unchanged; only the ended rule differs from the calendar.
    /// Programs that ended earlier today stay visible for today's civil date; only those whose last published
    /// date is before today are hidden by the ended toggle.
    static func cards(from entries: [ProgramCatalogEntry], filter: EventFilter, custom: [CustomEventCategory], now: Date) -> ProgramCatalogResult {
        let today = EventCalendar.day(now)
        var unrestricted = filter
        unrestricted.showEnded = true
        unrestricted.includeNPS = true
        var visible: [ProgramCard] = []
        var hidden = 0
        for entry in entries where matches(entry, filter: unrestricted, custom: custom) {
            if !filter.showEnded && entry.lastDay < today {
                hidden += 1
                continue
            }
            visible.append(ProgramCard(entry: entry, status: status(of: entry, now: now)))
        }
        return ProgramCatalogResult(visible: visible.sorted(by: precedes), hiddenEnded: hidden)
    }

    private static func matches(_ entry: ProgramCatalogEntry, filter: EventFilter, custom: [CustomEventCategory]) -> Bool {
        let e = entry.event
        let probe = EventOccurrence(source: .curated(e.id), day: entry.firstDay ?? entry.lastDay, startMinutes: nil, timeLabel: "", title: e.title,
                                    category: e.category, area: e.area, admission: e.admission, regionId: nil, ended: false)
        return EventCalendar.matches(probe, filter: filter, custom: custom)
    }

    /// Live programs by next date (under way today first), then ended ones newest first; title and id break ties.
    static func precedes(_ a: ProgramCard, _ b: ProgramCard) -> Bool {
        switch (a.status, b.status) {
        case (.ended, .ended):
            if a.entry.lastDay != b.entry.lastDay { return a.entry.lastDay > b.entry.lastDay }
        case (.ended, _): return false
        case (_, .ended): return true
        default:
            let an = a.nextDay ?? "", bn = b.nextDay ?? ""
            if an != bn { return an < bn }
        }
        if a.event.title != b.event.title { return a.event.title.localizedCaseInsensitiveCompare(b.event.title) == .orderedAscending }
        return a.id < b.id
    }
}

// MARK: - Views

/// Embeds inside `EventsScreen`'s scroll in Programs mode; occurrences expand once per content load.
struct ProgramCatalogView: View {
    let content: Content
    let filter: EventFilter
    let customCategories: [CustomEventCategory]
    var now = Date()
    @EnvironmentObject private var router: AppRouter
    @State private var entries: [ProgramCatalogEntry] = []
    @State private var builtFor: UUID?

    var body: some View {
        let ready = builtFor == content.buildId
        let result = ProgramCatalog.cards(from: entries, filter: filter, custom: customCategories, now: now)
        let today = EventCalendar.day(now)
        VStack(alignment: .leading, spacing: 14) {
            FieldCard(title: "Explore the programs", eyebrow: "Curated listings · next published date first") {
                if ready {
                    Text("\(result.visible.count) program\(result.visible.count == 1 ? "" : "s") match the current filters.").font(.fieldCaption)
                    if result.hiddenEnded > 0 {
                        Text("\(result.hiddenEnded) ended before today and are hidden; turn on Show ended to include them.").font(.fieldCaption).foregroundStyle(.secondary)
                    }
                    Text("Dates are the ones each host published. No season is assumed to repeat, and listing a program says nothing about availability.").font(.caption2).foregroundStyle(.tertiary)
                } else {
                    ProgressView("Preparing programs…").frame(maxWidth: .infinity)
                }
            }
            if ready {
                if result.visible.isEmpty {
                    EmptyStateView(symbol: "calendar.badge.exclamationmark", title: "No programs match",
                                   message: filter.showEnded ? "Nothing in the curated list fits these filters." : "Nothing current fits these filters. Turn on Show ended or clear a filter to see more.")
                        .accessibilityElement(children: .combine)
                } else {
                    ForEach(result.visible) { card in
                        ProgramCardView(card: card, today: today) { router.push(.event(card.id)) }
                    }
                }
            }
        }
        .task(id: content.buildId) {
            let events = content.events.events
            entries = await Task.detached { ProgramCatalog.entries(for: events) }.value
            builtFor = content.buildId
        }
    }
}

struct ProgramCardView: View {
    let card: ProgramCard
    let today: String
    let open: () -> Void

    private var cost: String { card.event.admissionLabel ?? card.event.admission }
    private var statusText: String { card.statusLabel(today: today) }
    private var ended: Bool { card.status == .ended }

    var body: some View {
        Button(action: open) {
            FieldCard {
                HStack(alignment: .top, spacing: 12) {
                    ProgramDateBadge(day: card.badgeDay, muted: ended)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(card.event.category) · \(cost)").font(.fieldEyebrow).foregroundStyle(.secondary)
                        Text(card.event.title).font(.fieldBody.weight(.semibold)).multilineTextAlignment(.leading).strikethrough(ended)
                        Text(card.event.summary).font(.fieldCaption).lineLimit(3).multilineTextAlignment(.leading)
                        Text(card.event.area).font(.caption2).foregroundStyle(.secondary)
                        Text(statusText).font(.fieldCaption.weight(.semibold)).foregroundStyle(ended ? Palette.ember : Palette.accent)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(card.event.title). \(statusText). \(card.event.category), \(cost), \(card.event.area).")
        .accessibilityHint("Opens the full listing with location, booking and sources")
    }
}

struct ProgramDateBadge: View {
    let day: String
    let muted: Bool

    var body: some View {
        let date = EventCalendar.date(day)
        let month = date.map { EventCalendar.calendar.shortMonthSymbols[EventCalendar.calendar.component(.month, from: $0) - 1] } ?? "—"
        let number = date.map { String(EventCalendar.calendar.component(.day, from: $0)) } ?? "—"
        VStack(spacing: 0) {
            Text(month).font(.caption2.weight(.bold)).textCase(.uppercase)
            Text(number).font(.title3.weight(.bold))
        }
        .frame(width: 48)
        .padding(.vertical, 6)
        .foregroundStyle(muted ? Color.secondary : Color.primary)
        .background(muted ? Color.secondary.opacity(0.15) : Palette.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
}
