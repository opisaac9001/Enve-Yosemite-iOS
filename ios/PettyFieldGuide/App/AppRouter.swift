import SwiftUI
import Combine

enum Route: Hashable, Codable {
    case place(String)
    case trail(String)
    /// A hike opened on one of its published route variants.
    case hikeRoute(trailId: String, routeId: String)
    case campground(String)
    case site(campground: String, ridbId: String)
    case housekeepingUnit(String)
    case event(String)
    case permit(String)
    case contact(String)
    case document(String)
    case region(String)
    case stop(Int)
    case webcam(String)
    case explorerLayer(String)
    case riskCheck(String)
    case fireIncident(String)
    case planner
}

enum MapTool: Hashable {
    case sunPreview
    case layers
    case parkedCar
}

enum AppSheet: Identifiable, Hashable {
    case settings
    case updates
    case changelog
    case suggestions
    case introGuide
    case backup
    case waterIceGuide
    case share(SharePayload)

    var id: String {
        switch self {
        case .settings: "settings"
        case .updates: "updates"
        case .changelog: "changelog"
        case .suggestions: "suggestions"
        case .introGuide: "intro"
        case .backup: "backup"
        case .waterIceGuide: "water-ice"
        case .share(let link): "share-\(link.url.absoluteString)"
        }
    }

    /// Deep-link host for sheets that can be opened by URL; nil for the rest.
    var linkHost: String? {
        switch self {
        case .updates: "updates"
        case .changelog: "changelog"
        case .suggestions: "suggestions"
        case .waterIceGuide: "water"
        default: nil
        }
    }
}

struct SharePayload: Hashable {
    let title: String
    let url: URL
}

/// What the map should focus when it next appears.
enum MapFocus: Hashable {
    case place(String)
    case site(campground: String, ridbId: String)
    case coordinate(latitude: Double, longitude: Double, label: String)
    case trail(String)
    case hikeRoute(String)
    /// Frames a park region's guide points and trailheads.
    case region(String)
    /// Frames the whole park.
    case park
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var section: AppSection = .map
    /// Intended navigation path per section; `pathBinding` hands it to a section's stack only once that stack is on screen.
    @Published var paths: [AppSection: [Route]] = [:]
    @Published var sheet: AppSheet?
    @Published var mapFocus: MapFocus?
    @Published var pendingMapTool: MapTool?
    @Published var pendingEventFilter: String?
    /// One `NavigationStack` instance; a stack re-created for the same section gets a new instance.
    struct StackIdentity: Equatable {
        let section: AppSection
        let instance: UUID
    }

    /// The stack currently on screen (`SectionStack` reports it); only it reads and writes its section's path.
    @Published private(set) var mountedStack: StackIdentity?
    var mountedSection: AppSection? { mountedStack?.section }

    // A NavigationStack drops a path it is created with or written before it is on screen, so only the mounted stack sees paths.
    func pathBinding(for stack: StackIdentity) -> Binding<[Route]> {
        Binding(get: { self.mountedStack == stack ? (self.paths[stack.section] ?? []) : [] },
                set: { if self.mountedStack == stack { self.paths[stack.section] = $0 } })
    }

    /// Mounting supersedes the previous stack; nothing reports unmounting, because in a split-view column
    /// the stack's `onDisappear` fires behind its own pushes and would pop them.
    func stackDidMount(_ stack: StackIdentity) {
        guard mountedStack != stack else { return }
        if (paths[stack.section] ?? []).isEmpty || pendingPushAnimations.remove(stack.section) != nil {
            mountedStack = stack
        } else {
            // Restored history should be in place when the section returns, not pushed screen by screen.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { mountedStack = stack }
        }
    }

    private var pendingPushAnimations: Set<AppSection> = []

    func show(_ section: AppSection) {
        self.section = section
    }

    func push(_ route: Route, in section: AppSection? = nil) {
        let target = section ?? self.section
        if mountedSection != target { pendingPushAnimations.insert(target) }
        self.section = target
        paths[target, default: []].append(route)
    }

    func showOnMap(_ focus: MapFocus) {
        mapFocus = focus
        section = .map
    }

    func openMapTool(_ tool: MapTool) {
        pendingMapTool = tool
        section = .map
    }

    // MARK: Deep links

    static let scheme = "enveyosemite"
    /// Scheme of links shared before the Enve Yosemite rename; still accepted, never emitted.
    static let legacyScheme = "pettyfieldguide"

    /// `enveyosemite://<host>/<id…>`; every URL this produces is handled by `open(url:)`.
    static func url(for route: Route) -> URL? {
        var parts: [String]
        switch route {
        case .place(let id): parts = ["place", id]
        case .trail(let id): parts = ["trail", id]
        case .hikeRoute(let trailId, let routeId): parts = ["trail", trailId, routeId]
        case .campground(let id): parts = ["campground", id]
        case .site(let cg, let ridb): parts = ["site", cg, ridb]
        case .housekeepingUnit(let unit): parts = ["housekeeping", unit]
        case .event(let id): parts = ["event", id]
        case .permit(let id): parts = ["permit", id]
        case .contact(let id): parts = ["contact", id]
        case .document(let id): parts = ["document", id]
        case .region(let id): parts = ["region", id]
        case .stop(let n): parts = ["stop", String(n)]
        case .webcam(let id): parts = ["webcam", id]
        case .explorerLayer(let id): parts = ["layer", id]
        case .riskCheck(let id): parts = ["risk", id]
        case .fireIncident(let id): parts = ["incident", id]
        case .planner: parts = ["planner"]
        }
        let path = parts.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }.joined(separator: "/")
        return URL(string: "\(scheme)://\(path)")
    }

    static func url(for tool: MapTool) -> URL? {
        switch tool {
        case .sunPreview: URL(string: "\(scheme)://sun")
        case .layers: URL(string: "\(scheme)://layers")
        case .parkedCar: URL(string: "\(scheme)://car")
        }
    }

    static func url(for sheet: AppSheet) -> URL? {
        sheet.linkHost.flatMap { URL(string: "\(scheme)://\($0)") }
    }

    static func url(for section: AppSection) -> URL? {
        URL(string: "\(scheme)://section/\(section.rawValue)")
    }

    static func eventFilterURL(encoded: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "events"
        components.queryItems = [URLQueryItem(name: "filter", value: encoded)]
        return components.url
    }

    func open(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == Self.scheme || scheme == Self.legacyScheme else { return }
        let host = url.host ?? ""
        let rest = url.pathComponents.filter { $0 != "/" }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch host {
        case "place":
            guard let id = rest.first else { return }
            showOnMap(.place(id))
        case "site":
            guard rest.count == 2 else { return }
            showOnMap(.site(campground: rest[0], ridbId: rest[1]))
        case "housekeeping":
            guard let unit = rest.first else { return }
            showOnMap(.place("housekeeping-unit-\(unit)"))
        case "trail":
            guard let id = rest.first else { return }
            if rest.count >= 2 { push(.hikeRoute(trailId: id, routeId: rest[1]), in: .trails) } else { push(.trail(id), in: .trails) }
        case "campground":
            guard let id = rest.first else { return }
            push(.campground(id), in: .trails)
        case "event":
            guard let id = rest.first else { return }
            push(.event(id), in: .events)
        case "events":
            pendingEventFilter = components?.queryItems?.first(where: { $0.name == "filter" })?.value
            show(.events)
        case "permit":
            guard let id = rest.first else { return }
            push(.permit(id), in: .permits)
        case "contact":
            guard let id = rest.first else { return }
            push(.contact(id), in: .contacts)
        case "document":
            guard let id = rest.first else { return }
            push(.document(id), in: .documents)
        case "region":
            guard let id = rest.first else { return }
            push(.region(id), in: .park)
        case "stop":
            guard let n = rest.first.flatMap(Int.init) else { return }
            push(.stop(n), in: .navigation)
        case "webcam":
            guard let id = rest.first else { return }
            push(.webcam(id), in: .status)
        case "layer":
            guard let id = rest.first else { return }
            push(.explorerLayer(id), in: .trip)
        case "risk":
            guard let id = rest.first else { return }
            push(.riskCheck(id), in: .risks)
        case "incident":
            guard let id = rest.first else { return }
            push(.fireIncident(id), in: .fire)
        case "planner": push(.planner, in: .navigation)
        case "sun": openMapTool(.sunPreview)
        case "layers": openMapTool(.layers)
        case "car": openMapTool(.parkedCar)
        case "water": sheet = .waterIceGuide
        case "section":
            guard let s = rest.first.flatMap(AppSection.init(rawValue:)) else { return }
            show(s)
        case "updates": sheet = .updates
        case "changelog": sheet = .changelog
        case "suggestions": sheet = .suggestions
        default: break
        }
    }
}
