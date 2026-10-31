import Foundation

/// Crosslinks official notices to places, trails, roads and regions using the bundled name
/// patterns. Unmatched notices are kept by the screens that list everything.
enum NoticeMatcher {
    private struct Compiled {
        let id: String
        let regex: NSRegularExpression
        let area: NSRegularExpression?
        let targets: NoticeTargets
    }

    nonisolated(unsafe) private static var cache: (UUID, [Compiled])?
    /// Exactly the fields `computeTargets` reads, so any change to them misses the cache.
    private struct TargetKey: Hashable {
        let title: String
        let body: String
        let subjects: [String]
        let area: String?
    }

    nonisolated(unsafe) private static var targetCache: (UUID, [TargetKey: NoticeTargets]) = (UUID(), [:])
    nonisolated(unsafe) private static var termCache: [String: NSRegularExpression] = [:]

    private static func compiled(_ content: Content) -> [Compiled] {
        if let cache, cache.0 == content.buildId { return cache.1 }
        let list: [Compiled] = content.notices.patterns.compactMap { p in
            guard let regex = try? NSRegularExpression(pattern: p.pattern.pattern, options: p.pattern.caseInsensitive ? [.caseInsensitive] : []) else { return nil }
            let area = p.area.flatMap { try? NSRegularExpression(pattern: $0.pattern, options: $0.caseInsensitive ? [.caseInsensitive] : []) }
            return Compiled(id: p.id, regex: regex, area: area, targets: p.targets)
        }
        cache = (content.buildId, list)
        return list
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Target ids (places, trails, roads, regions) referenced by a notice; cached per content build because
    /// the hike list asks for every notice once per hike.
    static func targets(of item: NoticeItem, content: Content) -> NoticeTargets {
        let key = TargetKey(title: item.title, body: item.body, subjects: item.subjects ?? [], area: item.area)
        if targetCache.0 == content.buildId, let cached = targetCache.1[key] { return cached }
        if targetCache.0 != content.buildId { targetCache = (content.buildId, [:]) }
        let computed = computeTargets(of: item, content: content)
        targetCache.1[key] = computed
        return computed
    }

    private static func computeTargets(of item: NoticeItem, content: Content) -> NoticeTargets {
        var out = NoticeTargets(roads: [], trails: [], places: [], regions: [])
        let text = [item.title, item.body, (item.subjects ?? []).joined(separator: " ")].joined(separator: "\n")
        for c in compiled(content) {
            if let area = c.area, !matches(area, item.area ?? "") { continue }
            guard matches(c.regex, text) else { continue }
            out.roads! += c.targets.roads ?? []
            out.trails! += c.targets.trails ?? []
            out.places! += c.targets.places ?? []
            out.regions! += c.targets.regions ?? []
        }
        for ar in content.notices.areaRegions {
            if let regex = try? NSRegularExpression(pattern: ar.pattern.pattern, options: ar.pattern.caseInsensitive ? [.caseInsensitive] : []), matches(regex, item.area ?? "") {
                out.regions! += ar.regions
            }
        }
        return out
    }

    static func notices(for place: Place, content: Content, snapshot: Snapshot<ConditionsFeed>?) -> [NoticeItem] {
        guard let snapshot, !snapshot.isExpired else { return [] }
        return snapshot.payload.allItems.filter { item in
            let t = targets(of: item, content: content)
            return (t.places ?? []).contains(place.id) || (place.trailId.map { (t.trails ?? []).contains($0) } ?? false)
        }
    }

    static func notices(forTrail trailId: String, content: Content, snapshot: Snapshot<ConditionsFeed>?) -> [NoticeItem] {
        guard let snapshot, !snapshot.isExpired else { return [] }
        return snapshot.payload.allItems.filter { (targets(of: $0, content: content).trails ?? []).contains(trailId) }
    }

    static func notices(forRegion regionId: String, content: Content, snapshot: Snapshot<ConditionsFeed>?) -> [NoticeItem] {
        guard let snapshot, !snapshot.isExpired else { return [] }
        return snapshot.payload.allItems.filter { (targets(of: $0, content: content).regions ?? []).contains(regionId) }
    }

    static func notices(forRoad roadKey: String, content: Content, snapshot: Snapshot<ConditionsFeed>?) -> [NoticeItem] {
        guard let snapshot, !snapshot.isExpired else { return [] }
        return snapshot.payload.allItems.filter { (targets(of: $0, content: content).roads ?? []).contains(roadKey) }
    }

    /// Whole-word, case-insensitive match of a route name in the notice text, with curly apostrophes folded.
    static func mentions(_ item: NoticeItem, term: String) -> Bool {
        let folded = term.replacingOccurrences(of: "’", with: "'")
        guard let regex = termCache[folded] ?? (try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: folded) + "\\b", options: [.caseInsensitive])) else { return false }
        termCache[folded] = regex
        let text = [item.title, item.body, (item.subjects ?? []).joined(separator: " ")].joined(separator: "\n").replacingOccurrences(of: "’", with: "'")
        return matches(regex, text)
    }

    /// Current notices for one hike, grouped by why they apply: the hike itself (curated pattern or a route
    /// name), a road its trailhead is reached by, or only its wider region. Each notice appears once, in the
    /// most specific group. Empty when there is no unexpired snapshot.
    static func hikeNotices(_ trail: Trail, content: Content, snapshot: Snapshot<ConditionsFeed>?) -> HikeNotices {
        guard let snapshot, !snapshot.isExpired else { return HikeNotices() }
        var out = HikeNotices()
        var seen = Set<String>()
        let items = snapshot.payload.allItems
        for item in items {
            let t = targets(of: item, content: content)
            if (t.trails ?? []).contains(trail.id) || (trail.noticeTerms ?? []).contains(where: { mentions(item, term: $0) }) {
                out.hike.append(item)
                seen.insert(item.id)
            }
        }
        for road in trail.accessRoads ?? [] {
            let matched = items.filter { !seen.contains($0.id) && (targets(of: $0, content: content).roads ?? []).contains(road.key) }
            seen.formUnion(matched.map(\.id))
            if !matched.isEmpty { out.roads.append(HikeNotices.Road(road: road, items: matched)) }
        }
        if let regionId = trail.regionId {
            out.region = items.filter { !seen.contains($0.id) && (targets(of: $0, content: content).regions ?? []).contains(regionId) }
        }
        return out
    }
}

struct HikeNotices: Equatable {
    struct Road: Equatable {
        let road: AccessRoad
        let items: [NoticeItem]
    }

    var hike: [NoticeItem] = []
    var roads: [Road] = []
    var region: [NoticeItem] = []

    /// Notices naming the hike or its access roads; region-wide items are not counted on the list.
    var specificCount: Int { hike.count + roads.reduce(0) { $0 + $1.items.count } }
    var isEmpty: Bool { specificCount == 0 && region.isEmpty }
}
