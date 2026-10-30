import SwiftUI
import Combine

struct FieldStatusScreen: View {
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var conditions = ConditionsStore.shared
    @ObservedObject private var server = ServerConfig.shared
    @State private var pointKey = "valley"
    @State private var now = Date()
    private let ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        if let c = content.content {
            FieldScroll {
                DaylightCard(now: now)
                pointPicker(c)
                weatherCards(c)
                webcams(c)
            }
            .fieldNavigationTitle("Field status")
            .onReceive(ticker) { now = $0 }
            .task { await conditions.refreshStale() }
        }
    }

    private func pointPicker(_ c: Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(c.status.forecastPoints) { p in
                    ChipButton(title: p.label, active: pointKey == p.key) { pointKey = p.key }
                }
            }
        }
    }

    @ViewBuilder private func weatherCards(_ c: Content) -> some View {
        if let point = c.forecastPoint(pointKey) {
            let snap = conditions.weather[point.key]
            FieldCard {
                FeedHeader(title: "\(point.label) · \(Int(point.elevationFt)) ft", snapshot: snap, refreshing: conditions.isRefreshing("weather-\(point.key)"), error: conditions.errors["weather-\(point.key)"]) {
                    Task { await conditions.refreshWeather(point: point.key) }
                }
                Text(point.region).font(.caption2).foregroundStyle(.secondary)
                if let snap, !snap.isExpired {
                    WeatherSummary(feed: snap.payload)
                } else if snap != nil {
                    Text("The saved forecast is older than 48 hours and is not shown as current.").font(.fieldCaption).foregroundStyle(Palette.ember)
                } else {
                    Text("No saved forecast for this point yet.").font(.fieldCaption).foregroundStyle(.secondary)
                }
            }
            if let snap, !snap.isExpired {
                HourlyCard(feed: snap.payload)
                AlertsCard(alerts: snap.payload.alerts)
                FieldCard(eyebrow: "Sources for this point") { FeedStatusList(statuses: snap.payload.statuses) }
            }
        }
    }

    private func webcams(_ c: Content) -> some View {
        FieldCard(eyebrow: "Webcams · provider pages") {
            Text("Links open each provider's own page; nothing is embedded. Status and dates are what the provider showed when checked.").font(.caption2).foregroundStyle(.secondary)
            ForEach(c.webcams.groupOrder, id: \.self) { group in
                let cams = c.webcams.webcams.filter { $0.group == group }
                if !cams.isEmpty {
                    Text(c.webcams.groups[group]?.label ?? group).font(.fieldEyebrow).foregroundStyle(.secondary).padding(.top, 4)
                    ForEach(cams) { cam in
                        NavigationLink(value: Route.webcam(cam.id)) {
                            HStack(alignment: .top) {
                                Image(systemName: cam.medium == "map" ? "map" : "video").foregroundStyle(Palette.accent).frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(cam.name).font(.fieldBody.weight(.semibold))
                                    Text(cam.shows).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct DaylightCard: View {
    let now: Date
    var body: some View {
        let times = SolarCalculator.dayTimes(on: now, at: YosemiteGeo.valleyCenter, timeZone: YosemiteGeo.timeZone)
        let pos = SolarCalculator.position(at: now, coordinate: YosemiteGeo.valleyCenter)
        FieldCard(eyebrow: "Daylight · Yosemite Valley · Pacific") {
            HStack {
                stat("Sunrise", times.sunrise.map(DateText.time) ?? "–")
                stat("Solar noon", DateText.time(times.solarNoon))
                stat("Sunset", times.sunset.map(DateText.time) ?? "–")
            }
            DaylightBar(now: now, times: times)
            Text("Now \(DateText.time(now)) · sun \(String(format: "%.0f", pos.altitude))° above the horizon · azimuth \(String(format: "%.0f", pos.azimuth))° \(SolarCalculator.compassName(forAzimuth: pos.azimuth)) · \(SolarCalculator.phase(forAltitude: pos.altitude).title)")
                .font(.fieldCaption)
            Text("Calculated on this device for the central Valley point with the astronomical horizon (zenith 90.833°); cliffs shade the floor earlier.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.fieldHeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DaylightBar: View {
    let now: Date
    let times: SolarCalculator.DayTimes

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let dayStart = YosemiteGeo.calendar.startOfDay(for: now)
            let riseX = times.sunrise.map { fraction($0, dayStart) * w }
            let setX = times.sunset.map { fraction($0, dayStart) * w }
            let nowX = fraction(now, dayStart) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                if let riseX, let setX {
                    Capsule().fill(Palette.accent.opacity(0.6)).frame(width: max(2, setX - riseX)).offset(x: riseX)
                }
                Circle().fill(Color.primary).frame(width: 10, height: 10).offset(x: max(0, min(w - 10, nowX - 5)))
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }

    private func fraction(_ date: Date, _ dayStart: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(dayStart) / 86400)
    }
}

struct WeatherSummary: View {
    let feed: WeatherFeed
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cur = feed.current {
                HStack(alignment: .firstTextBaseline) {
                    Text(cur.temperatureF.map { "\(Int($0))°F" } ?? "–").font(.system(size: 36, weight: .bold, design: .rounded))
                    VStack(alignment: .leading) {
                        Text(cur.shortForecast ?? "").font(.fieldBody)
                        Text("Wind \(cur.windDirection ?? "") \(cur.windMph.map { "\(Int($0)) mph" } ?? "") · humidity \(cur.humidityPct.map { "\(Int($0))%" } ?? "–") · precip \(cur.precipChancePct.map { "\(Int($0))%" } ?? "–")").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text("NWS hourly period \(DateText.long(cur.start))\(feed.forecastUpdatedAt.map { " · forecast issued \(DateText.long($0))" } ?? "")").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                badge("UV", feed.uv.index.map { String(format: "%.0f", $0) } ?? "–", feed.uv.state, feed.uv.date.map { "EPA forecast \($0)" })
                badge("AQI", feed.airQuality.firstAqi.map { "\(Int($0))" } ?? "–", feed.airQuality.state, feed.airQuality.pm25.map { String(format: "PM2.5 %.1f", $0) })
                badge("Visibility", feed.visibility.firstMiles.map { String(format: "%.0f mi", $0) } ?? "–", feed.visibility.state, feed.visibility.minMiles12h.map { String(format: "12 h min %.0f mi", $0) })
                badge("Snow 24 h", feed.snowfall.next24hIn.map { String(format: "%.1f in", $0) } ?? "–", feed.snowfall.state, "modelled")
            }
            if let obs = feed.observation, obs.temperatureF != nil || obs.textDescription != nil {
                Text("Station \(obs.stationId): \(obs.textDescription ?? "") \(obs.temperatureF.map { "\(Int($0))°F" } ?? "") at \(obs.timestamp.map(DateText.long) ?? "–")").font(.caption2).foregroundStyle(.secondary)
            } else if let obs = feed.observation {
                Text("Station \(obs.stationId) reported no readings at \(obs.timestamp.map(DateText.long) ?? "–").").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func badge(_ label: String, _ value: String, _ state: String, _ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(state == "ready" ? value : "n/a").font(.fieldHeading)
            if let note { Text(state == "ready" ? note : state).font(.system(size: 9)).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HourlyCard: View {
    let feed: WeatherFeed
    var body: some View {
        FieldCard(eyebrow: "Next hours · NWS") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(feed.hourly.prefix(24).enumerated()), id: \.offset) { _, h in
                        VStack(spacing: 3) {
                            Text(DateText.parse(h.start).map(DateText.time) ?? "").font(.caption2).foregroundStyle(.secondary)
                            Image(systemName: h.isDaytime ? "sun.max" : "moon").font(.caption)
                            Text(h.temperatureF.map { "\(Int($0))°" } ?? "–").font(.fieldCaption.weight(.semibold))
                            Text(h.precipChancePct.map { "\(Int($0))%" } ?? "").font(.system(size: 9)).foregroundStyle(Palette.river)
                        }
                        .frame(width: 52)
                    }
                }
            }
        }
    }
}

struct AlertsCard: View {
    let alerts: AlertList
    var body: some View {
        FieldCard(eyebrow: "NWS alerts") {
            if alerts.state != "ready" { Text("Alert feed \(alerts.state).").font(.fieldCaption).foregroundStyle(.secondary) }
            else if alerts.items.isEmpty { Text("No active NWS alerts for this point at the saved check (\(DateText.long(alerts.checkedAt))).").font(.fieldCaption).foregroundStyle(.secondary) }
            ForEach(alerts.items) { a in
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.event).font(.fieldBody.weight(.semibold)).foregroundStyle(Palette.ember)
                    if let h = a.headline { Text(h).font(.fieldCaption) }
                    Text([a.severity, a.urgency, a.ends.map { "ends \(DateText.long($0))" }].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                    if let u = a.url, let url = URL(string: u) { Link("NWS", destination: url).font(.caption2) }
                }
            }
        }
    }
}

struct WebcamDetailView: View {
    let webcamId: String
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        if let c = content.content, let cam = c.webcam(webcamId) {
            FieldScroll {
                FieldCard {
                    Text(c.webcams.groups[cam.group]?.label ?? cam.group).font(.fieldEyebrow).foregroundStyle(.secondary)
                    Text(cam.shows).font(.fieldBody)
                    if let o = cam.origin { LabeledContent("Camera location", value: o).font(.fieldCaption) }
                    LabeledContent("Kind", value: mediumText(cam.medium)).font(.fieldCaption)
                    LabeledContent("Provider status", value: statusText(cam)).font(.fieldCaption)
                    if let s = cam.season { Text(s).font(.fieldCaption) }
                    if let url = URL(string: cam.url) { Link(destination: url) { Label("Open on \(cam.credit)", systemImage: "arrow.up.right.square") }.buttonStyle(.borderedProminent).font(.fieldCaption) }
                }
                if !cam.caveats.isEmpty {
                    FieldCard(eyebrow: "Caveats") { ForEach(cam.caveats, id: \.self) { Label($0, systemImage: "exclamationmark.circle").font(.fieldCaption) } }
                }
                if let rid = cam.regionId {
                    FieldCard(eyebrow: "Region") {
                        Button { router.push(.region(rid), in: .park) } label: { Label(c.region(rid)?.name ?? rid, systemImage: "mountain.2") }.font(.fieldBody)
                        if let basis = cam.regionBasis { Text(basis).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                FieldCard(eyebrow: "Provider & dates") {
                    Text(c.webcams.providerNotes[cam.provider] ?? "").font(.fieldCaption)
                    Text("Credit: \(cam.credit)").font(.caption2).foregroundStyle(.secondary)
                    if let su = cam.sourceUpdated { Text("Provider page dated \(DateText.long(su))").font(.caption2).foregroundStyle(.secondary) }
                    Text("Checked \(DateText.long(cam.checked))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .fieldNavigationTitle(cam.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            EmptyStateView(symbol: "video", title: "Webcam not found", message: "This link points to a camera that is not listed.")
        }
    }

    private func mediumText(_ m: String) -> String {
        switch m {
        case "stream": "Live video in the provider's player"
        case "still": "Still image the provider refreshes"
        case "ptz": "Aimed camera with live and time-lapse images"
        case "map": "Map of several cameras"
        default: m
        }
    }

    private func statusText(_ cam: Webcam) -> String {
        switch cam.providerStatus {
        case "active": "Provider showed “Active” on \(DateText.long(cam.checked))"
        case "inactive": "Provider showed “Inactive” on \(DateText.long(cam.checked))"
        default: "No status shown by the provider on \(DateText.long(cam.checked))"
        }
    }
}
