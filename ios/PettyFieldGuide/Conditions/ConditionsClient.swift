import Foundation

/// HTTP client for the companion server. Every call fails with a readable message when no
/// server is configured, so screens can show "unavailable".
final class ConditionsClient: Sendable {
    static let shared = ConditionsClient()

    enum ClientError: LocalizedError {
        case notConfigured
        case http(Int, String)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "No companion server is configured. Add its address under Trip prep › Conditions server."
            case .http(let code, let body): "Server returned HTTP \(code)\(body.isEmpty ? "" : ": \(body)")"
            case .decoding(let detail): "The server reply could not be read: \(detail)"
            }
        }
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private let decoder = JSONDecoder()

    private func baseURL() async throws -> URL {
        guard let url = await MainActor.run(body: { ServerConfig.shared.baseURL }) else { throw ClientError.notConfigured }
        return url
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        var components = URLComponents(url: try await baseURL().appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        do { return try decoder.decode(T.self, from: data) } catch { throw ClientError.decoding(error.localizedDescription) }
    }

    private func post<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        var request = URLRequest(url: try await baseURL().appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        do { return try decoder.decode(T.self, from: data) } catch { throw ClientError.decoding(error.localizedDescription) }
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? ""
            throw ClientError.http(http.statusCode, message)
        }
    }

    // MARK: Feeds

    func weather(point: String) async throws -> WeatherFeed { try await get("api/weather", query: ["point": point]) }
    func fire() async throws -> FireFeed { try await get("api/fire-risk") }
    func smoke() async throws -> SmokeFeed { try await get("api/smoke") }
    func seasonal() async throws -> SeasonalFeed { try await get("api/seasonal-risks") }
    func programs() async throws -> ProgramsFeed { try await get("api/nps-programs") }
    func conditions() async throws -> ConditionsFeed { try await get("api/conditions") }
    func updates() async throws -> UpdatesFeed { try await get("api/updates") }

    // MARK: Suggestions

    struct SuggestionSubmission: Encodable, Sendable {
        var name: String?
        var title: String?
        var text: String
        var layout: LayoutMetadata?
        var proof: String?
    }

    struct LayoutMetadata: Codable, Hashable, Sendable {
        var section: String
        var orientation: String
        var sizeClass: String
        var textSize: String
        var appearance: String
        var appVersion: String
    }

    struct SuggestionReceipt: Codable, Hashable, Sendable {
        var receipt: String
        var name: String?
        var createdAt: String
        var updatedAt: String
        var status: String
        var reply: String?
        var closed: Bool?
    }

    func submitSuggestion(_ submission: SuggestionSubmission) async throws -> SuggestionReceipt { try await post("api/suggestions", body: submission) }

    struct StatusRequest: Encodable { var receipts: [ReceiptRef] }
    struct ReceiptRef: Encodable { var receipt: String; var name: String? }
    struct StatusResponse: Decodable { var responses: [SuggestionReceipt] }

    func suggestionStatus(_ refs: [ReceiptRef]) async throws -> [SuggestionReceipt] {
        let response: StatusResponse = try await post("api/suggestions/status", body: StatusRequest(receipts: refs))
        return response.responses
    }

    // MARK: Push

    struct PushRegistrationBody: Encodable { var token: String; var platform = "apns"; var preferences: [String: TopicPreference] }
    struct PushRegistrationReply: Decodable { var accepted: Bool; var pushReady: Bool }

    func registerPush(token: String, preferences: [String: TopicPreference]) async throws -> Bool {
        let reply: PushRegistrationReply = try await post("api/push/register", body: PushRegistrationBody(token: token, preferences: preferences))
        return reply.accepted && reply.pushReady
    }

    func unregisterPush(token: String) async throws {
        let _: PushRegistrationReply = try await post("api/push/unregister", body: ["token": token])
    }

    // MARK: Downloads

    func download(path: String, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Int {
        let url = try await baseURL().appendingPathComponent(path)
        let (tmp, response) = try await session.download(from: url)
        try check(response, Data())
        let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmp, to: destination)
        progress(1)
        return size
    }
}
