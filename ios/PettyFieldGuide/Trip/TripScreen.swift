import SwiftUI
import UniformTypeIdentifiers

struct TripScreen: View {
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var saved: SavedStore
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var conditions = ConditionsStore.shared
    @ObservedObject private var server = ServerConfig.shared
    @ObservedObject private var packs = OfflinePackStatus.shared
    @State private var confirmClearCar = false

    var body: some View {
        if let c = content.content {
            FieldScroll {
                conditionsCard(c)
                basePackCard
                savedCard(c)
                FieldCard(eyebrow: "Backup") {
                    Text("Export your saved places, notes, campsite, car pin, event views, tracked topics and settings as a JSON file, or restore one. Imports merge: nothing on this device is dropped silently.").font(.fieldCaption)
                    Button { router.sheet = .backup } label: { Label("Back up or restore", systemImage: "externaldrive") }.buttonStyle(.bordered).font(.fieldCaption)
                }
                NavigationLink(value: Route.explorerLayer("catalog")) {
                    FieldCard(eyebrow: "Optional GIS packs") {
                        HStack { Text("Park-wide trails, roads, buildings, structures, parking and places from NPS GIS. Download only what you need.").font(.fieldCaption); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                    }
                }
                .buttonStyle(.plain)
                FieldCard(eyebrow: "Travel facts") {
                    ForEach(c.regions.tripFacts, id: \.label) { fact in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fact.label).font(.fieldEyebrow).foregroundStyle(.secondary)
                            Text(fact.detail).font(.fieldBody)
                            if let other = fact.otherYears, let year = fact.onlyYear, YosemiteGeo.calendar.component(.year, from: Date()) != year { Text(other).font(.fieldCaption).foregroundStyle(Palette.ember) }
                            if let u = fact.url, let url = URL(string: u) { Link("Official page", destination: url).font(.fieldCaption) }
                        }
                    }
                }
                FieldCard(eyebrow: "Install") {
                    Text("This is a native app: every map, document and directory record is inside it. Airplane mode changes nothing except live feeds.").font(.fieldCaption)
                }
            }
            .fieldNavigationTitle("Trip prep")
            .task { packs.verify() }
        }
    }

    private func conditionsCard(_ c: Content) -> some View {
        FieldCard(eyebrow: "Conditions snapshots · expire after 48 h") {
            Text("Choose forecast points to save, then refresh before you lose signal.").font(.fieldCaption)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(c.status.forecastPoints) { point in
                        ChipButton(title: point.label, active: conditions.selectedPoints.contains(point.key)) {
                            if conditions.selectedPoints.contains(point.key) { conditions.selectedPoints.remove(point.key) } else { conditions.selectedPoints.insert(point.key) }
                        }
                    }
                }
            }
            ForEach(c.status.forecastPoints.filter { conditions.selectedPoints.contains($0.key) }) { point in
                row(label: "Weather · \(point.label)", snapshot: conditions.weather[point.key], key: "weather-\(point.key)", stale: 3600)
            }
            row(label: FeedKind.fire.title, snapshot: conditions.fire, key: "fire", stale: 3600)
            row(label: FeedKind.smoke.title, snapshot: conditions.smoke, key: "smoke", stale: 3600)
            row(label: FeedKind.seasonal.title, snapshot: conditions.seasonal, key: "seasonal", stale: 3 * 3600)
            row(label: FeedKind.conditions.title, snapshot: conditions.conditions, key: "conditions", stale: 6 * 3600)
            row(label: FeedKind.programs.title, snapshot: conditions.programs, key: "programs", stale: 12 * 3600)
            HStack {
                Button { Task { await conditions.refreshAll() } } label: { Label("Refresh all", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent).disabled(!server.isConfigured || !conditions.refreshing.isEmpty)
                Button(role: .destructive) { conditions.clearAll() } label: { Label("Delete snapshots", systemImage: "trash") }.buttonStyle(.bordered)
            }
            .font(.fieldCaption)
            Text(server.isConfigured ? "Server: \(server.baseURLString) · stored \(ByteCountFormatter.string(fromByteCount: Int64(conditions.storedBytes), countStyle: .file))" : "No companion server configured; set one in Settings to enable live refresh.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func row<T: Codable & Sendable>(label: String, snapshot: Snapshot<T>?, key: String, stale: TimeInterval) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.fieldCaption.weight(.semibold))
                SnapshotFooter(snapshot: snapshot, staleAfter: stale)
                if let e = conditions.errors[key] { Text(e).font(.caption2).foregroundStyle(Palette.ember) }
            }
            Spacer()
            if conditions.isRefreshing(key) { ProgressView() }
        }
    }

    private var basePackCard: some View {
        FieldCard(eyebrow: "Base pack · bundled with the app") {
            ForEach(packs.resources) { r in
                HStack {
                    Circle().fill(Palette.stateColor(r.state)).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.label).font(.fieldCaption.weight(.semibold))
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(r.bytes), countStyle: .file)) · \(r.detail)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            HStack {
                Text("Total \(ByteCountFormatter.string(fromByteCount: Int64(packs.totalBytes), countStyle: .file)) · checked \(packs.checkedAt.map { DateText.short($0) } ?? "–")").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button { packs.verify(force: true) } label: { Label("Check files", systemImage: "checkmark.shield") }.buttonStyle(.bordered).font(.fieldCaption)
            }
            if packs.missing.isEmpty {
                Text("Every bundled resource is present with its expected checksum. Native packs update with app releases; there is nothing to repair separately.").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Missing or altered: \(packs.missing.joined(separator: ", ")). Reinstall the app to repair; the bundle is read-only.").font(.caption2).foregroundStyle(Palette.ember)
            }
        }
    }

    private func savedCard(_ c: Content) -> some View {
        FieldCard(eyebrow: "Saved on this device") {
            if let car = saved.state.car {
                VStack(alignment: .leading, spacing: 4) {
                    Label(ParkedCar.describe(car), systemImage: "car.fill").font(.fieldCaption)
                    if let note = car.note { Text(note).font(.fieldCaption).foregroundStyle(.secondary) }
                    if MapCoverage.contains(car.coordinate) {
                        HStack {
                            Button("Map") { router.showOnMap(.coordinate(latitude: car.latitude, longitude: car.longitude, label: "My car")) }
                            Button("Edit") { router.openMapTool(.parkedCar) }
                            Button("Clear", role: .destructive) { confirmClearCar = true }
                        }
                        .buttonStyle(.bordered).font(.fieldCaption)
                    } else {
                        Text(String(format: "Outside the bundled map · %.5f, %.5f", car.latitude, car.longitude)).font(.caption2).foregroundStyle(Palette.ember)
                        HStack {
                            if let url = ParkedCar.externalMapURL(for: car) { Link("Apple Maps", destination: url) }
                            Button("Edit") { router.openMapTool(.parkedCar) }
                            Button("Clear", role: .destructive) { confirmClearCar = true }
                        }
                        .buttonStyle(.bordered).font(.fieldCaption)
                    }
                }
                .confirmationDialog("Clear the parked-car pin?", isPresented: $confirmClearCar, titleVisibility: .visible) {
                    Button("Clear pin", role: .destructive) { saved.setCar(nil) }
                } message: { Text("Removes the pin and its note from this device.") }
            } else {
                HStack {
                    Text("No parked car pinned.").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Mark parked car") { router.openMapTool(.parkedCar) }.font(.fieldCaption)
                }
            }
            if let camp = saved.state.campsite {
                HStack {
                    Label(camp.label, systemImage: "tent.fill").font(.fieldCaption)
                    Spacer()
                    Button("Open") { router.push(.campground(camp.campgroundId), in: .trails) }.font(.fieldCaption)
                }
            } else { Text("No campsite marked.").font(.caption2).foregroundStyle(.secondary) }
            let places = saved.state.places.values.sorted { $0.savedAt > $1.savedAt }
            if places.isEmpty { Text("No saved places yet. Tap the star on any place.").font(.caption2).foregroundStyle(.secondary) }
            ForEach(places, id: \.placeId) { sp in
                // Saved hikes open the hike; Valley hikes also have a place record, park-wide hikes only a trail.
                let trail = c.trail(sp.placeId)
                if let name = trail?.name ?? c.place(sp.placeId)?.name {
                    Button { if trail != nil { router.push(.trail(sp.placeId), in: .trails) } else { router.push(.place(sp.placeId), in: .directory) } } label: {
                        HStack(alignment: .top) {
                            Image(systemName: trail != nil ? "figure.hiking" : "star.fill").foregroundStyle(Palette.accent).font(.caption)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name).font(.fieldCaption.weight(.semibold))
                                if let note = sp.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if let error = saved.storageError { Text(error).font(.caption2).foregroundStyle(Palette.ember) }
        }
    }
}

/// Verifies bundled resources against the pack manifest checksums.
@MainActor
final class OfflinePackStatus: ObservableObject {
    static let shared = OfflinePackStatus()

    struct Resource: Identifiable {
        let id: String
        let label: String
        let bytes: Int
        let state: SourceState
        let detail: String
    }

    @Published private(set) var resources: [Resource] = []
    @Published private(set) var missing: [String] = []
    @Published private(set) var checkedAt: Date?
    var totalBytes: Int { resources.reduce(0) { $0 + $1.bytes } }

    struct Manifest: Decodable {
        struct Geo: Decodable { var file: String; var bytes: Int; var sha256: String }
        var built: String
        var geo: [Geo]
    }

    nonisolated private static let labels: [String: String] = [
        "buildings.geojson": "Valley buildings", "parking.geojson": "Valley parking", "pois.geojson": "Valley points of interest",
        "roads.geojson": "Valley roads", "trails.geojson": "Valley trails & bike paths", "park-roads.geojson": "Park roads beyond the Valley", "park-trails.geojson": "Park trails (NPS)",
        "park-pois.geojson": "Park points of interest beyond the Valley", "park-buildings.geojson": "Park buildings beyond the Valley",
        "park-parking.geojson": "Park parking beyond the Valley", "park-water.geojson": "Park streams & lakes (NHD)", "park-names.geojson": "Park place names (GNIS)",
        "park-boundary.geojson": "Park boundary", "fire-scars.geojson": "Historical fire perimeters",
        "campsites.geojson": "Campsite inventory (RIDB)", "campground-context.geojson": "Campground roads & restrooms",
        "elevation-valley.json": "Sun/shadow terrain grid 320×152", "elevation-basemap.json": "Relief detail grid (20 m)",
        "elevation-park.json": "Park relief grid header (3DEP)", "elevation-park.bin": "Park relief grid (3DEP, ≈30 m)",
        "elevation-surround.json": "Surrounding relief header (3DEP)", "elevation-surround.bin": "Surrounding relief (3DEP, ≈250 m)",
        "transit.json": "Shuttle timetable (GTFS)", "map-manifest.json": "Valley pack manifest",
        "park-manifest.json": "Park pack manifest", "water-ice.json": "Water & ice records", "dump-stations.json": "RV dump stations",
        "waterways.geojson": "Rivers & creeks (NHD)",
    ]

    func verify(force: Bool = false) {
        if !force, checkedAt != nil { return }
        Task.detached(priority: .utility) {
            var rows: [Resource] = []
            var missing: [String] = []
            if let data = try? BundleContent.data("pack-manifest.json", subdirectory: "Content"), let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
                for geo in manifest.geo {
                    let label = Self.labels[geo.file] ?? geo.file
                    if let fileData = try? BundleContent.data(geo.file, subdirectory: "Geo") {
                        let ok = SHA256Digest.hex(fileData) == geo.sha256
                        rows.append(Resource(id: geo.file, label: label, bytes: fileData.count, state: ok ? .ready : .unavailable, detail: ok ? "checksum verified" : "checksum differs"))
                        if !ok { missing.append(geo.file) }
                    } else {
                        rows.append(Resource(id: geo.file, label: label, bytes: 0, state: .unavailable, detail: "missing"))
                        missing.append(geo.file)
                    }
                }
            }
            for name in ["places.json", "trails.json", "hike-routes.json", "campgrounds.json", "permits.json", "contacts.json", "events.json", "regions.json", "webcams.json", "documents.json", "status.json", "categories.json", "notices.json", "changelog.json", "housekeeping.json"] {
                if let d = try? BundleContent.data(name, subdirectory: "Content") {
                    rows.append(Resource(id: name, label: "Content · \(name.replacingOccurrences(of: ".json", with: ""))", bytes: d.count, state: .ready, detail: "present"))
                } else {
                    rows.append(Resource(id: name, label: "Content · \(name)", bytes: 0, state: .unavailable, detail: "missing"))
                    missing.append(name)
                }
            }
            if let docs = try? BundleContent.decode([DocumentItem].self, "documents.json") {
                for doc in docs {
                    if let d = try? BundleContent.data(doc.bundledFile, subdirectory: "Documents") {
                        let ok = SHA256Digest.hex(d) == doc.sha256
                        rows.append(Resource(id: doc.id, label: "PDF · \(doc.title)", bytes: d.count, state: ok ? .ready : .unavailable, detail: ok ? "checksum verified" : "checksum differs"))
                        if !ok { missing.append(doc.bundledFile) }
                    } else {
                        rows.append(Resource(id: doc.id, label: "PDF · \(doc.title)", bytes: 0, state: .unavailable, detail: "missing"))
                        missing.append(doc.bundledFile)
                    }
                }
            }
            let finalRows = rows, finalMissing = missing
            await MainActor.run {
                self.resources = finalRows
                self.missing = finalMissing
                self.checkedAt = Date()
            }
        }
    }
}

enum SHA256Digest {
    static func hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

import CommonCrypto
