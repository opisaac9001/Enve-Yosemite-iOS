import SwiftUI
import CoreLocation

enum FireMapMode: String, CaseIterable, Identifiable {
    case automatic, live, past
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .live: "Live layers"
        case .past: "Past burns"
        }
    }
}

struct FireScreen: View {
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var conditions = ConditionsStore.shared
    @State private var mode: FireMapMode = .automatic
    @State private var tapped: String?

    var body: some View {
        if let c = content.content {
            FieldScroll {
                assessment
                mapCard(c)
                regionalSummaries(c)
                incidents(c)
                airCard
                restrictionsCard(c)
                fireWeather
                officialNotices
                FieldCard(eyebrow: "External fire maps") {
                    ForEach(Array(c.status.fireLinks.sorted { $0.key < $1.key }), id: \.key) { key, u in
                        if let url = URL(string: u) { ExternalLinkRow(label: fireLinkLabel(key), url: url) }
                    }
                }
            }
            .fieldNavigationTitle("Fire & smoke")
            .task { await conditions.refreshStale() }
        }
    }

    private func fireLinkLabel(_ key: String) -> String {
        switch key {
        case "airnowFireMap": "AirNow fire & smoke map"
        case "hrrrSmoke": "HRRR smoke model (SSEC)"
        case "npsCurrentData": "NPS air quality current data"
        case "npsWebcam": "NPS air quality webcam"
        case "airnowYosemite": "AirNow · Yosemite"
        case "calfire": "CAL FIRE incidents"
        default: key
        }
    }

    private var assessment: some View {
        FieldCard {
            FeedHeader(title: "Fire planning assessment", snapshot: conditions.fire, refreshing: conditions.isRefreshing("fire"), error: conditions.errors["fire"]) { Task { await conditions.refresh(.fire) } }
            if let snap = conditions.fire, !snap.isExpired {
                let a = snap.payload.assessment
                HStack(spacing: 8) {
                    Text("Level \(a.priority)").font(.fieldCaption.weight(.bold)).padding(.horizontal, 8).padding(.vertical, 3).background(priorityColor(a.priority).opacity(0.25), in: Capsule())
                    Text(a.label).font(.fieldHeading)
                }
                ForEach(a.reasons, id: \.self) { Label($0, systemImage: "arrow.turn.down.right").font(.fieldCaption) }
                Text("Inputs").font(.fieldEyebrow).foregroundStyle(.secondary)
                ForEach(a.inputs.keys.sorted(), id: \.self) { k in LabeledContent(k, value: a.inputs[k] ?? "").font(.caption2) }
                Text(a.heuristicNote).font(.caption2).foregroundStyle(Palette.ember)
                FeedStatusList(statuses: snap.payload.statuses)
            } else if conditions.fire != nil {
                Text("The saved assessment is older than 48 hours and is not shown as current.").font(.fieldCaption).foregroundStyle(Palette.ember)
            } else {
                Text("No saved assessment. This app never classifies conditions as safe without inputs.").font(.fieldCaption).foregroundStyle(.secondary)
            }
        }
    }

    private func priorityColor(_ p: Int) -> Color {
        switch p {
        case ...1: Palette.meadow
        case 2...3: Palette.accent
        default: Palette.ember
        }
    }

    private func mapCard(_ c: Content) -> some View {
        FieldCard(eyebrow: "Park-wide fire map") {
            Picker("Mode", selection: $mode) { ForEach(FireMapMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            ParkMapView(mode: .fire, onSelect: { id in handleTap(id, c) }, frameContent: fireContent(c), height: 360)
            if let tapped { Text(tapped).font(.fieldCaption) }
            legend
        }
    }

    private var effectiveMode: FireMapMode {
        guard mode == .automatic else { return mode }
        if let snap = conditions.smoke, !snap.isExpired, !snap.payload.incidents.items.isEmpty || !snap.payload.hotspots.items.isEmpty { return .live }
        return .past
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(effectiveMode == .past ? "Past burns: CAL FIRE FRAP perimeters (orange tint). Live layers appear when a saved smoke snapshot has incidents or heat." : "Live: NIFC perimeters (red outline), VIIRS heat by age (red <6 h, orange 6–12 h, amber 12–24 h, grey 24–48 h), NOAA HMS plumes (grey fill), monitors (blue), incidents (flame).").font(.caption2).foregroundStyle(.secondary)
            if let snap = conditions.smoke { SnapshotFooter(snapshot: snap) }
        }
    }

    private func fireContent(_ c: Content) -> MapFrameContent {
        var frame = MapFrameContent()
        guard effectiveMode == .live, let snap = conditions.smoke, !snap.isExpired else { return frame }
        let projection = MapSceneBuilder.projection
        let feed = snap.payload
        for poly in feed.plumes.polygons ?? [] {
            let ring = poly.ring.map { projection.project(CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0])) }
            let alpha: CGFloat = poly.density == "Heavy" ? 0.45 : poly.density == "Medium" ? 0.3 : 0.18
            frame.overlayAreas.append(MapOverlayArea(id: "plume-\(poly.density)-\(poly.start ?? "")", rings: [ring], fillHex: "#555555", fillAlpha: alpha, strokeHex: nil, title: "\(poly.density) smoke · HMS \(poly.start.map(DateText.long) ?? "")"))
        }
        for per in feed.perimeters.items {
            let rings = per.rings.map { $0.map { projection.project(CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0])) } }
            frame.overlayAreas.append(MapOverlayArea(id: "perimeter-\(per.id)", rings: rings, fillHex: "#C93B2E", fillAlpha: 0.2, strokeHex: "#C93B2E", title: "\(per.name): \(per.acres.map { "\(Int($0)) acres" } ?? "")"))
        }
        let now = Date()
        for (i, h) in feed.hotspots.items.enumerated() {
            let age = now.timeIntervalSince(DateText.parse(h.acquiredAt) ?? now) / 3600
            let color = age <= 6 ? "#E53935" : age <= 12 ? "#FB8C00" : age <= 24 ? "#FDD835" : "#9E9E9E"
            frame.markers.append(MapMarker(id: "hotspot-\(i)", point: projection.project(CLLocationCoordinate2D(latitude: h.latitude, longitude: h.longitude)), title: "VIIRS detection", colorHex: color, priority: 3, shape: .dot, clusterable: false))
        }
        for r in feed.airnow.readings where r.latitude != nil && r.longitude != nil {
            frame.markers.append(MapMarker(id: "monitor-\(r.site)", point: projection.project(CLLocationCoordinate2D(latitude: r.latitude!, longitude: r.longitude!)), title: r.site, glyph: r.aqi.map { "\(Int($0))" }, colorHex: "#3B7EA8", priority: 4, shape: .badge, clusterable: false))
        }
        for inc in feed.incidents.items {
            frame.markers.append(MapMarker(id: "incident-\(inc.id)", point: projection.project(CLLocationCoordinate2D(latitude: inc.latitude, longitude: inc.longitude)), title: inc.name, symbol: "flame.fill", colorHex: "#C93B2E", priority: 8, shape: .pin, clusterable: false))
        }
        return frame
    }

    private func handleTap(_ id: String, _ c: Content) {
        if id.hasPrefix("incident-") { router.push(.fireIncident(String(id.dropFirst(9)))); return }
        if id.hasPrefix("perimeter-") {
            let incidentId = String(id.dropFirst(10))
            if conditions.smoke?.payload.incidents.items.contains(where: { $0.id == incidentId }) == true { router.push(.fireIncident(incidentId)) }
            else if let per = conditions.smoke?.payload.perimeters.items.first(where: { $0.id == incidentId }) {
                tapped = "\(per.name) perimeter: \(per.acres.map { "\(Int($0)) acres" } ?? "size not reported"), \(per.percentContained.map { "\(Int($0))% contained" } ?? "containment not reported"), updated \(per.updatedAt.map(DateText.long) ?? "–"). No matching incident record within the tracked radius."
            }
            return
        }
        if id.hasPrefix("plume-") {
            if let area = fireContent(c).overlayAreas.first(where: { $0.id == id }) { tapped = area.title ?? "Smoke plume" }
            return
        }
        if id.hasPrefix("hotspot-"), let i = Int(id.dropFirst(8)), let h = conditions.smoke?.payload.hotspots.items[safe: i] {
            tapped = "VIIRS \(h.satellite ?? "") detection \(DateText.long(h.acquiredAt)) · confidence \(h.confidence ?? "–") · FRP \(h.frpMw.map { String(format: "%.1f MW", $0) } ?? "–")\(h.incidentId.map { " · incident \($0)" } ?? " · not attributed to a tracked incident")"
            return
        }
        if id.hasPrefix("monitor-"), let r = conditions.smoke?.payload.airnow.readings.first(where: { "monitor-\($0.site)" == id }) {
            tapped = "\(r.site): \(r.parameter) AQI \(r.aqi.map { "\(Int($0))" } ?? "–") (\(r.category ?? "")) observed \(r.observedAt.map(DateText.long) ?? "–") · \(r.agency ?? "")"
        }
    }

    private func regionalSummaries(_ c: Content) -> some View {
        FieldCard(eyebrow: "Regional summary · 15 areas") {
            if let snap = conditions.smoke, !snap.isExpired {
                ForEach(c.status.fireRegions) { region in
                    let s = FireRegionSummary.compute(region: region, feed: snap.payload)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(region.label).font(.fieldCaption.weight(.semibold))
                        Text(s.text).font(.caption2).foregroundStyle(s.severe ? Palette.ember : .secondary)
                    }
                    .padding(.vertical, 1)
                }
                Text("Perimeter-edge distances are straight-line from each area's reference point; heat counts use detections within 15 miles over the saved window.").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("Needs a current smoke snapshot.").font(.fieldCaption).foregroundStyle(.secondary)
            }
        }
    }

    private func incidents(_ c: Content) -> some View {
        FieldCard {
            FeedHeader(title: "Incidents & satellite heat", snapshot: conditions.smoke, refreshing: conditions.isRefreshing("smoke"), error: conditions.errors["smoke"]) { Task { await conditions.refresh(.smoke) } }
            if let snap = conditions.smoke, !snap.isExpired {
                let feed = snap.payload
                if feed.incidents.items.isEmpty { Text("No incidents within \(Int(feed.incidents.radiusMiles ?? 150)) miles in the saved snapshot (\(DateText.long(feed.incidents.checkedAt))).").font(.fieldCaption).foregroundStyle(.secondary) }
                ForEach(feed.incidents.items.sorted { ($0.distanceMiles ?? 1e9) < ($1.distanceMiles ?? 1e9) }) { inc in
                    NavigationLink(value: Route.fireIncident(inc.id)) {
                        HStack(alignment: .top) {
                            Image(systemName: "flame.fill").foregroundStyle(Palette.ember)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(inc.name).font(.fieldBody.weight(.semibold))
                                Text([inc.acres.map { "\(Int($0)) acres" }, inc.percentContained.map { "\(Int($0))% contained" }, inc.distanceMiles.map { "\(Int($0)) mi \(inc.bearing ?? "")" }, inc.updatedAt.map { "updated \(DateText.long($0))" }].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Text("VIIRS: \(feed.hotspots.items.count) detections in the last \(feed.hotspots.windowHours ?? 48) h, \(feed.hotspots.unattributed ?? 0) not attributed to an incident\(feed.hotspots.latestAt.map { ", latest \(DateText.long($0))" } ?? "").").font(.caption2).foregroundStyle(.secondary)
                FeedStatusList(statuses: feed.statuses)
            }
        }
    }

    private var airCard: some View {
        FieldCard(eyebrow: "Smoke & air monitors") {
            if let snap = conditions.smoke, !snap.isExpired {
                let feed = snap.payload
                Text("NPS Yosemite monitors: \(feed.monitors.state)\(feed.monitors.detail.map { " (\($0))" } ?? "")").font(.fieldCaption).foregroundStyle(feed.monitors.state == "ready" ? .primary : Palette.ember)
                ForEach(feed.monitors.readings + feed.airnow.readings, id: \.self) { r in
                    HStack {
                        Text(r.site).font(.fieldCaption)
                        Spacer()
                        Text("\(r.parameter) \(r.aqi.map { "\(Int($0))" } ?? "–") \(r.category ?? "")").font(.fieldCaption.weight(.semibold))
                    }
                    Text("\(r.observedAt.map(DateText.long) ?? "") · \(r.agency ?? "") · \(r.method ?? "")").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                if let pts = feed.plumes.points {
                    Text("HMS smoke at forecast points (analysis \(feed.plumes.analysisDate ?? "–")):").font(.fieldEyebrow).foregroundStyle(.secondary)
                    ForEach(pts, id: \.pointKey) { p in Text("\(p.label): \(p.density ?? "none detected")").font(.caption2) }
                }
            } else {
                Text("No current smoke snapshot.").font(.fieldCaption).foregroundStyle(.secondary)
            }
        }
    }

    private func restrictionsCard(_ c: Content) -> some View {
        FieldCard(eyebrow: "Official fire restrictions") {
            if let snap = conditions.fire, !snap.isExpired {
                let r = snap.payload.restrictions
                Text(r.text ?? "Restriction text unavailable.").font(.fieldBody)
                Text("State \(r.state)\(r.detail.map { " · \($0)" } ?? "") · page updated \(r.pageUpdated.map(DateText.long) ?? "unknown") · checked \(DateText.long(r.checkedAt))").font(.caption2).foregroundStyle(.secondary)
                if let url = URL(string: r.url) { ExternalLinkRow(label: "NPS fire restrictions page", url: url) }
            } else if let u = c.status.links["fireRestrictions"], let url = URL(string: u) {
                ExternalLinkRow(label: "NPS fire restrictions page (no saved snapshot)", url: url)
            }
        }
    }

    @ViewBuilder private var fireWeather: some View {
        if let snap = conditions.fire, !snap.isExpired {
            let f = snap.payload.fwf
            FieldCard(eyebrow: "NWS Hanford fire weather · \(f.zoneName ?? f.zone ?? "")") {
                if f.state == "ready" {
                    if let d = f.discussion { Text(d).font(.fieldCaption) }
                    ForEach(f.periods ?? [], id: \.name) { p in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.fieldCaption.weight(.semibold))
                            Text([p.skyWeather, p.maxTemperature.map { "high \($0)" }, p.minTemperature.map { "low \($0)" }, p.minHumidity.map { "min RH \($0)" }, p.windsRidges.map { "ridges \($0)" }].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text("Issued \(f.issuedAt.map(DateText.long) ?? "–"). Regional zone, a different scale from the Valley point.").font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Text("Fire weather product \(f.state)\(f.detail.map { ": \($0)" } ?? "").").font(.fieldCaption).foregroundStyle(Palette.ember)
                }
            }
        }
    }

    @ViewBuilder private var officialNotices: some View {
        if let snap = conditions.fire, !snap.isExpired {
            FieldCard(eyebrow: "Official notices checked for fire terms") {
                if snap.payload.notices.items.isEmpty && snap.payload.alerts.items.isEmpty { Text("No NPS or NWS notices in the saved snapshot.").font(.fieldCaption).foregroundStyle(.secondary) }
                ForEach(snap.payload.notices.items) { n in
                    NoticeRow(item: NoticeItem(id: n.id, kind: "alert", title: n.title, text: n.body, area: n.category, url: n.url, sourceDate: n.lastModified))
                }
                ForEach(snap.payload.alerts.items) { a in Text("NWS: \(a.event)\(a.headline.map { " · \($0)" } ?? "")").font(.fieldCaption) }
                Text("Matched fire terms: \((snap.payload.notices.fireMatches ?? []).isEmpty && (snap.payload.alerts.fireMatches ?? []).isEmpty ? "none" : ((snap.payload.notices.fireMatches ?? []) + (snap.payload.alerts.fireMatches ?? [])).joined(separator: ", "))").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

enum FireRegionSummary {
    struct Result { let text: String; let severe: Bool }

    static func compute(region: FireRegion, feed: SmokeFeed) -> Result {
        let origin = region.coordinate
        var nearest: (name: String, miles: Double, inside: Bool)?
        for per in feed.perimeters.items {
            var best = Double.infinity
            var inside = false
            for ring in per.rings {
                let pts = ring.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
                if pointInPolygon(origin, pts) { inside = true; best = 0; break }
                for i in 0..<pts.count {
                    best = min(best, haversineMeters(origin, pts[i]) / 1609.344)
                }
            }
            if nearest == nil || best < nearest!.miles { nearest = (per.name, best, inside) }
        }
        let heat = feed.hotspots.items.filter { haversineMeters(origin, CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) <= 15 * 1609.344 }.count
        var smoke: String?
        for poly in feed.plumes.polygons ?? [] {
            let ring = poly.ring.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
            if pointInPolygon(origin, ring) { if smoke == nil || rank(poly.density) > rank(smoke!) { smoke = poly.density } }
        }
        var parts: [String] = []
        if let n = nearest { parts.append(n.inside ? "inside the \(n.name) perimeter" : String(format: "nearest perimeter %@ %.0f mi", n.name, n.miles)) } else { parts.append("no current perimeter in the snapshot") }
        parts.append("\(heat) heat detections within 15 mi")
        parts.append(smoke.map { "\($0.lowercased()) smoke overhead (HMS)" } ?? "no HMS smoke overhead")
        return Result(text: parts.joined(separator: " · "), severe: (nearest?.inside ?? false) || heat > 0 || smoke == "Heavy")
    }

    private static func rank(_ d: String) -> Int { d == "Heavy" ? 3 : d == "Medium" ? 2 : 1 }

    static func pointInPolygon(_ p: CLLocationCoordinate2D, _ ring: [CLLocationCoordinate2D]) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.latitude > p.latitude) != (b.latitude > p.latitude) {
                let x = (b.longitude - a.longitude) * (p.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude
                if p.longitude < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

struct FireIncidentDetailView: View {
    let incidentId: String
    @ObservedObject private var conditions = ConditionsStore.shared

    var body: some View {
        if let snap = conditions.smoke, let inc = snap.payload.incidents.items.first(where: { $0.id == incidentId }) {
            FieldScroll {
                FieldCard {
                    Text(inc.type == "WF" ? "Wildfire" : (inc.type ?? "Incident")).font(.fieldEyebrow).foregroundStyle(.secondary)
                    LabeledContent("Size", value: inc.acres.map { "\(Int($0)) acres" } ?? "not reported")
                    LabeledContent("Containment", value: inc.percentContained.map { "\(Int($0))%" } ?? "not reported")
                    LabeledContent("Distance from Valley", value: inc.distanceMiles.map { "\(Int($0)) mi \(inc.bearing ?? "")" } ?? "–")
                    LabeledContent("Discovered", value: inc.discoveredAt.map(DateText.long) ?? "–")
                    LabeledContent("Source update", value: inc.updatedAt.map(DateText.long) ?? "–")
                    LabeledContent("Source", value: inc.source ?? "–")
                    if let c = inc.county { LabeledContent("County", value: c) }
                    if let p = inc.perimeterAcres { LabeledContent("Perimeter acres", value: "\(Int(p))") }
                    LabeledContent("Heat detections", value: "\(inc.hotspotCount ?? 0)\(inc.latestHotspotAt.map { " · latest \(DateText.long($0))" } ?? "")")
                    if let u = inc.url ?? inc.inciwebUrl, let url = URL(string: u) { ExternalLinkRow(label: "Incident page", url: url) }
                }
                .font(.fieldCaption)
                if let track = snap.payload.tracking?.incidents.first(where: { $0.id == inc.id }) {
                    FieldCard(eyebrow: "Change history · recorded by the companion server") {
                        ForEach(track.points, id: \.t) { p in
                            Text("\(DateText.long(p.t)): \(p.acres.map { "\(Int($0)) ac" } ?? "–") · \(p.percentContained.map { "\(Int($0))%" } ?? "–") contained · \(p.detections12h ?? 0) detections/12 h").font(.caption2)
                        }
                        if let since = snap.payload.tracking?.since { Text("Tracked since \(DateText.long(since)).").font(.caption2).foregroundStyle(.secondary) }
                    }
                } else {
                    Text("No locally recorded change history for this incident.").font(.caption2).foregroundStyle(.secondary)
                }
                SnapshotFooter(snapshot: snap)
            }
            .fieldNavigationTitle(inc.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            EmptyStateView(symbol: "flame", title: "Incident not in snapshot", message: "The saved smoke snapshot does not include this incident.")
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
