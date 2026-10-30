import Foundation

/// One dated occurrence of a curated or NPS event, in Pacific civil time.
struct EventOccurrence: Identifiable, Hashable, Sendable {
    enum Source: Hashable, Sendable { case curated(String), nps(String) }
    let source: Source
    let day: String               // yyyy-MM-dd
    let startMinutes: Int?
    let timeLabel: String
    let title: String
    let category: String
    let area: String
    let admission: String
    let regionId: String?
    let ended: Bool

    /// One row per published session: sessions of a program on the same day keep distinct ids.
    var id: String {
        let slot = Self.slotKey(startMinutes: startMinutes, timeLabel: timeLabel)
        switch source {
        case .curated(let id): return "c-\(id)-\(day)-\(slot)"
        case .nps(let id): return "n-\(id)-\(day)-\(slot)"
        }
    }

    /// Full published identity of a session's time: start minute and label together, so two
    /// records at the same minute with different published details stay distinct.
    static func slotKey(startMinutes: Int?, timeLabel: String) -> String {
        "\(startMinutes.map(String.init) ?? "-")|\(timeLabel)"
    }
}

/// Filter state; encodable so saved views and deep links can carry it.
struct EventFilter: Codable, Equatable, Sendable {
    var regions: [String] = []
    var categories: [String] = []
    var costs: [String] = []
    var includeTitles: [String] = []
    var excludeTitles: [String] = []
    var customCategories: [String] = []
    var showEnded = false
    var includeNPS = true

    var isEmpty: Bool { regions.isEmpty && categories.isEmpty && costs.isEmpty && includeTitles.isEmpty && excludeTitles.isEmpty && customCategories.isEmpty && !showEnded && includeNPS }

    func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ s: String) -> EventFilter? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard b64.count <= 16000, let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONDecoder().decode(EventFilter.self, from: data)
    }
}

/// A user-defined grouping of events by title keywords, stored on device.
struct CustomEventCategory: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var keywords: [String]
}

enum EventCalendar {
    static let calendar = YosemiteGeo.calendar

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = YosemiteGeo.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ day: String) -> Date? { dayFormatter.date(from: day) }
    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// Expands curated rules into dated occurrences. `weekdays` use 0 = Sunday. Exclusions apply to
    /// explicit dates as well as recurrences. Rules that publish different sessions on the same day
    /// each keep their row; only an exact repeat of day, start minute and label collapses.
    static func occurrences(of event: CuratedEvent, now: Date = Date()) -> [EventOccurrence] {
        var sessions: [(String, EventRule)] = []
        for rule in event.rules {
            let excluded = Set(rule.excluded ?? [])
            if let explicit = rule.dates, !explicit.isEmpty {
                for d in explicit where d >= rule.from && d <= rule.through && !excluded.contains(d) { sessions.append((d, rule)) }
                continue
            }
            guard var cursor = date(rule.from), let end = date(rule.through) else { continue }
            var guardCount = 0
            while cursor <= end && guardCount < 800 {
                let weekday = calendar.component(.weekday, from: cursor) - 1
                let key = day(cursor)
                if rule.weekdays.contains(weekday) && !excluded.contains(key) { sessions.append((key, rule)) }
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? end.addingTimeInterval(1)
                guardCount += 1
            }
        }
        let ended = DateText.parse(event.end).map { $0 < now } ?? false
        var seen = Set<String>()
        return sessions
            .sorted { ($0.0, $0.1.minutes ?? -1, $0.1.time) < ($1.0, $1.1.minutes ?? -1, $1.1.time) }
            .compactMap { (d, rule) in
                guard seen.insert("\(d)|\(EventOccurrence.slotKey(startMinutes: rule.minutes, timeLabel: rule.time))").inserted else { return nil }
                return EventOccurrence(source: .curated(event.id), day: d, startMinutes: rule.minutes, timeLabel: rule.time, title: event.title,
                                       category: event.category, area: event.area, admission: event.admission, regionId: nil, ended: ended)
            }
    }

    /// NPS calendar listings (next 45 days) not already represented by a curated program.
    static func occurrences(ofNPS item: NPSEvent, mapping: [NPSEventMapping], areaRegions: [String: String], now: Date = Date()) -> [EventOccurrence] {
        guard !mapping.contains(where: { $0.npsId == item.id }) else { return [] }
        let cancelled = Set(item.cancelledDates ?? [])
        let firstTime = item.times.first
        let timeLabel: String = {
            if item.allDay == true { return "All day" }
            if let t = firstTime, let s = t.start { return t.end.map { "\(s)–\($0)" } ?? s }
            return item.timeInfo ?? "Time not published"
        }()
        let area = areaOf(item)
        let region = areaRegions[area]
        let admission = item.isFree == true ? "free" : (item.isFree == false ? "paid" : "unknown")
        return item.dates.filter { !cancelled.contains($0) }.map { d in
            EventOccurrence(source: .nps(item.id), day: d, startMinutes: firstTime?.startMinutes, timeLabel: timeLabel, title: item.title,
                            category: item.types.first ?? "NPS program", area: area, admission: admission, regionId: region,
                            ended: (date(d).map { calendar.date(byAdding: .day, value: 1, to: $0) ?? $0 } ?? now) < now)
        }
    }

    static func areaOf(_ item: NPSEvent) -> String {
        if let open = item.title.lastIndex(of: "("), let close = item.title.lastIndex(of: ")"), open < close {
            return String(item.title[item.title.index(after: open)..<close])
        }
        return item.location ?? "Yosemite"
    }

    /// Day visibility is separate from clock status: a listing that ended earlier today stays on today's
    /// Pacific date (struck through); only its earlier days hide when "show ended" is off.
    static func matches(_ occ: EventOccurrence, filter: EventFilter, custom: [CustomEventCategory], today: String = EventCalendar.day(Date())) -> Bool {
        if !filter.showEnded && occ.ended && occ.day < today { return false }
        if case .nps = occ.source, !filter.includeNPS { return false }
        if !filter.regions.isEmpty && !filter.regions.contains(occ.area) { return false }
        if !filter.categories.isEmpty && !filter.categories.contains(occ.category) { return false }
        if !filter.costs.isEmpty && !filter.costs.contains(occ.admission) { return false }
        let title = SearchIndex.normalise(occ.title)
        if !filter.includeTitles.isEmpty && !filter.includeTitles.contains(where: { title.contains(SearchIndex.normalise($0)) }) { return false }
        if filter.excludeTitles.contains(where: { !$0.isEmpty && title.contains(SearchIndex.normalise($0)) }) { return false }
        if !filter.customCategories.isEmpty {
            let active = custom.filter { filter.customCategories.contains($0.id) }
            if !active.contains(where: { $0.keywords.contains { title.contains(SearchIndex.normalise($0)) } }) { return false }
        }
        return true
    }

    /// Month grid days (6 weeks) starting on Sunday, in Pacific time.
    static func gridDays(for month: Date) -> [Date] {
        let comps = calendar.dateComponents([.year, .month], from: month)
        guard let first = calendar.date(from: comps) else { return [] }
        let weekday = calendar.component(.weekday, from: first) - 1
        guard let start = calendar.date(byAdding: .day, value: -weekday, to: first) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}
