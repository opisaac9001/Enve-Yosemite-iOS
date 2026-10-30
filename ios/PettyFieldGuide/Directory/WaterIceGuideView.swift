import SwiftUI

/// The bundled water/ice pack exactly as shipped. Keeps the provenance fields the directory `Place` drops.
struct WaterIcePack: Decodable, Sendable {
    struct Metadata: Decodable, Sendable {
        var kind: String
        var type: WaterIceType
        var directions: String?
        var locationBasis: String?
        var checked: String?
        var sources: [SourceLink]?
        var evidenceNote: String?
        var communityMapped: Bool?
        var warning: String?
    }

    struct Record: Decodable, Sendable {
        var id: String
        var name: String
        var campus: String
        var latitude: Double
        var longitude: Double
        var summary: String
        var hours: [String]
        var accessScope: String?
        var notice: String?
        var tags: [String]
        var waterIce: Metadata
    }

    var checked: String
    var attribution: String
    var license: String
    var licenseUrl: String
    var places: [Record]

    static let fileName = "water-ice.json"
    static var bundledURL: URL? { BundleContent.resourceURL(fileName, subdirectory: "Geo") }
    static func load() throws -> WaterIcePack { try BundleContent.decode(WaterIcePack.self, fileName, subdirectory: "Geo") }
}

enum WaterIceType: String, Decodable, Sendable {
    case faucet
    case drinkingWater = "drinking-water"
    case bottleFiller = "bottle-filler"
    case iceMachine = "ice-machine"

    var title: String {
        switch self {
        case .faucet: "Campground faucet"
        case .drinkingWater: "Drinking water"
        case .bottleFiller: "Bottle filler"
        case .iceMachine: "Ice machine"
        }
    }

    var isWater: Bool { self != .iceMachine }
}

enum WaterIceFilter: String, CaseIterable, Identifiable, Sendable {
    case all, allWater, faucets, bottleFillers, iceMachines

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .allWater: "All water"
        case .faucets: "Campground faucets"
        case .bottleFillers: "Bottle fillers"
        case .iceMachines: "Ice machines"
        }
    }

    var symbol: String? {
        switch self {
        case .all: nil
        case .allWater: "drop"
        case .faucets: "spigot"
        case .bottleFillers: "waterbottle"
        case .iceMachines: "snowflake"
        }
    }

    func includes(_ type: WaterIceType) -> Bool {
        switch self {
        case .all: true
        case .allWater: type.isWater
        case .faucets: type == .faucet
        case .bottleFillers: type == .bottleFiller
        case .iceMachines: type == .iceMachine
        }
    }
}

/// Directory wording merged with the pack's provenance for one tap or machine. Also the navigation value for its detail.
struct WaterIceRecord: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let area: String
    let latitude: Double
    let longitude: Double
    let type: WaterIceType
    let summary: String
    let hours: [String]
    let accessScope: String?
    let caveat: String?          // generic "recorded, not live" note; nil when a dated warning replaces it
    let warning: String?         // an old or unverified report, never a current status
    let directions: String?
    let locationBasis: String?
    let checked: String?
    let sources: [SourceLink]
    let evidenceNote: String?
    let communityMapped: Bool
    let searchText: String

    var isInValley: Bool { YosemiteGeo.valleyBounds.contains(latitude: latitude, longitude: longitude) }
    var glyph: String { type.isWater ? "H₂O" : "ICE" }
}

enum WaterIceAction: Hashable {
    case focusValleyMap(placeId: String)
    case openExternalMap(latitude: Double, longitude: Double, label: String)
}

struct WaterIceGroup: Identifiable, Sendable {
    let area: String
    let records: [WaterIceRecord]
    var id: String { area }
}

enum WaterIceGuide {
    static let oldReportLabel = "Old report · not a current status"
    static let recordedNotLive = "These are recorded locations, not live availability. Seasonal shut-offs, repairs and access rules change; follow posted signs."

    /// Directory text wins for wording; the pack supplies type, directions, location basis, evidence and warnings.
    static func records(from pack: WaterIcePack, content: Content) -> [WaterIceRecord] {
        pack.places.map { raw in
            let place = content.place(raw.id)
            let meta = raw.waterIce
            let summary = place?.summary ?? raw.summary
            let notice = place?.notice ?? raw.notice
            let sources = meta.sources ?? []
            let accessScope = place?.accessScope ?? raw.accessScope
            var haystack = [raw.name, raw.campus, summary, meta.type.title, AccessScope.title(accessScope)] + raw.hours + raw.tags + sources.map(\.label)
            haystack += [meta.directions, meta.locationBasis, meta.evidenceNote, notice].compactMap { $0 }
            if meta.communityMapped == true { haystack.append("community mapped openstreetmap") }
            let hasWarning = meta.warning != nil
            return WaterIceRecord(
                id: raw.id, name: place?.name ?? raw.name, area: place?.campus ?? raw.campus,
                latitude: raw.latitude, longitude: raw.longitude, type: meta.type,
                summary: summary, hours: place?.hours ?? raw.hours, accessScope: accessScope,
                caveat: hasWarning ? nil : notice,
                warning: hasWarning ? (place?.notice ?? meta.warning) : nil,
                directions: meta.directions, locationBasis: meta.locationBasis, checked: meta.checked,
                sources: sources, evidenceNote: meta.evidenceNote, communityMapped: meta.communityMapped ?? false,
                searchText: SearchIndex.normalise(haystack.joined(separator: " ")))
        }
    }

    /// Every query token must appear somewhere in the record's searchable text.
    static func filtered(_ records: [WaterIceRecord], filter: WaterIceFilter, query: String) -> [WaterIceRecord] {
        let tokens = SearchIndex.tokens(query)
        return records.filter { r in filter.includes(r.type) && tokens.allSatisfy { r.searchText.contains($0) } }
    }

    static func grouped(_ records: [WaterIceRecord]) -> [WaterIceGroup] {
        var order: [String] = []
        var buckets: [String: [WaterIceRecord]] = [:]
        for r in records {
            if buckets[r.area] == nil { order.append(r.area) }
            buckets[r.area, default: []].append(r)
        }
        return order.map { WaterIceGroup(area: $0, records: buckets[$0] ?? []) }
    }

    /// Points inside the bundled Valley extent focus their real pin; anything beyond it is never clamped to the edge.
    static func action(for record: WaterIceRecord) -> WaterIceAction {
        record.isInValley ? .focusValleyMap(placeId: record.id) : .openExternalMap(latitude: record.latitude, longitude: record.longitude, label: record.name)
    }

    static func externalMapURL(latitude: Double, longitude: Double, label: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"), URLQueryItem(name: "q", value: label)]
        return components.url
    }

    static func externalMapURL(for record: WaterIceRecord) -> URL? {
        externalMapURL(latitude: record.latitude, longitude: record.longitude, label: record.name)
    }
}

// MARK: - Views

struct WaterIceGuideView: View {
    let content: Content
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var state: GuideState = .loading

    private enum GuideState {
        case loading
        case ready(WaterIcePack, [WaterIceRecord])
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            switch state {
            case .loading:
                ProgressView("Reading the water & ice pack…")
                    .navigationTitle("Water & ice")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { doneButton }
            case .failed(let message):
                EmptyStateView(symbol: "drop.triangle", title: "Guide unavailable", message: message)
                    .navigationTitle("Water & ice")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { doneButton }
            case .ready(let pack, let records):
                WaterIceListView(pack: pack, records: records, perform: perform)
                    .toolbar { doneButton }
            }
        }
        .task { await load() }
    }

    private var doneButton: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
    }

    private func load() async {
        guard case .loading = state else { return }
        let content = self.content
        do {
            let (pack, records) = try await Task.detached {
                let pack = try WaterIcePack.load()
                return (pack, WaterIceGuide.records(from: pack, content: content))
            }.value
            state = .ready(pack, records)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func perform(_ action: WaterIceAction) {
        switch action {
        case .focusValleyMap(let placeId):
            dismiss()
            router.showOnMap(.place(placeId))
        case .openExternalMap(let lat, let lon, let label):
            if let url = WaterIceGuide.externalMapURL(latitude: lat, longitude: lon, label: label) { openURL(url) }
        }
    }
}

/// The stack's root: inline search, filters and grouped rows. The search field is an ordinary text
/// field inside the list rather than the navigation-bar search controller, which left the sheet
/// without its bar after returning from a detail; title and destinations stay on the list itself.
struct WaterIceListView: View {
    let pack: WaterIcePack
    let records: [WaterIceRecord]
    let perform: (WaterIceAction) -> Void
    @State private var filter: WaterIceFilter = .all
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let shown = WaterIceGuide.filtered(records, filter: filter, query: query)
        List {
            Section {
                searchField
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(WaterIceFilter.allCases) { f in
                            let count = records.filter { f.includes($0.type) }.count
                            ChipButton(title: "\(f.title) · \(count)", symbol: f.symbol, active: filter == f) { filter = f }
                                .accessibilityLabel("\(f.title), \(count) locations")
                        }
                    }
                }
                Text("\(shown.count) of \(records.count) locations")
                    .font(.fieldCaption.weight(.semibold))
                    .accessibilityLabel("\(shown.count) of \(records.count) locations shown")
                Text(WaterIceGuide.recordedNotLive).font(.fieldCaption).foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

            if shown.isEmpty {
                Section {
                    EmptyStateView(symbol: "mappin.slash", title: "No location matches", message: "Try another name, area or campground, or change the type filter.")
                    Button("Clear search and filter") { query = ""; filter = .all }
                        .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(WaterIceGuide.grouped(shown)) { group in
                    Section("\(group.area) · \(group.records.count)") {
                        ForEach(group.records) { record in
                            NavigationLink(value: record) { WaterIceRow(record: record) }
                        }
                    }
                }
            }

            Section {
                WaterIceSourcesCard(pack: pack, communityMapped: records.filter(\.communityMapped).count)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Water & ice")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .navigationDestination(for: WaterIceRecord.self) { record in
            WaterIceRecordView(record: record, pack: pack, perform: perform)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Name, area, directions or source", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($searchFocused)
                .accessibilityLabel("Search water and ice locations")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { searchFocused = true }
    }
}

struct WaterIceRow: View {
    let record: WaterIceRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(record.type.isWater ? Palette.river : Palette.granite).frame(width: 34, height: 34)
                Text(record.glyph).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).font(.fieldBody.weight(.semibold))
                Text("\(record.type.title) · \(AccessScope.title(record.accessScope))").font(.fieldCaption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if record.warning != nil { Label("Old report", systemImage: "clock.arrow.circlepath").foregroundStyle(Palette.ember) }
                    if record.communityMapped { Label("Community mapped", systemImage: "person.2") }
                    if !record.isInValley { Label("Outside the Valley map", systemImage: "arrow.up.right.square") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct WaterIceRecordView: View {
    let record: WaterIceRecord
    let pack: WaterIcePack
    let perform: (WaterIceAction) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let warning = record.warning {
                    FieldCard(eyebrow: WaterIceGuide.oldReportLabel) {
                        Label { Text(warning).font(.fieldBody) } icon: { Image(systemName: "clock.arrow.circlepath").foregroundStyle(Palette.ember) }
                        Text("Nothing newer than this report is in the dataset. It is not a current outage notice and not a confirmation that the tap works.").font(.fieldCaption).foregroundStyle(.secondary)
                    }
                }
                FieldCard(eyebrow: "Hours & season") {
                    ForEach(record.hours, id: \.self) { Text($0).font(.fieldBody) }
                    if let caveat = record.caveat { Text(caveat).font(.fieldCaption).foregroundStyle(.secondary) }
                }
                if let directions = record.directions {
                    FieldCard(eyebrow: "Directions") { Text(directions).font(.fieldBody) }
                }
                FieldCard(eyebrow: "Where the pin comes from") {
                    if let basis = record.locationBasis { Text(basis).font(.fieldBody) }
                    if let evidence = record.evidenceNote { Text(evidence).font(.fieldCaption).foregroundStyle(.secondary) }
                    if record.communityMapped {
                        Label("Community-mapped position from OpenStreetMap. Retrieving the record is not a field inspection.", systemImage: "person.2")
                            .font(.fieldCaption).foregroundStyle(.secondary)
                    }
                    if !record.isInValley {
                        Text(String(format: "Recorded at %.6f, %.6f, beyond the bundled Valley map.", record.latitude, record.longitude)).font(.fieldCaption).foregroundStyle(.secondary)
                    }
                }
                FieldCard(eyebrow: "Sources & freshness") {
                    SourceList(sources: record.sources, checked: record.checked)
                    Text("\(pack.attribution) · \(pack.license) · pack checked \(DateText.long(pack.checked))").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .navigationTitle(record.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        FieldCard {
            Text("\(record.type.title) · \(record.area)").font(.fieldEyebrow).foregroundStyle(.secondary)
            Text(record.summary).font(.fieldBody)
            Label(AccessScope.title(record.accessScope), systemImage: "person.2").font(.fieldCaption)
            switch WaterIceGuide.action(for: record) {
            case .focusValleyMap:
                Button { perform(.focusValleyMap(placeId: record.id)) } label: { Label("Show on the Valley map", systemImage: "map") }
                    .buttonStyle(.borderedProminent).font(.fieldCaption)
                    .accessibilityHint("Closes this guide and focuses the pin")
            case .openExternalMap(let lat, let lon, let label):
                Button { perform(.openExternalMap(latitude: lat, longitude: lon, label: label)) } label: { Label("Open in Apple Maps", systemImage: "arrow.up.right.square") }
                    .buttonStyle(.borderedProminent).font(.fieldCaption)
                    .accessibilityHint("Opens the recorded coordinates in Apple Maps because this point is outside the Valley map")
                Text("Outside the bundled Valley map, so it opens at its recorded coordinates in Apple Maps instead of being pushed to the map edge.").font(.fieldCaption).foregroundStyle(.secondary)
            }
        }
    }
}

struct WaterIceSourcesCard: View {
    let pack: WaterIcePack
    let communityMapped: Int

    var body: some View {
        FieldCard(eyebrow: "Dataset & licence") {
            Text("\(pack.places.count) records: NPS restroom and drinking-water points, official property maps and \(communityMapped) community-mapped OpenStreetMap points. Each record lists its own official or OSM links.").font(.fieldCaption)
            Text(pack.attribution).font(.fieldCaption)
            if let url = URL(string: pack.licenseUrl) { ExternalLinkRow(label: "Licence · \(pack.license)", url: url) }
            if let url = URL(string: "https://www.openstreetmap.org/copyright") { ExternalLinkRow(label: "OpenStreetMap copyright and attribution", url: url) }
            Text("Pack checked \(DateText.long(pack.checked)). Source retrieval is not a field inspection.").font(.caption2).foregroundStyle(.secondary)
            if let file = WaterIcePack.bundledURL {
                ShareLink(item: file, preview: SharePreview("Water & ice locations (\(WaterIcePack.fileName))")) {
                    Label("Export the bundled location data", systemImage: "square.and.arrow.up")
                }
                .font(.fieldCaption)
                Text("Shares the JSON file exactly as bundled, with its attribution and licence fields.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
