import Foundation
import Combine

/// Everything bundled with the app, decoded once at launch off the main actor.
struct Content: Sendable {
    let buildId = UUID()
    var places: [Place]
    var placesById: [String: Place]
    var trails: TrailsPack
    var campgrounds: CampgroundsPack
    var campsites: [Campsite]
    var permits: PermitsPack
    var contacts: ContactsPack
    var events: EventsPack
    var regions: RegionsPack
    var webcams: WebcamsPack
    var documents: [DocumentItem]
    var status: StatusPack
    var categories: CategoriesPack
    var notices: NoticesPack
    var changelog: [ChangelogEntry]
    var housekeeping: HousekeepingPack
    var transit: TransitFeedPack
    var hikeRoutes: HikeRoutesPack
    var parkHikes: ParkHikesPack

    func place(_ id: String) -> Place? { placesById[id] }
    /// Hikes listed for a park region, in published order.
    func hikes(inRegion regionId: String) -> [Trail] { trails.trails.filter { $0.regionId == regionId } }
    func hikeAdvice(forRegion regionId: String) -> HikeAdvice? { parkHikes.regionNotes.first { $0.regionId == regionId } }
    /// "Yosemite Valley" or the hike's region name.
    func areaName(of trail: Trail) -> String { trail.regionId.flatMap { region($0)?.name } ?? "Yosemite Valley" }
    func trail(_ id: String) -> Trail? { trails.trails.first { $0.id == id } }
    func hikeRoute(_ id: String) -> HikeRoute? { hikeRoutes.routes.first { $0.id == id } }
    /// Routes in the trail's published order.
    func hikeRoutes(for trailId: String) -> [HikeRoute] {
        guard let trail = trail(trailId) else { return [] }
        return trail.routes.compactMap { published in hikeRoutes.routes.first { $0.id == published.id } }
    }
    func defaultHikeRoute(for trailId: String) -> HikeRoute? {
        let routes = hikeRoutes(for: trailId)
        return routes.first(where: \.isDefault) ?? routes.first
    }
    /// Routes that walk the given NPS trail feature, whichever pack they were traced on; the map draws them all.
    func hikeRoutes(usingFeature featureId: Int) -> [HikeRoute] {
        hikeRoutes.routes.filter { $0.featureIds.contains(featureId) }
    }
    func campground(_ id: String) -> Campground? { campgrounds.campgrounds.first { $0.id == id } }
    func category(_ id: String) -> PlaceCategory? { categories.categories.first { $0.id == id } }
    func forecastPoint(_ key: String) -> ForecastPoint? { status.forecastPoints.first { $0.key == key } }
    func region(_ id: String) -> ParkRegion? { regions.regions.first { $0.id == id } }
    func event(_ id: String) -> CuratedEvent? { events.events.first { $0.id == id } }
    func document(_ id: String) -> DocumentItem? { documents.first { $0.id == id } }
    func contact(_ id: String) -> Contact? { contacts.contacts.first { $0.id == id } }
    func permit(_ id: String) -> PermitGuide? { permits.guides.first { $0.id == id } }
    func webcam(_ id: String) -> Webcam? { webcams.webcams.first { $0.id == id } }
    func sites(in campgroundId: String) -> [Campsite] { campsites.filter { $0.campground == campgroundId } }
}

enum ContentLoadState {
    case idle
    case loading
    case ready(Content)
    case failed(String)
}

@MainActor
final class ContentStore: ObservableObject {
    static let shared = ContentStore()

    @Published private(set) var state: ContentLoadState = .idle

    var content: Content? {
        if case .ready(let c) = state { return c }
        return nil
    }

    var isReady: Bool { content != nil }

    func loadIfNeeded() async {
        guard case .idle = state else { return }
        state = .loading
        do {
            let content = try await Task.detached(priority: .userInitiated) { try BundleContent.load() }.value
            state = .ready(content)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// Bundled packs live in the `Content`, `Geo` and `Documents` folders at the bundle root.
enum BundleContent {
    enum LoadError: LocalizedError {
        case missing(String)
        case decoding(pack: String, path: String, detail: String)

        var errorDescription: String? {
            switch self {
            case .missing(let name): "The bundled pack \(name) is missing. Reinstall the app."
            case .decoding(let pack, let path, let detail): "The bundled pack \(pack) could not be read at \(path): \(detail). This build's content does not match its models; reinstall or update the app."
            }
        }

        /// Human-readable coding path and reason for any decoding failure.
        static func describe(_ error: Error, pack: String) -> LoadError {
            guard let decoding = error as? DecodingError else { return .decoding(pack: pack, path: "$", detail: error.localizedDescription) }
            func path(_ context: DecodingError.Context) -> String {
                "$" + context.codingPath.map { key in key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)" }.joined()
            }
            switch decoding {
            case .typeMismatch(let type, let context): return .decoding(pack: pack, path: path(context), detail: "expected \(type); \(context.debugDescription)")
            case .valueNotFound(let type, let context): return .decoding(pack: pack, path: path(context), detail: "missing value of type \(type)")
            case .keyNotFound(let key, let context): return .decoding(pack: pack, path: path(context) + ".\(key.stringValue)", detail: "key not found")
            case .dataCorrupted(let context): return .decoding(pack: pack, path: path(context), detail: context.debugDescription)
            @unknown default: return .decoding(pack: pack, path: "$", detail: decoding.localizedDescription)
            }
        }
    }

    static func resourceURL(_ name: String, subdirectory: String) -> URL? {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        return Bundle.main.url(forResource: parts[0], withExtension: parts.count > 1 ? parts[1] : nil, subdirectory: subdirectory)
    }

    static func data(_ name: String, subdirectory: String) throws -> Data {
        guard let url = resourceURL(name, subdirectory: subdirectory) else { throw LoadError.missing(name) }
        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String, subdirectory: String = "Content") throws -> T {
        try decode(type, from: data(name, subdirectory: subdirectory), pack: name)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, pack: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw LoadError.describe(error, pack: pack) }
    }

    static func load() throws -> Content {
        let places = try decode([Place].self, "places.json")
        let campsites = try CampsiteLoader.load(from: data("campsites.geojson", subdirectory: "Geo"))
        let parkHikes = try decode(ParkHikesPack.self, "park-hikes.json")
        var trails = try decode(TrailsPack.self, "trails.json")
        trails.trails += parkHikes.trails
        return Content(
            places: places,
            placesById: Dictionary(places.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            trails: trails,
            campgrounds: try decode(CampgroundsPack.self, "campgrounds.json"),
            campsites: campsites,
            permits: try decode(PermitsPack.self, "permits.json"),
            contacts: try decode(ContactsPack.self, "contacts.json"),
            events: try decode(EventsPack.self, "events.json"),
            regions: try decode(RegionsPack.self, "regions.json"),
            webcams: try decode(WebcamsPack.self, "webcams.json"),
            documents: try decode([DocumentItem].self, "documents.json"),
            status: try decode(StatusPack.self, "status.json"),
            categories: try decode(CategoriesPack.self, "categories.json"),
            notices: try decode(NoticesPack.self, "notices.json"),
            changelog: try decode([ChangelogEntry].self, "changelog.json"),
            housekeeping: try decode(HousekeepingPack.self, "housekeeping.json"),
            transit: try decode(TransitFeedPack.self, "transit.json", subdirectory: "Geo"),
            hikeRoutes: try decode(HikeRoutesPack.self, "hike-routes.json"),
            parkHikes: parkHikes
        )
    }
}

enum CampsiteLoader {
    private struct Collection: Decodable {
        struct Feature: Decodable {
            struct Geometry: Decodable { var coordinates: [Double] }
            struct Properties: Decodable {
                var campground: String
                var site: String
                var loop: String?
                var type: String
                var accessible: Bool
                var maxPeople: Int?
                var maxVehicleFt: Int?
                var ridbId: String
            }
            var geometry: Geometry
            var properties: Properties
        }
        var features: [Feature]
    }

    static func load(from data: Data) throws -> [Campsite] {
        try BundleContent.decode(Collection.self, from: data, pack: "campsites.geojson").features.map { f in
            Campsite(ridbId: f.properties.ridbId, campground: f.properties.campground, site: f.properties.site,
                     loop: f.properties.loop, type: f.properties.type, accessible: f.properties.accessible,
                     maxPeople: f.properties.maxPeople, maxVehicleFt: f.properties.maxVehicleFt,
                     latitude: f.geometry.coordinates[1], longitude: f.geometry.coordinates[0])
        }
    }
}
