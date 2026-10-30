import Foundation
import Combine
import CoreLocation

struct SavedPlace: Codable, Hashable, Sendable {
    var placeId: String
    var savedAt: Date
    var note: String?
    var noteUpdatedAt: Date?

    /// When the note was last written or deliberately cleared. A cleared note keeps its stamp as a
    /// tombstone so an older backup cannot resurrect the text; a place that never had a note loses.
    var noteStamp: Date { noteUpdatedAt ?? (note == nil ? .distantPast : savedAt) }
}

extension Date {
    /// Now, at the millisecond precision the saved-state encoding keeps, so what is written reloads equal.
    static var stamp: Date { DateText.parse(DateText.isoString(Date()))! }
}

struct SavedCampsite: Codable, Hashable, Sendable {
    var campgroundId: String
    var siteId: String?          // RIDB id when the site came from the inventory
    var label: String            // e.g. "Upper Pines · site 18" or "Housekeeping unit 179"
    var placeId: String?         // Valley place or Housekeeping unit place
    var latitude: Double?
    var longitude: Double?
    var updatedAt: Date
}

enum CarPinBasis: String, Codable, Sendable {
    case manual, location
}

struct SavedCar: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    var note: String?
    var basis: CarPinBasis
    var updatedAt: Date
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

struct SavedEventView: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var encodedFilter: String
    var isDefault: Bool
    var savedAt: Date
}

struct SavedState: Codable, Equatable, Sendable {
    var version = 1
    var places: [String: SavedPlace] = [:]
    var campsite: SavedCampsite?
    var car: SavedCar?
    var eventViews: [SavedEventView] = []
    var trackedTopics: [String: TopicPreference] = [:]
    var seenRevisions: [String: String] = [:]
    var changelogSeenId: String?
    var introGuideSeen = false
}

extension SavedState {
    /// Backups and older state files may omit keys that later versions always write; missing keys take defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        places = try c.decodeIfPresent([String: SavedPlace].self, forKey: .places) ?? [:]
        campsite = try c.decodeIfPresent(SavedCampsite.self, forKey: .campsite)
        car = try c.decodeIfPresent(SavedCar.self, forKey: .car)
        eventViews = try c.decodeIfPresent([SavedEventView].self, forKey: .eventViews) ?? []
        trackedTopics = try c.decodeIfPresent([String: TopicPreference].self, forKey: .trackedTopics) ?? [:]
        seenRevisions = try c.decodeIfPresent([String: String].self, forKey: .seenRevisions) ?? [:]
        changelogSeenId = try c.decodeIfPresent(String.self, forKey: .changelogSeenId)
        introGuideSeen = try c.decodeIfPresent(Bool.self, forKey: .introGuideSeen) ?? false
    }
}

struct TopicPreference: Codable, Hashable, Sendable {
    var track: Bool
    var push: Bool
}

/// On-device personal state. Never shared through links; exported only through explicit backup.
@MainActor
final class SavedStore: ObservableObject {
    static let shared = SavedStore(fileURL: AppDirectories.applicationSupport.appendingPathComponent("saved-state.json"))

    @Published private(set) var state: SavedState
    @Published private(set) var storageError: String?

    private let fileURL: URL
    private var writer: Task<Void, Never>?

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let decoded = try? Self.decoder.decode(SavedState.self, from: data) {
            state = decoded
        } else {
            state = SavedState()
            if FileManager.default.fileExists(atPath: fileURL.path) {
                storageError = "Saved items on this device could not be read. Saving something new replaces the unreadable copy."
            }
        }
    }

    /// Dates travel as ISO 8601 with milliseconds; reading accepts whole-second strings from older files too.
    nonisolated static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = DateText.parse(raw) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unreadable date \(raw)") }
            return date
        }
        return d
    }

    nonisolated static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(DateText.isoString(date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }

    // MARK: Mutations

    func isSaved(_ placeId: String) -> Bool { state.places[placeId] != nil }

    func toggleSaved(_ placeId: String) {
        if state.places[placeId] != nil { state.places.removeValue(forKey: placeId) }
        else { state.places[placeId] = SavedPlace(placeId: placeId, savedAt: .stamp) }
        persist()
    }

    func setNote(_ note: String?, for placeId: String) {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        var entry = state.places[placeId] ?? SavedPlace(placeId: placeId, savedAt: .stamp)
        entry.note = (trimmed?.isEmpty ?? true) ? nil : trimmed
        entry.noteUpdatedAt = .stamp
        state.places[placeId] = entry
        persist()
    }

    func setCampsite(_ campsite: SavedCampsite?) {
        state.campsite = campsite
        persist()
    }

    func setCar(_ car: SavedCar?) {
        state.car = car
        persist()
    }

    func update(_ mutate: (inout SavedState) -> Void) {
        mutate(&state)
        persist()
    }

    // MARK: Merge (backup restore)

    struct MergeSummary: Equatable {
        enum Decision: Equatable { case none, keptLocal, tookBackup }
        var placesAdded = 0
        var notesUpdated = 0
        var campsite: Decision = .none
        var car: Decision = .none
        var eventViewsAdded = 0
        var topicsAdded = 0

        var text: String {
            func describe(_ d: Decision) -> String {
                switch d {
                case .none: "none"
                case .keptLocal: "kept this device's (newer or only)"
                case .tookBackup: "took the backup's (newer)"
                }
            }
            return "\(placesAdded) new saved place\(placesAdded == 1 ? "" : "s"), \(notesUpdated) note\(notesUpdated == 1 ? "" : "s") updated; campsite: \(describe(campsite)); car pin: \(describe(car)); \(eventViewsAdded) event view\(eventViewsAdded == 1 ? "" : "s") and \(topicsAdded) tracked topic\(topicsAdded == 1 ? "" : "s") added."
        }
    }

    /// Union merge. Saved places union with the newer note edit winning per place (a newer deliberate
    /// clear beats older text); campsite and car keep whichever is newer; event views, tracked topics
    /// and seen revisions fill gaps only. Nothing local is dropped.
    @discardableResult
    func merge(_ incoming: SavedState) -> MergeSummary {
        var merged = state
        var summary = MergeSummary()
        for (id, theirs) in incoming.places {
            if var mine = merged.places[id] {
                if theirs.noteStamp > mine.noteStamp {
                    mine.note = theirs.note
                    mine.noteUpdatedAt = theirs.noteStamp
                    summary.notesUpdated += 1
                }
                mine.savedAt = min(mine.savedAt, theirs.savedAt)
                merged.places[id] = mine
            } else {
                merged.places[id] = theirs
                summary.placesAdded += 1
            }
        }
        if let theirs = incoming.campsite {
            if let mine = merged.campsite, mine.updatedAt >= theirs.updatedAt { summary.campsite = .keptLocal }
            else { merged.campsite = theirs; summary.campsite = .tookBackup }
        } else if merged.campsite != nil { summary.campsite = .keptLocal }
        if let theirs = incoming.car {
            if let mine = merged.car, mine.updatedAt >= theirs.updatedAt { summary.car = .keptLocal }
            else { merged.car = theirs; summary.car = .tookBackup }
        } else if merged.car != nil { summary.car = .keptLocal }
        let localHasDefault = merged.eventViews.contains(where: \.isDefault)
        for view in incoming.eventViews where !merged.eventViews.contains(where: { $0.id == view.id }) {
            var copy = view
            if localHasDefault { copy.isDefault = false }
            merged.eventViews.append(copy)
            summary.eventViewsAdded += 1
        }
        for (topic, pref) in incoming.trackedTopics where merged.trackedTopics[topic] == nil {
            merged.trackedTopics[topic] = pref
            summary.topicsAdded += 1
        }
        for (channel, revision) in incoming.seenRevisions where merged.seenRevisions[channel] == nil {
            merged.seenRevisions[channel] = revision
        }
        merged.changelogSeenId = merged.changelogSeenId ?? incoming.changelogSeenId
        merged.introGuideSeen = merged.introGuideSeen || incoming.introGuideSeen
        state = merged
        persist()
        return summary
    }

    // MARK: Persistence

    /// Writes are chained so they complete in the order the edits happened; the last write always
    /// holds the newest state even when an earlier encode is still running.
    private func persist() {
        let snapshot = state
        let url = fileURL
        let previous = writer
        writer = Task.detached(priority: .utility) { [weak self] in
            await previous?.value
            do {
                let data = try Self.encoder.encode(snapshot)
                try AtomicFile.write(data, to: url)
            } catch {
                let message = "Could not save to this device: \(error.localizedDescription)"
                await MainActor.run { self?.storageError = message }
            }
        }
    }

    /// Waits until every queued write has landed.
    func flush() async {
        await writer?.value
    }
}

enum AppDirectories {
    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PettyFieldGuide", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func subdirectory(_ name: String) -> URL {
        let dir = applicationSupport.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

enum AtomicFile {
    /// Writes to a sibling temp file and replaces, so a crash mid-write never leaves a torn file.
    static func write(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        try replace(url, with: tmp)
    }

    /// Atomic swap that also works when the destination does not exist yet.
    static func replace(_ url: URL, with tmp: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
