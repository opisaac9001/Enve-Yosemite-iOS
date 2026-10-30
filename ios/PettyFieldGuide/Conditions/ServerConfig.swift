import Foundation
import Combine

/// Companion-server address. Empty means live conditions are unavailable, which the app states plainly.
@MainActor
final class ServerConfig: ObservableObject {
    static let shared = ServerConfig()

    @Published var baseURLString: String { didSet { UserDefaults.standard.set(baseURLString, forKey: "server.baseURL") } }

    private init() {
        baseURLString = UserDefaults.standard.string(forKey: "server.baseURL") ?? ""
    }

    var baseURL: URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    var isConfigured: Bool { baseURL != nil }
}
