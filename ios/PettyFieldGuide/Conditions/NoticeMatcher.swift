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

    /// Target ids (places, trails, roads, regions) referenced by a notice.
    static func targets(of item: NoticeItem, content: Content) -> NoticeTargets {
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
}
