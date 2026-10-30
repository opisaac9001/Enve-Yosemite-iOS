import Foundation

/// Device preferences that travel with an explicit backup. Everything here is a setting the user
/// chose; none of it ever goes into a share link.
struct BackupPreferences: Codable, Equatable {
    var appearance: String?
    var textSize: String?
    var boldText: Bool?
    var mapElementSize: String?
    var mapLayers: MapLayerToggles?
    var mapCategories: [String]?
    var conditionsPoints: [String]?
    var serverBaseURL: String?
    var eventFilter: EventFilter?
    var customEventCategories: [CustomEventCategory]?
    var planner: PlannerPreferences?
}

struct PlannerPreferences: Codable, Equatable {
    var feedId: String
    var from: String
    var to: String

    static let feedKey = "planner.feed"
    static let fromKey = "planner.from"
    static let toKey = "planner.to"
}

/// The file written by "Save backup to Files". Version 1 held only `state`; version 2 adds
/// preferences, the suggestion draft and (when the user opts in) private suggestion receipts.
/// The format marker predates the Enve Yosemite name and stays so every existing backup still imports.
struct BackupPackage: Codable {
    static let format = "petty-field-guide-backup"
    static let currentVersion = 2

    var format = BackupPackage.format
    var version = BackupPackage.currentVersion
    var exportedAt: Date
    var appVersion: String
    var state: SavedState
    var preferences: BackupPreferences?
    var suggestionDraft: SuggestionDraft?
    var suggestionReceipts: [SuggestionRecord]?

    enum ImportError: LocalizedError, Equatable {
        case unreadable, wrongFormat, newerVersion(Int)
        var errorDescription: String? {
            switch self {
            case .unreadable: "That file is not readable JSON."
            case .wrongFormat: "That file is not an Enve Yosemite backup."
            case .newerVersion(let v): "This backup uses format version \(v), newer than this app understands. Update the app first; nothing was changed."
            }
        }
    }

    /// Validates shape and version before anything is applied.
    static func decode(_ data: Data) throws -> BackupPackage {
        let decoder = SavedStore.decoder
        guard let package = try? decoder.decode(BackupPackage.self, from: data) else {
            if (try? JSONSerialization.jsonObject(with: data)) == nil { throw ImportError.unreadable }
            if let header = try? decoder.decode(Header.self, from: data), header.format == format, header.version > currentVersion { throw ImportError.newerVersion(header.version) }
            throw ImportError.wrongFormat
        }
        guard package.format == format else { throw ImportError.wrongFormat }
        guard package.version <= currentVersion else { throw ImportError.newerVersion(package.version) }
        return package
    }

    private struct Header: Decodable { var format: String; var version: Int }

    func encoded() throws -> Data { try SavedStore.encoder.encode(self) }
}

struct BackupImportReport: Equatable {
    var merge: SavedStore.MergeSummary
    var preferencesApplied: Bool
    var customCategoriesAdded: Int
    var draftRestored: Bool
    var receiptsAdded: Int

    var text: String {
        var parts = ["Imported. \(merge.text)"]
        parts.append(preferencesApplied
                     ? "Settings: appearance, text, map element size and map layers/categories replaced from the backup; conditions points, custom categories and planner stops filled in; event filter and server address taken only where this device had none."
                     : "No settings in this backup.")
        if customCategoriesAdded > 0 { parts.append("\(customCategoriesAdded) custom event categor\(customCategoriesAdded == 1 ? "y" : "ies") added.") }
        if draftRestored { parts.append("Suggestion draft restored.") }
        if receiptsAdded > 0 { parts.append("\(receiptsAdded) suggestion receipt\(receiptsAdded == 1 ? "" : "s") added to the Keychain.") }
        return parts.joined(separator: " ")
    }
}

/// Gathers everything an explicit backup contains and applies an imported one across the stores.
@MainActor
enum BackupCoordinator {
    static func export(includeReceipts: Bool) throws -> Data {
        let theme = ThemeManager.shared
        let defaults = UserDefaults.standard
        let events = EventsState.shared
        let updates = UpdatesStore.shared
        let layers = defaults.data(forKey: MapViewModel.layersKey).flatMap { try? JSONDecoder().decode(MapLayerToggles.self, from: $0) }
        let planner = defaults.string(forKey: PlannerPreferences.fromKey).map {
            PlannerPreferences(feedId: defaults.string(forKey: PlannerPreferences.feedKey) ?? "valley", from: $0, to: defaults.string(forKey: PlannerPreferences.toKey) ?? "shuttle-16")
        }
        let preferences = BackupPreferences(
            appearance: theme.appearance.rawValue, textSize: theme.textSize.rawValue, boldText: theme.boldText, mapElementSize: theme.mapElementSize.rawValue,
            mapLayers: layers, mapCategories: defaults.stringArray(forKey: MapViewModel.categoriesKey),
            conditionsPoints: Array(ConditionsStore.shared.selectedPoints).sorted(), serverBaseURL: ServerConfig.shared.baseURLString.isEmpty ? nil : ServerConfig.shared.baseURLString,
            eventFilter: events.filter, customEventCategories: events.customCategories, planner: planner)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let package = BackupPackage(exportedAt: Date(), appVersion: version, state: SavedStore.shared.state, preferences: preferences,
                                    suggestionDraft: updates.draft.text.isEmpty && updates.draft.title.isEmpty ? nil : updates.draft,
                                    suggestionReceipts: includeReceipts ? updates.submissions : nil)
        return try package.encoded()
    }

    static func restore(_ data: Data) throws -> BackupImportReport {
        let package = try BackupPackage.decode(data)
        let merge = SavedStore.shared.merge(package.state)
        var categoriesAdded = 0
        var applied = false
        if let p = package.preferences {
            applied = true
            let theme = ThemeManager.shared
            if let a = p.appearance.flatMap(AppearanceChoice.init(rawValue:)) { theme.appearance = a }
            if let t = p.textSize.flatMap(TextSizeChoice.init(rawValue:)) { theme.textSize = t }
            if let b = p.boldText { theme.boldText = b }
            if let m = p.mapElementSize.flatMap(MapElementSize.init(rawValue:)) { theme.mapElementSize = m }
            let defaults = UserDefaults.standard
            if let layers = p.mapLayers, let data = try? JSONEncoder().encode(layers) { defaults.set(data, forKey: MapViewModel.layersKey) }
            if let categories = p.mapCategories { defaults.set(categories, forKey: MapViewModel.categoriesKey) }
            if p.mapLayers != nil || p.mapCategories != nil { NotificationCenter.default.post(name: .mapPreferencesImported, object: nil) }
            if let points = p.conditionsPoints { ConditionsStore.shared.selectedPoints.formUnion(points) }
            if let url = p.serverBaseURL, ServerConfig.shared.baseURLString.isEmpty { ServerConfig.shared.baseURLString = url }
            let events = EventsState.shared
            if let custom = p.customEventCategories {
                for category in custom where !events.customCategories.contains(where: { $0.id == category.id }) {
                    events.customCategories.append(category)
                    categoriesAdded += 1
                }
            }
            if let filter = p.eventFilter, events.filter.isEmpty { events.filter = filter }
            if let planner = p.planner {
                defaults.set(planner.feedId, forKey: PlannerPreferences.feedKey)
                defaults.set(planner.from, forKey: PlannerPreferences.fromKey)
                defaults.set(planner.to, forKey: PlannerPreferences.toKey)
            }
        }
        let updates = UpdatesStore.shared
        var draftRestored = false
        if let draft = package.suggestionDraft, updates.draft.text.isEmpty, updates.draft.title.isEmpty {
            updates.draft = draft
            draftRestored = true
        }
        let receiptsAdded = package.suggestionReceipts.map(updates.importReceipts) ?? 0
        return BackupImportReport(merge: merge, preferencesApplied: applied, customCategoriesAdded: categoriesAdded, draftRestored: draftRestored, receiptsAdded: receiptsAdded)
    }
}
