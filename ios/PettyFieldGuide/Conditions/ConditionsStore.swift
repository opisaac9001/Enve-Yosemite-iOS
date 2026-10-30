import Foundation
import Combine

/// Every feed payload carries the time the server assembled it from upstream sources.
protocol TimestampedFeed {
    var fetchedAt: String { get }
}

extension WeatherFeed: TimestampedFeed {}
extension FireFeed: TimestampedFeed {}
extension SmokeFeed: TimestampedFeed {}
extension SeasonalFeed: TimestampedFeed {}
extension ProgramsFeed: TimestampedFeed {}
extension ConditionsFeed: TimestampedFeed {}

/// A saved feed payload. Age, staleness and the 48-hour expiry are measured from `acquiredAt`,
/// the payload's own acquisition time, never from when this device happened to download it:
/// the server keeps serving its last good payload when upstream fails, so a fresh HTTP response
/// can carry days-old observations.
struct Snapshot<Payload: Codable & Sendable>: Codable, Sendable {
    var payload: Payload
    var acquiredAt: Date
    var retrievedAt: Date

    static var expiry: TimeInterval { 48 * 3600 }

    var age: TimeInterval { Date().timeIntervalSince(acquiredAt) }
    var isExpired: Bool { age > Self.expiry }
    var servedFromServerCache: Bool { retrievedAt.timeIntervalSince(acquiredAt) > 60 }

    func freshness(staleAfter: TimeInterval) -> SourceState {
        if isExpired { return .expired }
        if age > staleAfter { return .stale }
        return .ready
    }
}

enum SnapshotError: LocalizedError, Equatable {
    case unreadableAcquisitionTime(String)
    case acquisitionTimeInFuture(String)

    var errorDescription: String? {
        switch self {
        case .unreadableAcquisitionTime(let raw): "The server reply has no readable acquisition time (\"\(raw)\"), so it was not saved."
        case .acquisitionTimeInFuture(let raw): "The server reply is dated in the future (\(raw)); its clock cannot be trusted, so it was not saved."
        }
    }
}

extension Snapshot where Payload: TimestampedFeed {
    /// Validates the payload's acquisition time before anything is stored or shown.
    static func received(_ payload: Payload, at retrievedAt: Date = Date()) throws -> Snapshot<Payload> {
        guard let acquired = DateText.parse(payload.fetchedAt) else { throw SnapshotError.unreadableAcquisitionTime(payload.fetchedAt) }
        guard acquired <= retrievedAt.addingTimeInterval(3600) else { throw SnapshotError.acquisitionTimeInFuture(payload.fetchedAt) }
        return Snapshot(payload: payload, acquiredAt: acquired, retrievedAt: retrievedAt)
    }
}

enum FeedKind: String, CaseIterable, Codable, Sendable {
    case weather, fire, smoke, seasonal, programs, conditions

    var title: String {
        switch self {
        case .weather: "Weather by forecast point"
        case .fire: "Fire assessment"
        case .smoke: "Smoke, air & incidents"
        case .seasonal: "River, chains & seasonal notices"
        case .programs: "NPS calendar & visitor-centre hours"
        case .conditions: "Roads, trails, alerts & wilderness reports"
        }
    }
}

@MainActor
final class ConditionsStore: ObservableObject {
    static let shared = ConditionsStore()

    @Published private(set) var weather: [String: Snapshot<WeatherFeed>] = [:]
    @Published private(set) var fire: Snapshot<FireFeed>?
    @Published private(set) var smoke: Snapshot<SmokeFeed>?
    @Published private(set) var seasonal: Snapshot<SeasonalFeed>?
    @Published private(set) var programs: Snapshot<ProgramsFeed>?
    @Published private(set) var conditions: Snapshot<ConditionsFeed>?
    @Published private(set) var refreshing: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    @Published var selectedPoints: Set<String> { didSet { UserDefaults.standard.set(Array(selectedPoints), forKey: "conditions.points") } }

    private let directory = AppDirectories.subdirectory("conditions")
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()

    private init() {
        selectedPoints = Set(UserDefaults.standard.stringArray(forKey: "conditions.points") ?? ["valley"])
        fire = read("fire.json")
        smoke = read("smoke.json")
        seasonal = read("seasonal.json")
        programs = read("programs.json")
        conditions = read("conditions.json")
        if let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for file in files where file.hasPrefix("weather-") && file.hasSuffix(".json") {
                let key = String(file.dropFirst("weather-".count).dropLast(".json".count))
                if let snap: Snapshot<WeatherFeed> = read(file) { weather[key] = snap }
            }
        }
    }

    private func read<T: Codable & Sendable>(_ name: String) -> Snapshot<T>? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? decoder.decode(Snapshot<T>.self, from: data)
    }

    private func write<T: Codable & Sendable>(_ snapshot: Snapshot<T>, _ name: String) {
        if let data = try? encoder.encode(snapshot) { try? AtomicFile.write(data, to: directory.appendingPathComponent(name)) }
    }

    func isRefreshing(_ key: String) -> Bool { refreshing.contains(key) }

    // MARK: Refresh

    /// Validates, stores and persists one payload; an old payload re-served by the server is kept
    /// (it is the only data there is) but flagged so the screens can say so.
    private func accept<T: TimestampedFeed & Codable & Sendable>(_ payload: T, key: String, file: String, assign: (Snapshot<T>) -> Void) throws {
        let snapshot = try Snapshot.received(payload)
        assign(snapshot)
        write(snapshot, file)
        if snapshot.isExpired {
            errors[key] = "The server returned data acquired \(DateText.relative(snapshot.acquiredAt)); its upstream sources were unreachable. Shown as expired, not current."
        } else {
            errors[key] = nil
        }
    }

    func refreshWeather(point: String) async {
        let key = "weather-\(point)"
        refreshing.insert(key); defer { refreshing.remove(key) }
        do {
            let feed = try await ConditionsClient.shared.weather(point: point)
            try accept(feed, key: key, file: "\(key).json") { weather[point] = $0 }
        } catch { errors[key] = error.localizedDescription }
    }

    func refresh(_ kind: FeedKind) async {
        let key = kind.rawValue
        refreshing.insert(key); defer { refreshing.remove(key) }
        do {
            switch kind {
            case .weather:
                for point in selectedPoints { await refreshWeather(point: point) }
            case .fire:
                try accept(try await ConditionsClient.shared.fire(), key: key, file: "fire.json") { fire = $0 }
            case .smoke:
                try accept(try await ConditionsClient.shared.smoke(), key: key, file: "smoke.json") { smoke = $0 }
            case .seasonal:
                try accept(try await ConditionsClient.shared.seasonal(), key: key, file: "seasonal.json") { seasonal = $0 }
            case .programs:
                try accept(try await ConditionsClient.shared.programs(), key: key, file: "programs.json") { programs = $0 }
            case .conditions:
                try accept(try await ConditionsClient.shared.conditions(), key: key, file: "conditions.json") { conditions = $0 }
            }
        } catch { errors[key] = error.localizedDescription }
    }

    func refreshAll() async {
        for kind in FeedKind.allCases { await refresh(kind) }
    }

    /// Foreground/return refresh for feeds whose data is older than the given interval.
    func refreshStale(olderThan interval: TimeInterval = 15 * 60) async {
        guard ServerConfig.shared.isConfigured else { return }
        for point in selectedPoints where (weather[point]?.age ?? .infinity) > interval { await refreshWeather(point: point) }
        if (fire?.age ?? .infinity) > interval { await refresh(.fire) }
        if (smoke?.age ?? .infinity) > interval { await refresh(.smoke) }
        if (seasonal?.age ?? .infinity) > interval { await refresh(.seasonal) }
        if (programs?.age ?? .infinity) > interval { await refresh(.programs) }
        if (conditions?.age ?? .infinity) > interval { await refresh(.conditions) }
    }

    func clearAll() {
        weather = [:]; fire = nil; smoke = nil; seasonal = nil; programs = nil; conditions = nil
        try? FileManager.default.removeItem(at: directory)
        _ = AppDirectories.subdirectory("conditions")
    }

    var storedBytes: Int {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]))?
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +) ?? 0
    }
}
