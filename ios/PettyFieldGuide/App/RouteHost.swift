import SwiftUI

struct RouteHost: View {
    let route: Route

    var body: some View {
        switch route {
        case .place(let id): PlaceDetailView(placeId: id)
        case .trail(let id): TrailDetailView(trailId: id)
        case .hikeRoute(let trailId, let routeId): TrailDetailView(trailId: trailId, routeId: routeId)
        case .campground(let id): CampgroundDetailView(campgroundId: id)
        case .site(let cg, let ridb): SiteDetailView(campgroundId: cg, ridbId: ridb)
        case .housekeepingUnit(let unit): PlaceDetailView(placeId: "housekeeping-unit-\(unit)")
        case .event(let id): EventDetailView(eventId: id)
        case .permit(let id): PermitDetailView(guideId: id)
        case .contact(let id): ContactDetailView(contactId: id)
        case .document(let id): DocumentDetailView(documentId: id)
        case .region(let id): RegionDetailView(regionId: id)
        case .stop(let n): StopTimetableView(stopNumber: n)
        case .webcam(let id): WebcamDetailView(webcamId: id)
        case .explorerLayer(let id): ExplorerLayerView(layerId: id)
        case .riskCheck(let id): RiskCheckDetailView(checkId: id)
        case .fireIncident(let id): FireIncidentDetailView(incidentId: id)
        case .planner: PlannerView()
        }
    }
}

struct SheetHost: View {
    let sheet: AppSheet
    @EnvironmentObject private var content: ContentStore

    var body: some View {
        switch sheet {
        case .settings: SettingsSheet()
        case .updates: UpdatesSheet(initialTab: .updates)
        case .changelog: UpdatesSheet(initialTab: .changelog)
        case .suggestions: UpdatesSheet(initialTab: .suggestions)
        case .introGuide: IntroGuideSheet()
        case .backup: BackupSheet()
        case .waterIceGuide:
            if let c = content.content { WaterIceGuideView(content: c) }
        case .share(let link): ShareSheetView(title: link.title, url: link.url)
        }
    }
}

struct ShareSheetView: View {
    let title: String
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ShareLink(item: url, subject: Text(title)) { Label("Share link", systemImage: "square.and.arrow.up") }.buttonStyle(.borderedProminent)
                if let image = QRCode.image(for: url.absoluteString) {
                    Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 240)
                }
                Text(url.absoluteString).font(.fieldMono).textSelection(.enabled).foregroundStyle(.secondary)
            }
            .padding(24)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

struct SettingsEntryCard: View {
    @EnvironmentObject private var router: AppRouter
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("App").font(.fieldEyebrow).foregroundStyle(.secondary).textCase(.uppercase)
            HStack(spacing: 12) {
                entry("Appearance & text", "paintbrush") { router.sheet = .settings }
                entry("Updates & feedback", "bell") { router.sheet = .updates }
                entry("Intro guide", "questionmark.circle") { router.sheet = .introGuide }
            }
        }
    }

    private func entry(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title3).foregroundStyle(Palette.accent)
                Text(title).font(.fieldCaption).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(Palette.card(scheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
