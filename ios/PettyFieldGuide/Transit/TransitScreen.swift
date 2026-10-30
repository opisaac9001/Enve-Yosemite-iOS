import SwiftUI

struct TransitScreen: View {
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        if let c = content.content {
            FieldScroll {
                PlannerView()
                FieldCard(eyebrow: "Valley shuttle facts") {
                    LabeledContent("Hours", value: c.status.shuttleInfo.hours)
                    LabeledContent("Fare", value: c.status.shuttleInfo.fare)
                    Text(c.status.shuttleInfo.accessibility).font(.fieldCaption)
                    ForEach(c.status.shuttleInfo.frequency, id: \.source) { f in
                        Text("\(f.source): Valleywide \(f.valleywide); East Valley \(f.eastValley)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(c.status.shuttleInfo.caveat).font(.caption2).foregroundStyle(.secondary)
                }
                .font(.fieldCaption)
                FieldCard(eyebrow: "Stops") {
                    ForEach(c.places.filter { $0.kind == .shuttleStop }.sorted { ($0.stopNumber ?? 0) < ($1.stopNumber ?? 0) }) { stop in
                        NavigationLink(value: Route.stop(stop.stopNumber ?? 0)) {
                            HStack { Text(stop.name).font(.fieldBody); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                        }
                        .buttonStyle(.plain)
                    }
                }
                DrivingNotesCard()
                FieldCard(eyebrow: "YARTS regional buses") {
                    Text(c.status.shuttleInfo.yarts.summary).font(.fieldBody)
                    Text("Valley stops: \(c.status.shuttleInfo.yarts.stops.joined(separator: " · "))").font(.fieldCaption)
                    if let url = PhoneFormat.telURL(c.status.shuttleInfo.yarts.phone) { Link(c.status.shuttleInfo.yarts.phone, destination: url).font(.fieldCaption) }
                    if let url = URL(string: c.status.shuttleInfo.yarts.url) { ExternalLinkRow(label: "YARTS routes & schedules", url: url) }
                }
                timetableSource(c)
            }
            .fieldNavigationTitle("Getting around")
        }
    }

    private func timetableSource(_ c: Content) -> some View {
        FieldCard(eyebrow: "Timetable source") {
            ForEach(c.transit.feeds) { feed in
                Text("\(feed.label): GTFS feed \(feed.feedVersion), valid \(DateText.long(feed.validFrom)) to \(DateText.long(feed.validTo)).").font(.fieldCaption)
                if let url = URL(string: feed.source) { Link("NPS GTFS download", destination: url).font(.caption2) }
            }
            Text("\(c.transit.note) Pack fetched \(DateText.long(c.transit.fetchedAt)).").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct DrivingNotesCard: View {
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var router: AppRouter
    var body: some View {
        if let c = content.content {
            FieldCard(eyebrow: "Driving to Village Parking") {
                Text("Day-use drivers are directed to Yosemite Village Parking, Yosemite Falls Parking or Curry Village, then onto the free shuttle. Valley roads are mostly one-way loops: Southside Drive runs east, Northside Drive runs west, with crossovers at El Capitan and Sentinel Bridge.").font(.fieldBody)
                ForEach(Array(c.notices.parkingWalks.sorted { $0.key < $1.key }), id: \.key) { key, walks in
                    ForEach(walks, id: \.placeId) { w in
                        Text("\(c.place(key)?.name ?? key): \(w.note)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button { router.showOnMap(.place("parking-yosemite-village")) } label: { Label("Village Parking on the map", systemImage: "map") }
                }
                .buttonStyle(.bordered).font(.fieldCaption)
                SourceList(sources: Array(c.notices.parkingSources.values).sorted { $0.label < $1.label })
            }
        }
    }
}

struct PlannerView: View {
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var router: AppRouter
    @AppStorage(PlannerPreferences.fromKey) private var fromPlace = "shuttle-1"
    @AppStorage(PlannerPreferences.toKey) private var toPlace = "shuttle-16"
    @AppStorage(PlannerPreferences.feedKey) private var feedId = "valley"
    @State private var when = PlannerView.defaultTime()

    private static func defaultTime() -> Date {
        var comps = YosemiteGeo.calendar.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 9; comps.minute = 0
        return YosemiteGeo.calendar.date(from: comps) ?? Date()
    }

    var body: some View {
        if let c = content.content, let feed = c.transit.feeds.first(where: { $0.id == feedId }) ?? c.transit.feeds.first {
            let stops = plannerStops(c, feed: feed)
            FieldCard(eyebrow: "Shuttle trip planner · scheduled times only") {
                Picker("Feed", selection: $feedId) { ForEach(c.transit.feeds) { Text($0.label).tag($0.id) } }.pickerStyle(.menu).font(.fieldCaption)
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("From", selection: $fromPlace) { ForEach(stops, id: \.id) { Text($0.label).tag($0.id) } }
                        Picker("To", selection: $toPlace) { ForEach(stops, id: \.id) { Text($0.label).tag($0.id) } }
                    }
                    .pickerStyle(.menu)
                    Button { (fromPlace, toPlace) = (toPlace, fromPlace) } label: { Image(systemName: "arrow.up.arrow.down") }.buttonStyle(.bordered).accessibilityLabel("Swap stops")
                }
                DatePicker("Yosemite date & time", selection: $when).environment(\.timeZone, YosemiteGeo.timeZone).font(.fieldCaption)
                let plans = ShuttlePlanner.plan(feed: feed, from: fromPlace, to: toPlace, at: when)
                if fromPlace == toPlace {
                    Text("Choose two different stops.").font(.fieldCaption).foregroundStyle(.secondary)
                } else if plans.isEmpty {
                    Text("No scheduled departure after \(DateText.short(when)) on \(DateText.long(EventCalendar.day(when))). The timetable is valid \(DateText.long(feed.validFrom))–\(DateText.long(feed.validTo)); service runs \(c.status.shuttleInfo.hours).").font(.fieldCaption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                        PlanCard(plan: plan, label: index == 0 ? "Earliest scheduled arrival" : "Alternative")
                    }
                }
                Text("Interpolated stop times from the NPS GTFS feed; transfers allow \(ShuttlePlanner.transferAllowanceMinutes) minutes. No live arrivals, walking times or traffic are included.").font(.caption2).foregroundStyle(.secondary)
            }
            .onAppear { if !c.transit.feeds.contains(where: { $0.id == feedId }) { feedId = c.transit.feeds.first?.id ?? feedId } }
        }
    }

    private struct PlannerStop { let id: String; let label: String }

    private func plannerStops(_ c: Content, feed: TransitFeed) -> [PlannerStop] {
        var seen = Set<String>()
        var out: [PlannerStop] = []
        for route in feed.routes {
            for s in route.stops {
                let id = s.placeId ?? "gtfs-\(s.gtfsId)"
                guard seen.insert(id).inserted else { continue }
                out.append(PlannerStop(id: id, label: c.place(id)?.name ?? s.name))
            }
        }
        return out.sorted { ($0.id.split(separator: "-").last.flatMap { Int($0) } ?? 99) < ($1.id.split(separator: "-").last.flatMap { Int($0) } ?? 99) }
    }
}

struct PlanCard: View {
    let plan: PlannedTrip
    let label: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.fieldEyebrow).foregroundStyle(.secondary)
                Spacer()
                Text("\(DateText.time(plan.departure)) → \(DateText.time(plan.arrival)) · \(plan.totalMinutes) min").font(.fieldCaption.weight(.semibold))
            }
            ForEach(Array(plan.legs.enumerated()), id: \.offset) { i, leg in
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(hex: leg.colorHex)).frame(width: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(leg.routeName).font(.fieldCaption.weight(.semibold))
                        Text("Board \(leg.boardStop.name) \(DateText.time(leg.departure)) · alight \(leg.alightStop.name) \(DateText.time(leg.arrival))").font(.caption2)
                        if leg.passesOrigin { Text("Stays aboard through the loop origin; the schedule treats this as a continuing run.").font(.caption2).foregroundStyle(.secondary) }
                        if expanded {
                            Text(leg.stopSequence.map(\.name).joined(separator: " → ")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if i == 0, plan.legs.count > 1, let t = plan.transferMinutes {
                    Text("Transfer: \(t) min wait (\(ShuttlePlanner.transferAllowanceMinutes) min allowance applied)").font(.caption2).foregroundStyle(Palette.accent)
                }
            }
            Button(expanded ? "Hide stop sequence" : "Show stop sequence") { expanded.toggle() }.font(.caption2)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct StopTimetableView: View {
    let stopNumber: Int
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var router: AppRouter
    @State private var day = Date()

    var body: some View {
        if let c = content.content, let stop = c.place("shuttle-\(stopNumber)") {
            FieldScroll {
                FieldCard {
                    Text(stop.summary).font(.fieldBody)
                    HStack {
                        Button { router.showOnMap(.place(stop.id)) } label: { Label("Map", systemImage: "map") }
                        Button { router.push(.place(stop.id), in: .directory) } label: { Label("Stop details", systemImage: "info.circle") }
                    }
                    .buttonStyle(.bordered).font(.fieldCaption)
                }
                DatePicker("Day", selection: $day, displayedComponents: .date).environment(\.timeZone, YosemiteGeo.timeZone)
                ForEach(c.transit.feeds) { feed in
                    ForEach(feed.routes.filter { $0.stops.contains { $0.placeId == stop.id } }) { route in
                        let times = ShuttlePlanner.timetable(route: route, placeId: stop.id, day: EventCalendar.day(day))
                        FieldCard(eyebrow: route.name) {
                            if times.isEmpty { Text("No service scheduled on this day.").font(.fieldCaption).foregroundStyle(.secondary) }
                            else {
                                Text("\(times.count) scheduled times · first \(DateText.time(times[0])) · last \(DateText.time(times[times.count - 1]))").font(.fieldCaption)
                                Text(times.map(DateText.time).joined(separator: "  ")).font(.fieldMono)
                            }
                            let order = ShuttlePlanner.stopOrder(route)
                            Text("Stop order: \(order.stops.map(\.name).joined(separator: " → "))\(order.closesLoop ? " → back to \(order.stops.first?.name ?? "the start")" : " (route ends here; no published return)")").font(.caption2).foregroundStyle(.secondary)
                            Text("Feed \(feed.feedVersion) valid \(DateText.long(feed.validFrom))–\(DateText.long(feed.validTo)). Interpolated schedule, not live.").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .fieldNavigationTitle(stop.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            EmptyStateView(symbol: "bus", title: "Stop not found", message: "No stop with that number is in the timetable.")
        }
    }
}
