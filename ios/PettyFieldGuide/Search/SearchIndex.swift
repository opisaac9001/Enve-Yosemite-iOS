import Foundation

struct SearchHit: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case place, saved, contact, campsite, region, trail, permit, event, document, webcam, topic

        var title: String {
            switch self {
            case .place: "Places"
            case .saved: "Saved"
            case .contact: "Contacts"
            case .campsite: "Campsites"
            case .region: "Regions"
            case .trail: "Trails"
            case .permit: "Permits"
            case .event: "Events"
            case .document: "Documents"
            case .webcam: "Webcams"
            case .topic: "Topics"
            }
        }
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let route: Route?
    let mapFocus: MapFocus?
    let mapTool: MapTool?
    let sheet: AppSheet?
    let section: AppSection?
    let tokens: [String]          // normalised words
    let phrase: String            // normalised full text for phrase matching
    let phoneDigits: String?
    let siteNumber: String?       // "18" for Upper Pines site 18, "179" for Housekeeping unit 179
    let siteScope: String?        // campground id or "housekeeping"
    let priority: Int

    static func == (lhs: SearchHit, rhs: SearchHit) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Tokenised in-memory index; built once per content load.
final class SearchIndex: Sendable {
    nonisolated(unsafe) private static var cache: (UUID, SearchIndex)?
    private static let lock = NSLock()

    let hits: [SearchHit]
    private let campgroundAliases: [(alias: String, id: String)]

    static func shared(for content: Content) -> SearchIndex {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache, cached.0 == content.buildId { return cached.1 }
        let index = SearchIndex(content: content)
        cache = (content.buildId, index)
        return index
    }

    init(content: Content) {
        var hits: [SearchHit] = []
        func add(_ id: String, _ kind: SearchHit.Kind, _ title: String, _ subtitle: String, route: Route?, map: MapFocus? = nil, tool: MapTool? = nil, sheet: AppSheet? = nil, section: AppSection? = nil,
                 extra: [String] = [], phone: String? = nil, site: String? = nil, scope: String? = nil, priority: Int = 1) {
            let text = ([title, subtitle] + extra).joined(separator: " ")
            hits.append(SearchHit(id: id, kind: kind, title: title, subtitle: subtitle, route: route, mapFocus: map, mapTool: tool, sheet: sheet, section: section,
                                  tokens: SearchIndex.tokens(text), phrase: SearchIndex.normalise(text), phoneDigits: phone, siteNumber: site, siteScope: scope, priority: priority))
        }
        for p in content.places {
            let kind: SearchHit.Kind = p.kind == .housekeepingUnit ? .campsite : .place
            let extra = p.tags + p.hours + (p.details.map(\.text)) + p.phones.map(\.number) + [p.summary]
            add("place-\(p.id)", kind, p.name, p.campus, route: .place(p.id), map: .place(p.id), extra: extra,
                phone: p.phones.first.map { PhoneFormat.digits($0.number) }, site: p.unitNumber, scope: p.unitNumber != nil ? "housekeeping" : nil,
                priority: p.listed ? p.mapPriority : 0)
        }
        for c in content.contacts.contacts {
            for n in c.numbers {
                add("contact-\(c.id)-\(n.number)", .contact, c.name, "\(n.label) · \(n.number)", route: .contact(c.id), section: .contacts,
                    extra: [c.reaches] + c.hours + c.location, phone: PhoneFormat.digits(n.number), priority: 3)
            }
        }
        for site in content.campsites {
            guard let cg = content.campgrounds.campgrounds.first(where: { $0.id == site.campground }) else { continue }
            let route: Route = .site(campground: cg.id, ridbId: site.ridbId)
            let map: MapFocus? = cg.isValley ? .site(campground: cg.id, ridbId: site.ridbId) : nil
            add("site-\(site.ridbId)", .campsite, "\(cg.name) · site \(site.displayNumber)", "\(site.typeTitle)\(site.loop.map { " · loop \($0)" } ?? "")\(site.accessible ? " · accessible" : "") · inventory point, availability unknown",
                route: route, map: map, section: .trails, extra: [cg.area, site.site], site: site.displayNumber, scope: cg.id, priority: 1)
        }
        for cg in content.campgrounds.campgrounds {
            add("campground-\(cg.id)", .campsite, "\(cg.name) Campground", "\(cg.area) · \(cg.sites) sites · \(cg.season)", route: .campground(cg.id), section: .trails,
                extra: cg.notes + [cg.reservation, cg.rvLimit, cg.water], priority: 6)
        }
        for r in content.regions.regions {
            add("region-\(r.id)", .region, r.name, r.tagline, route: .region(r.id), section: .park, extra: r.highlights + r.services + r.points.map(\.name), priority: 5)
        }
        for t in content.trails.trails {
            add("trail-\(t.id)", .trail, t.name, "\(t.difficulty) · \(t.start)", route: .trail(t.id), map: .trail(t.id), section: .trails, extra: t.notes + [t.summary] + t.gisNames, priority: 6)
        }
        for g in content.permits.guides {
            add("permit-\(g.id)", .permit, g.title, g.plan, route: .permit(g.id), section: .permits, extra: g.keywords + [g.summary] + g.facts.map(\.text), priority: 5)
        }
        for e in content.events.events {
            add("event-\(e.id)", .event, e.title, "\(e.dateLabel) · \(e.area)", route: .event(e.id), map: e.placeId.map { .place($0) }, section: .events,
                extra: [e.summary, e.location, e.host, e.category, e.cost], priority: 2)
        }
        for d in content.documents {
            add("document-\(d.id)", .document, d.title, d.edition, route: .document(d.id), section: .documents, extra: [d.description, d.category, d.note], priority: 4)
        }
        for w in content.webcams.webcams {
            add("webcam-\(w.id)", .webcam, "\(w.name) webcam", w.shows, route: .webcam(w.id), section: .status, extra: [w.credit, w.origin ?? ""], priority: 3)
        }
        for topic in SearchTopic.all {
            add("topic-\(topic.id)", .topic, topic.title, topic.subtitle, route: topic.route, tool: topic.mapTool, sheet: topic.sheet, section: topic.section, extra: topic.keywords, priority: 4)
        }
        self.hits = hits
        campgroundAliases = content.campgrounds.campgrounds.flatMap { cg in
            [(SearchIndex.normalise(cg.name), cg.id), (SearchIndex.normalise(cg.name.replacingOccurrences(of: " Campground", with: "")), cg.id)]
        } + [("housekeeping", "housekeeping"), ("housekeeping camp", "housekeeping")]
    }

    // MARK: Matching

    static func normalise(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
            .lowercased()
    }

    static func tokens(_ s: String) -> [String] {
        normalise(s).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static let sitePattern = try! NSRegularExpression(pattern: #"\b(?:site|unit|campsite|space)\s*#?\s*(\d{1,4})\b"#, options: .caseInsensitive)

    struct Query {
        var raw: String
        var tokens: [String]
        var phrase: String
        var digits: String
        var siteNumber: String?
        var siteScope: String?
    }

    func parse(_ raw: String) -> Query {
        let normalised = Self.normalise(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        var siteNumber: String?
        var scope: String?
        if let m = Self.sitePattern.firstMatch(in: normalised, range: NSRange(normalised.startIndex..., in: normalised)), let r = Range(m.range(at: 1), in: normalised) {
            siteNumber = String(Int(normalised[r]) ?? 0)
            for alias in campgroundAliases.sorted(by: { $0.alias.count > $1.alias.count }) where normalised.contains(alias.alias) {
                scope = alias.id
                break
            }
        }
        let digits = raw.filter(\.isNumber)
        return Query(raw: raw, tokens: Self.tokens(raw), phrase: normalised, digits: digits, siteNumber: siteNumber, siteScope: scope)
    }

    func search(_ raw: String, kinds: Set<SearchHit.Kind>? = nil, savedIds: Set<String> = [], limit: Int = 60) -> [SearchHit] {
        let q = parse(raw)
        guard !q.tokens.isEmpty || q.digits.count >= 3 else { return [] }
        var scored: [(SearchHit, Int)] = []
        for hit in hits {
            if let kinds, !kinds.contains(hit.kind) && !(kinds.contains(.saved) && savedIds.contains(placeId(of: hit) ?? "")) { continue }
            var score = 0
            if let number = q.siteNumber, hit.siteNumber == number {
                if q.siteScope == nil || hit.siteScope == q.siteScope { score += 400 } else { score += 40 }
            } else if q.siteNumber != nil && hit.kind == .campsite && hit.siteScope != nil && q.siteScope != nil && hit.siteScope != q.siteScope {
                continue
            }
            if q.digits.count >= 3, let phone = hit.phoneDigits, phone.contains(q.digits) { score += 300 }
            if !q.phrase.isEmpty && hit.phrase.contains(q.phrase) { score += 120 }
            let titleTokens = Set(Self.tokens(hit.title))
            var matched = 0
            for token in q.tokens {
                if titleTokens.contains(token) { score += 60; matched += 1 }
                else if titleTokens.contains(where: { $0.hasPrefix(token) }) { score += 35; matched += 1 }
                else if hit.tokens.contains(token) { score += 18; matched += 1 }
                else if token.count >= 3 && hit.tokens.contains(where: { $0.hasPrefix(token) }) { score += 8; matched += 1 }
            }
            if matched == 0 && score == 0 { continue }
            if matched < q.tokens.count && q.tokens.count > 1 && score < 100 {
                // Require most tokens to match for multi-word queries.
                if matched * 2 < q.tokens.count { continue }
                score -= 20 * (q.tokens.count - matched)
            }
            if savedIds.contains(placeId(of: hit) ?? "") { score += 15 }
            score += hit.priority
            scored.append((hit, score))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    func placeId(of hit: SearchHit) -> String? {
        if case .place(let id)? = hit.route { return id }
        return nil
    }

    /// The best map target for a free-text query, used by the map search field.
    func placeOrSite(matching raw: String) -> MapFocus? {
        search(raw, limit: 5).first { $0.mapFocus != nil }?.mapFocus
    }
}

extension SearchIndex {
    func places(matching raw: String, limit: Int, content: Content) -> [Place] {
        search(raw, kinds: [.place, .campsite], limit: limit).compactMap { hit in
            if case .place(let id)? = hit.route { return content.place(id) }
            return nil
        }
    }
}

/// Planning topics and feature entry points that are searchable like the reference's guide topics.
struct SearchTopic {
    let id: String
    let title: String
    let subtitle: String
    var route: Route? = nil
    var mapTool: MapTool? = nil
    var sheet: AppSheet? = nil
    let section: AppSection
    let keywords: [String]

    static let all: [SearchTopic] = [
        SearchTopic(id: "planner", title: "Shuttle trip planner", subtitle: "Earliest scheduled arrival between stops", route: .planner, section: .navigation, keywords: ["bus", "timetable", "departure", "arrival", "transfer", "route"]),
        SearchTopic(id: "water", title: "Water & ice guide", subtitle: "Every tap, bottle filler and ice machine with directions and sources", sheet: .waterIceGuide, section: .directory, keywords: ["water", "drinking", "faucet", "tap", "bottle", "filler", "ice", "refill", "spigot"]),
        SearchTopic(id: "parked-car", title: "Parked car", subtitle: "Pin where you parked, with a private note", mapTool: .parkedCar, section: .map, keywords: ["car", "parking", "parked", "vehicle", "pin", "where did i park"]),
        SearchTopic(id: "weather", title: "Weather & daylight", subtitle: "Forecast points, UV, air, sunrise and sunset", section: .status, keywords: ["forecast", "temperature", "rain", "snow", "wind", "sunrise", "sunset", "uv", "air quality", "aqi"]),
        SearchTopic(id: "fire", title: "Fire & smoke desk", subtitle: "Perimeters, satellite heat, smoke plumes, air monitors", section: .fire, keywords: ["wildfire", "smoke", "restrictions", "campfire", "aqi", "hotspots"]),
        SearchTopic(id: "risks", title: "Seasonal risks", subtitle: "Month-by-month checks with live inputs", section: .risks, keywords: ["chains", "river", "flood", "mosquito", "tick", "heat", "visibility", "snow"]),
        SearchTopic(id: "packs", title: "Offline packs & trip prep", subtitle: "Base pack status, conditions snapshots, backups", section: .trip, keywords: ["offline", "download", "backup", "restore", "airplane mode", "storage"]),
        SearchTopic(id: "sun", title: "Sun & terrain shadow", subtitle: "Solar position and terrain occlusion preview", mapTool: .sunPreview, section: .map, keywords: ["shadow", "sunlight", "solar", "azimuth", "altitude"]),
        SearchTopic(id: "layers", title: "Map layers", subtitle: "Shuttle routes, contours, building names, smoke plumes", mapTool: .layers, section: .map, keywords: ["contours", "buildings", "smoke", "routes", "labels"]),
        SearchTopic(id: "roads", title: "Road status & chain controls", subtitle: "NPS road table, Caltrans chain signs, alerts", section: .park, keywords: ["tioga", "glacier point road", "closed", "chains", "caltrans", "highway 41", "highway 120", "highway 140"]),
        SearchTopic(id: "emergency", title: "Emergency & roadside", subtitle: "911, park dispatch, roadside assistance, fuel", section: .contacts, keywords: ["911", "emergency", "tow", "gas", "fuel", "help"]),
    ]
}
