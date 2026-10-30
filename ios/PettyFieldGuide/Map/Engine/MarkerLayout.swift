import CoreGraphics

/// One drawn, tappable marker or cluster. Renderer, hit-testing and VoiceOver all consume the same layout.
struct PlacedMarker: Identifiable {
    let id: String
    let anchor: CGPoint            // screen point of the geographic position (pin tip / symbol centre)
    let center: CGPoint            // visual centre (pin head for teardrops)
    let radius: CGFloat
    let members: [MapMarker]       // selected first, then priority-desc, id-asc; first is the representative
    let frame: CGRect              // hit, accessibility and label-reservation footprint

    var representative: MapMarker { members[0] }
    var count: Int { members.count }
    var isCluster: Bool { members.count > 1 }
}

enum MarkerLayout {
    /// Greedy, order-independent clustering: selected first, then priority and id. Wide zooms merge by
    /// family spacing; close zooms merge only symbols that actually overlap, so coincident points stay
    /// grouped and reachable. Selected and non-clusterable markers always stand alone at their anchor.
    static func compute(_ markers: [MapMarker], camera: MapCamera, elementScale es: CGFloat, selectedId: String?) -> [PlacedMarker] {
        let visible = camera.visibleRect(margin: 48)
        let size = symbolScale(camera.scale) * es
        let candidates = markers
            .filter { visible.contains($0.point) && (camera.scale >= $0.minScale || $0.id == selectedId) }
            .sorted { a, b in
                if (a.id == selectedId) != (b.id == selectedId) { return a.id == selectedId }
                return a.priority != b.priority ? a.priority > b.priority : a.id < b.id
            }

        struct Seed { let anchor: CGPoint; var members: [MapMarker]; let family: String?; let radius: CGFloat }
        var seeds: [Seed] = []
        let close = camera.scale >= 0.45
        let spacing: CGFloat = camera.scale >= 0.35 ? 20 * size : 26 * size
        for m in candidates {
            let sp = camera.screenPoint(for: m.point)
            let radius = baseRadius(m.shape) * size
            if m.id != selectedId, let family = m.clusterFamily {
                let index = seeds.firstIndex { seed in
                    guard seed.family != nil else { return false }
                    let d = hypot(seed.anchor.x - sp.x, seed.anchor.y - sp.y)
                    if close { return d < (seed.radius + radius) * 0.75 }
                    return seed.family == family && d <= spacing
                }
                if let index {
                    seeds[index].members.append(m)
                    continue
                }
            }
            seeds.append(Seed(anchor: sp, members: [m], family: m.id == selectedId ? nil : m.clusterFamily, radius: radius))
        }

        var placed = seeds.map { seed -> PlacedMarker in
            let rep = seed.members[0]
            let selected = seed.members.contains { $0.id == selectedId }
            let boost: CGFloat = selected ? 1.2 : 1
            if seed.members.count > 1 {
                let radius = (10 + min(5, CGFloat(seed.members.count) * 0.45)) * size * boost
                let center = rep.shape == .stop ? seed.anchor : CGPoint(x: seed.anchor.x, y: seed.anchor.y - radius)
                return PlacedMarker(id: "cluster-\(rep.id)", anchor: seed.anchor, center: center, radius: radius, members: seed.members,
                                    frame: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
            let radius = seed.radius * boost
            switch rep.shape {
            case .pin, .car, .campsite:
                let center = CGPoint(x: seed.anchor.x, y: seed.anchor.y - radius * 1.55)
                return PlacedMarker(id: rep.id, anchor: seed.anchor, center: center, radius: radius, members: seed.members,
                                    frame: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2.55))
            default:
                return PlacedMarker(id: rep.id, anchor: seed.anchor, center: seed.anchor, radius: radius, members: seed.members,
                                    frame: CGRect(x: seed.anchor.x - radius, y: seed.anchor.y - radius, width: radius * 2, height: radius * 2))
            }
        }
        // Draw order: north to south so nearer pins overlap farther ones; the selection always on top.
        placed.sort { a, b in
            let sa = a.members.contains { $0.id == selectedId }, sb = b.members.contains { $0.id == selectedId }
            if sa != sb { return sb }
            return a.anchor.y != b.anchor.y ? a.anchor.y < b.anchor.y : a.id < b.id
        }
        return placed
    }

    /// Symbols shrink a little at overview zooms so the Valley is not papered over with pins.
    static func symbolScale(_ scale: CGFloat) -> CGFloat {
        scale < 0.04 ? 0.8 : scale < 0.1 ? 0.9 : 1
    }

    static func baseRadius(_ shape: MapMarker.Shape) -> CGFloat {
        switch shape {
        case .dot: 4.5
        case .site: 8.5
        case .badge: 8
        case .stop: 9
        case .user: 7
        case .pin: 11
        case .car, .campsite: 12
        }
    }

    /// Topmost item whose footprint (with a little slack) contains the point.
    static func hit(_ layout: [PlacedMarker], at point: CGPoint, slack: CGFloat) -> PlacedMarker? {
        layout.last { $0.frame.insetBy(dx: -slack, dy: -slack).contains(point) }
    }
}
