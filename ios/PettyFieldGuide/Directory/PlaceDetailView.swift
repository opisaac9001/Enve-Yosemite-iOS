import SwiftUI
import CoreImage.CIFilterBuiltins

struct PlaceDetailView: View {
    let placeId: String
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var saved: SavedStore
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var conditions = ConditionsStore.shared
    @State private var noteDraft = ""
    @State private var showQR = false

    var body: some View {
        if let c = content.content, let place = c.place(placeId) {
            FieldScroll {
                header(place, c)
                if let notice = place.notice { noticeCard(notice) }
                relatedNotices(place, c)
                detailsCard(place)
                hoursCard(place)
                accessCard(place)
                specialCards(place, c)
                contactsCard(place)
                nearbyCard(place, c)
                relatedHikes(place, c)
                permitsCard(place, c)
                notesCard(place)
                sourcesCard(place)
            }
            .fieldNavigationTitle(place.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Button { saved.toggleSaved(place.id) } label: { Image(systemName: saved.isSaved(place.id) ? "star.fill" : "star") }
                            .accessibilityLabel(saved.isSaved(place.id) ? "Remove from saved" : "Save place")
                        if let url = AppRouter.url(for: .place(place.id)) {
                            ShareLink(item: url, subject: Text(place.name), message: Text("\(place.name) · \(place.campus) — Enve Yosemite")) { Image(systemName: "square.and.arrow.up") }
                        }
                        Button { showQR = true } label: { Image(systemName: "qrcode") }.accessibilityLabel("Show QR code")
                    }
                }
            }
            .sheet(isPresented: $showQR) { QRSheet(title: place.name, url: AppRouter.url(for: .place(place.id))) }
            .onAppear { noteDraft = saved.state.places[place.id]?.note ?? "" }
        } else {
            EmptyStateView(symbol: "mappin.slash", title: "Place not found", message: "This link points to a place that is not in the bundled directory.")
        }
    }

    // MARK: Sections

    private func header(_ place: Place, _ c: Content) -> some View {
        FieldCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(place.categories, id: \.self) { id in
                        if let cat = c.category(id) {
                            Label(cat.label, systemImage: cat.symbol).font(.fieldCaption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color(hex: cat.color).opacity(0.18), in: Capsule())
                        }
                    }
                }
                Text(place.campus).font(.fieldEyebrow).foregroundStyle(.secondary)
                Text(place.summary).font(.fieldBody)
                HStack {
                    // A hike's place record sits at its trailhead; the map shows the whole default route instead of that pin.
                    Button { router.showOnMap(place.kind == .trail ? .trail(place.id) : .place(place.id)) } label: { Label(place.kind == .trail ? "Show route on map" : "Show on map", systemImage: "map") }
                    if place.kind == .shuttleStop, let n = place.stopNumber {
                        Button { router.push(.stop(n), in: .navigation) } label: { Label("Timetable", systemImage: "clock") }
                    }
                    if let cgId = place.campgroundId {
                        Button { router.push(.campground(cgId), in: .trails) } label: { Label("Campground", systemImage: "tent") }
                    }
                }
                .buttonStyle(.borderedProminent).font(.fieldCaption)
                if let checked = place.checked {
                    Text("Reviewed \(DateText.long(checked)). Hours and access are a dated snapshot, not live status.").font(.fieldCaption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func noticeCard(_ notice: String) -> some View {
        FieldCard(eyebrow: "Notice") {
            Label { Text(notice).font(.fieldBody) } icon: { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.accent) }
        }
    }

    @ViewBuilder private func relatedNotices(_ place: Place, _ c: Content) -> some View {
        let matches = NoticeMatcher.notices(for: place, content: c, snapshot: conditions.conditions)
        if !matches.isEmpty {
            FieldCard(title: "Mentions this place", eyebrow: "Current official notices") {
                ForEach(matches) { item in NoticeRow(item: item) }
                SnapshotFooter(snapshot: conditions.conditions)
            }
        }
    }

    @ViewBuilder private func detailsCard(_ place: Place) -> some View {
        if !place.details.isEmpty {
            FieldCard(eyebrow: "Details") { LabeledTextList(items: place.details) }
        }
    }

    @ViewBuilder private func hoursCard(_ place: Place) -> some View {
        if !place.hours.isEmpty {
            FieldCard(eyebrow: "Hours & season") {
                ForEach(place.hours, id: \.self) { Text($0).font(.fieldBody) }
            }
        }
    }

    private func accessCard(_ place: Place) -> some View {
        FieldCard(eyebrow: "Access") {
            Label(AccessScope.title(place.accessScope), systemImage: "person.2").font(.fieldBody)
            if let a = place.accessibility {
                Label { Text(a).font(.fieldBody) } icon: { Image(systemName: "figure.roll") }
            }
            if place.facility == "toilet" { Label("Toilet", systemImage: "toilet").font(.fieldCaption) }
            if place.facility == "shower" || place.glyph == "SH" { Label("Showers", systemImage: "shower").font(.fieldCaption) }
            if place.isWater { Label("Drinking water", systemImage: "drop").font(.fieldCaption) }
            if place.isIce { Label("Ice machine", systemImage: "snowflake").font(.fieldCaption) }
            if place.guestArea == true { Text("Inside a lodging or campground area; intended for registered guests.").font(.fieldCaption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func specialCards(_ place: Place, _ c: Content) -> some View {
        if let ev = place.charging {
            FieldCard(eyebrow: "EV charging · installed inventory") {
                LabeledContent("Ports", value: "\(ev.count)")
                if let n = ev.network { LabeledContent("Network", value: n) }
                if let con = ev.connector { LabeledContent("Plug", value: con) }
                if let kw = ev.maxKw { LabeledContent("Rated power", value: String(format: "up to %g kW per port", kw)) }
                Text("No live availability or working-status feed exists in this guide.").font(.fieldCaption).foregroundStyle(.secondary)
            }
        }
        if let dump = place.dumpStation {
            FieldCard(eyebrow: "RV dump station") {
                LabeledContent("Published season", value: dump.status.replacingOccurrences(of: "-", with: " "))
                Text("Location and normal season only; current operation is not observed.").font(.fieldCaption).foregroundStyle(.secondary)
            }
        }
        if let wf = place.waterfall {
            FieldCard(eyebrow: "Waterfall · normal season, not current flow") {
                if let h = wf.height { LabeledContent("Height", value: h) }
                if let s = wf.normalSeason { LabeledTextList(items: [LabeledText(label: "Normal season", text: s)]) }
                if let v = wf.viewing { LabeledTextList(items: [LabeledText(label: "Viewing", text: v)]) }
                if let closure = wf.closure {
                    Label { Text("\(closure)\(wf.closureAsOf.map { " (as of \(DateText.long($0)))" } ?? "")") } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(.fieldCaption)
                }
                if let links = wf.links, !links.isEmpty {
                    ForEach(links, id: \.label) { link in
                        if let pid = link.placeId, c.place(pid) != nil || c.trail(pid) != nil {
                            Button { open(placeOrTrail: pid, c) } label: { Label(link.label, systemImage: "arrow.right.circle") }.font(.fieldCaption)
                        } else if let u = link.url, let url = URL(string: u) {
                            ExternalLinkRow(label: link.label, url: url)
                        }
                        if let note = link.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        if let bridge = place.bridge {
            FieldCard(eyebrow: "Bridge · schematic") {
                BridgeSchematic(segments: bridge.segments)
                    .frame(height: 110)
                if let basis = bridge.locationBasis { Text(basis).font(.fieldCaption).foregroundStyle(.secondary) }
                Text("Original schematic from the NPS line records; not an engineering drawing.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        if let wi = place.waterIce {
            FieldCard(eyebrow: wi.kind == "ice" ? "Ice machine" : "Drinking water") {
                if let t = wi.type { LabeledContent("Type", value: t.replacingOccurrences(of: "-", with: " ")) }
                if let d = wi.directions { Text(d).font(.fieldBody) }
                if let warning = wi.warning {
                    Label { Text(warning).font(.fieldCaption) } icon: { Image(systemName: "exclamationmark.triangle") }.foregroundStyle(Palette.ember)
                }
                if let basis = wi.locationBasis { Text(basis).font(.fieldCaption).foregroundStyle(.secondary) }
                if let evidence = wi.evidenceNote { Text(evidence).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        if let menus = place.menus {
            FieldCard(eyebrow: "Official menus") {
                if menus.status == "official-pdf" {
                    ForEach(menus.documents, id: \.id) { doc in
                        if let url = URL(string: doc.url) {
                            VStack(alignment: .leading, spacing: 2) {
                                ExternalLinkRow(label: doc.label, url: url)
                                Text([doc.publisher, doc.pdfCreated.map { "PDF dated \(DateText.long($0))" }, doc.pages.map { "\($0) pages" }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else if let note = menus.note {
                    Text(note).font(.fieldBody)
                }
                if let page = menus.page, let u = page.url, let url = URL(string: u) { ExternalLinkRow(label: page.label, url: url) }
                if let seeAlso = menus.seeAlso, c.place(seeAlso.placeId) != nil {
                    Button { router.push(.place(seeAlso.placeId)) } label: { Label(seeAlso.label, systemImage: "arrow.right.circle") }.font(.fieldCaption)
                }
                if let checked = menus.checked { Text("Menus checked \(DateText.long(checked)); prices and items change without notice.").font(.fieldCaption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private func contactsCard(_ place: Place) -> some View {
        if !place.phones.isEmpty {
            FieldCard(eyebrow: "Phone") {
                ForEach(place.phones, id: \.number) { PhoneRow(phone: $0) }
            }
        }
    }

    @ViewBuilder private func nearbyCard(_ place: Place, _ c: Content) -> some View {
        if !place.nearbyStops.isEmpty && place.kind != .shuttleStop {
            FieldCard(eyebrow: "Nearby shuttle stops") {
                ForEach(place.nearbyStops, id: \.self) { n in
                    if let stop = c.place("shuttle-\(n)") {
                        Button { router.push(.place(stop.id)) } label: {
                            HStack { Text(stop.name).font(.fieldBody); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder private func relatedHikes(_ place: Place, _ c: Content) -> some View {
        let hikes = c.trails.trails.filter { t in
            t.shuttleStops.contains(where: { place.stopNumber == $0 }) || t.id == place.trailId || (place.kind == .waterfall && t.name.localizedCaseInsensitiveContains(place.name.replacingOccurrences(of: " Falls", with: "").replacingOccurrences(of: " Fall", with: "")))
        }
        if !hikes.isEmpty {
            FieldCard(eyebrow: "Related hikes") {
                ForEach(hikes) { hike in
                    Button { router.push(.trail(hike.id), in: .trails) } label: {
                        HStack { Label(hike.name, systemImage: "figure.hiking").font(.fieldBody); Spacer(); Text(hike.difficulty).font(.fieldCaption).foregroundStyle(.secondary) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private func permitsCard(_ place: Place, _ c: Content) -> some View {
        let guides = c.permits.guides.filter { ($0.places ?? []).contains(place.id) || ($0.places ?? []).contains(place.trailId ?? "") }
        if !guides.isEmpty {
            FieldCard(eyebrow: "Permits that apply") {
                ForEach(guides) { g in
                    Button { router.push(.permit(g.id), in: .permits) } label: {
                        HStack { Label(g.title, systemImage: "checkmark.seal").font(.fieldBody); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func notesCard(_ place: Place) -> some View {
        FieldCard(eyebrow: "My note · stays on this device") {
            TextField("Add a private note", text: $noteDraft, axis: .vertical)
                .lineLimit(1...5)
                .onSubmit { saved.setNote(noteDraft, for: place.id) }
            HStack {
                Button("Save note") { saved.setNote(noteDraft, for: place.id) }.buttonStyle(.bordered).font(.fieldCaption)
                    .disabled(noteDraft == (saved.state.places[place.id]?.note ?? ""))
                Spacer()
                Text("Notes are never included in shared links.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func sourcesCard(_ place: Place) -> some View {
        let listed = place.sources.isEmpty ? (place.sourceUrl.map { [SourceLink(label: "Source page", url: $0)] } ?? []) : place.sources
        return FieldCard(eyebrow: "Sources & freshness") {
            SourceList(sources: listed, note: place.sourceNote, checked: place.checked)
            if let u = place.sourceUrl, let url = URL(string: u), !listed.contains(where: { $0.url == u }) {
                ExternalLinkRow(label: "Primary source", url: url)
            }
        }
    }

    private func open(placeOrTrail id: String, _ c: Content) {
        if c.trail(id) != nil { router.push(.trail(id), in: .trails) } else { router.push(.place(id)) }
    }
}

/// Original schematic drawing of a bridge from its NPS line segments.
struct BridgeSchematic: View {
    let segments: [[[Double]]]

    var body: some View {
        Canvas { ctx, size in
            let pts = segments.flatMap { $0 }.map { CGPoint(x: $0[1], y: $0[0]) }
            guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(), let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() else { return }
            let spanX = max(maxX - minX, 0.00002), spanY = max(maxY - minY, 0.00002)
            let scale = min((size.width - 40) / spanX, (size.height - 40) / spanY)
            func map(_ p: CGPoint) -> CGPoint {
                CGPoint(x: 20 + (p.x - minX) * scale + ((size.width - 40) - spanX * scale) / 2,
                        y: size.height - 20 - (p.y - minY) * scale - ((size.height - 40) - spanY * scale) / 2)
            }
            // Water band under the deck.
            var water = Path()
            water.addRect(CGRect(x: 0, y: size.height * 0.35, width: size.width, height: size.height * 0.3))
            ctx.fill(water, with: .color(Palette.river.opacity(0.25)))
            for seg in segments {
                var path = Path()
                let mapped = seg.map { map(CGPoint(x: $0[1], y: $0[0])) }
                path.addLines(mapped)
                ctx.stroke(path, with: .color(Palette.granite), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                ctx.stroke(path, with: .color(Palette.accent), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            ctx.draw(Text("N ↑").font(.caption2), at: CGPoint(x: size.width - 18, y: 12))
        }
        .accessibilityLabel("Schematic plan of the bridge deck over the water")
    }
}

struct QRSheet: View {
    let title: String
    let url: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let url, let image = QRCode.image(for: url.absoluteString) {
                    Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 260)
                    Text(url.absoluteString).font(.fieldMono).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Opens this place in Enve Yosemite on another device. Shared links never include notes, your car or your campsite.").font(.fieldCaption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

enum QRCode {
    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
