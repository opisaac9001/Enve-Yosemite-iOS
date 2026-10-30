import Foundation
import Combine
import Security

/// Topic tracking against the server's update channels, plus suggestion receipts.
@MainActor
final class UpdatesStore: ObservableObject {
    static let shared = UpdatesStore()

    @Published private(set) var feed: UpdatesFeed?
    @Published private(set) var unread: Set<String> = []
    @Published private(set) var lastCheck: Date?
    @Published private(set) var checking = false
    @Published private(set) var message: String?
    @Published private(set) var submissions: [SuggestionRecord] = []
    @Published var draft: SuggestionDraft { didSet { if let d = try? JSONEncoder().encode(draft) { UserDefaults.standard.set(d, forKey: "suggestions.draft") } } }

    private var timer: Timer?
    private static let keychainService = "dev.petty.fieldguide.suggestion-receipts"

    private init() {
        if let d = UserDefaults.standard.data(forKey: "suggestions.draft"), let decoded = try? JSONDecoder().decode(SuggestionDraft.self, from: d) { draft = decoded } else { draft = SuggestionDraft() }
        submissions = Keychain.read(service: Self.keychainService).flatMap { try? JSONDecoder().decode([SuggestionRecord].self, from: $0) } ?? []
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in Task { @MainActor in await self?.check(background: true) } }
    }

    var unreadCount: Int { unread.count }

    func preferences(saved: SavedState, topics: [UpdateTopic]) -> [String: TopicPreference] {
        var out: [String: TopicPreference] = [:]
        for t in topics { out[t.id] = saved.trackedTopics[t.id] ?? TopicPreference(track: t.id == "app", push: false) }
        return out
    }

    /// Fetches channels and marks tracked topics whose revision moved since last seen.
    func check(background: Bool = false) async {
        guard ServerConfig.shared.isConfigured else {
            if !background { message = "No companion server configured; nothing to check. Bundled content updates with app releases." }
            return
        }
        if background, let last = lastCheck, Date().timeIntervalSince(last) < 60 { return }
        checking = true; defer { checking = false }
        do {
            let feed = try await ConditionsClient.shared.updates()
            self.feed = feed
            let saved = SavedStore.shared
            var newlyChanged: Set<String> = []
            var seen = saved.state.seenRevisions
            for (channel, info) in feed.channels where info.available {
                let pref = saved.state.trackedTopics[channel] ?? TopicPreference(track: channel == "app", push: false)
                if let previous = seen[channel], previous != info.revision, pref.track { newlyChanged.insert(channel) }
                if seen[channel] == nil { seen[channel] = info.revision }
            }
            unread.formUnion(newlyChanged)
            saved.update { $0.seenRevisions = seen }
            lastCheck = Date()
            message = nil
            await pollReceipts()
        } catch {
            message = error.localizedDescription
        }
    }

    func markRead() {
        guard let feed else { unread = []; return }
        SavedStore.shared.update { s in for (channel, info) in feed.channels where info.available { s.seenRevisions[channel] = info.revision } }
        unread = []
    }

    // MARK: Suggestions

    func submit(layout: ConditionsClient.LayoutMetadata?) async -> Bool {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 250 else { message = "Write between 1 and 250 characters."; return false }
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        let proof = submissions.first { $0.name == (name.isEmpty ? nil : name) }?.receipt
        do {
            let receipt = try await ConditionsClient.shared.submitSuggestion(.init(name: name.isEmpty ? nil : name, title: draft.title.isEmpty ? nil : draft.title, text: text, layout: layout, proof: proof))
            guard !submissions.contains(where: { $0.receipt == receipt.receipt }) else { return true }
            submissions.append(SuggestionRecord(receipt: receipt.receipt, name: receipt.name, title: draft.title, text: text, createdAt: receipt.createdAt, updatedAt: receipt.updatedAt, status: receipt.status, reply: receipt.reply, closed: receipt.closed ?? false, readAt: receipt.updatedAt))
            persistReceipts()
            draft = SuggestionDraft(name: name)
            message = "Suggestion submitted. Your private receipt is saved in the Keychain on this device."
            return true
        } catch {
            message = "\(error.localizedDescription) Your draft is saved; retry when ready."
            return false
        }
    }

    func pollReceipts() async {
        let open = submissions.filter { !$0.closed }
        guard !open.isEmpty else { return }
        do {
            let replies = try await ConditionsClient.shared.suggestionStatus(open.map { .init(receipt: $0.receipt, name: $0.name) })
            for reply in replies {
                if let i = submissions.firstIndex(where: { $0.receipt == reply.receipt }) {
                    submissions[i].status = reply.status
                    submissions[i].reply = reply.reply
                    submissions[i].updatedAt = reply.updatedAt
                    submissions[i].closed = reply.closed ?? false
                }
            }
            persistReceipts()
        } catch { message = error.localizedDescription }
    }

    /// Adds receipts from an explicit backup that this device does not already hold.
    @discardableResult
    func importReceipts(_ records: [SuggestionRecord]) -> Int {
        let fresh = records.filter { record in !submissions.contains { $0.receipt == record.receipt } }
        guard !fresh.isEmpty else { return 0 }
        submissions.append(contentsOf: fresh)
        persistReceipts()
        return fresh.count
    }

    var unreadReplies: Int { submissions.filter { $0.readAt != $0.updatedAt }.count }

    func markRepliesRead() {
        for i in submissions.indices { submissions[i].readAt = submissions[i].updatedAt }
        persistReceipts()
    }

    private func persistReceipts() {
        if let data = try? JSONEncoder().encode(submissions) { Keychain.write(data, service: Self.keychainService) }
    }
}

struct SuggestionDraft: Codable, Equatable {
    var name = ""
    var title = ""
    var text = ""
    var includeLayout = false
}

struct SuggestionRecord: Codable, Identifiable, Hashable {
    var receipt: String
    var name: String?
    var title: String
    var text: String
    var createdAt: String
    var updatedAt: String
    var status: String
    var reply: String?
    var closed: Bool
    var readAt: String
    var id: String { receipt }
}

enum Keychain {
    static func read(service: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func write(_ data: Data, service: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var add = query
            add.merge(attributes) { $1 }
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
