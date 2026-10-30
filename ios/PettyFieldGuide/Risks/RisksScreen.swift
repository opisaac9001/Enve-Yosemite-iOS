import SwiftUI

/// Evaluates a seasonal check against saved snapshots with disclosed trigger rules.
struct RiskEvaluation {
    struct Input: Identifiable {
        let id: String
        let label: String
        let state: SourceState
        let value: String
        let triggered: Bool
    }
    let inputs: [Input]
    let matchedNotices: [NoticeItem]
    var triggered: Bool { inputs.contains(where: \.triggered) || !matchedNotices.isEmpty }
}

@MainActor
enum RiskEvaluator {
    static func evaluate(check: RiskCheck, content: Content, store: ConditionsStore) -> RiskEvaluation {
        let valley = store.weather["valley"]
        let fire = store.fire
        let seasonal = store.seasonal
        let smoke = store.smoke
        func state<T: Codable & Sendable>(_ s: Snapshot<T>?, _ staleAfter: TimeInterval = 3 * 3600) -> SourceState { s?.freshness(staleAfter: staleAfter) ?? .none }
        var inputs: [RiskEvaluation.Input] = []
        let patternKey: String? = switch check.id {
        case "fire": "fire"
        case "insects": "vector"
        case "water": "water"
        case "river": "flood"
        case "snow": "snow"
        case "visibility": "visibility"
        default: nil
        }
        var matched: [NoticeItem] = []
        if let key = patternKey, let spec = content.status.riskPatterns[key], let regex = try? NSRegularExpression(pattern: spec.pattern, options: spec.caseInsensitive ? [.caseInsensitive] : []) {
            let notices = allNotices(store: store)
            matched = notices.filter { n in
                let text = n.title + " " + n.body
                return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }
            inputs.append(.init(id: "notices", label: "NPS/NWS notice keyword match", state: notices.isEmpty && store.conditions == nil && store.seasonal == nil ? .none : .ready, value: matched.isEmpty ? "no match" : "\(matched.count) matched", triggered: !matched.isEmpty))
        }
        switch check.id {
        case "fire":
            let aqi = valley?.payload.airQuality.maxAqi12h
            inputs.append(.init(id: "aqi", label: "Modelled 12 h max AQI (Open-Meteo)", state: state(valley), value: aqi.map { "\(Int($0))" } ?? "–", triggered: (aqi ?? 0) > 100))
            inputs.append(.init(id: "assessment", label: "Fire planning assessment level", state: state(fire), value: fire.map { "\($0.payload.assessment.priority) · \($0.payload.assessment.label)" } ?? "–", triggered: (fire?.payload.assessment.priority ?? 0) >= 3))
            if let m = smoke?.payload.monitors { inputs.append(.init(id: "monitors", label: "NPS air monitors", state: m.state == "ready" ? state(smoke) : .unavailable, value: m.state == "ready" ? "\(m.readings.count) readings" : (m.detail ?? m.state), triggered: m.readings.contains { ($0.aqi ?? 0) > 100 })) }
        case "uv":
            let uv = valley?.payload.uv
            inputs.append(.init(id: "uv", label: "EPA UV index (Valley ZIP)", state: uv?.state == "ready" ? state(valley) : (uv == nil ? .none : .unavailable), value: uv?.index.map { String(format: "%.0f", $0) } ?? "–", triggered: (uv?.index ?? 0) >= 6))
            let hi = valley?.payload.hourly.compactMap(\.temperatureF).max()
            inputs.append(.init(id: "heat", label: "NWS 24 h high (Valley)", state: state(valley), value: hi.map { "\(Int($0))°F" } ?? "–", triggered: (hi ?? 0) >= 90))
        case "river":
            let r = seasonal?.payload.river
            var gauge = "–"
            if let r, let discharge = r.dischargeCfs {
                gauge = "\(Int(discharge)) cfs"
                if let stage = r.stageFt { gauge += String(format: " · %.2f ft", stage) }
                if let t = r.dischargeTime { gauge += " · \(DateText.long(t))" }
            }
            inputs.append(.init(id: "gauge", label: "USGS Merced at Pohono Bridge (provisional)", state: r?.state == "ready" ? state(seasonal) : (r == nil ? .none : .unavailable), value: gauge, triggered: (r?.dischargeCfs ?? 0) >= 4000))
        case "snow":
            let ch = seasonal?.payload.chains
            inputs.append(.init(id: "chains", label: "Caltrans chain controls (SR-41/120/140)", state: ch?.state == "ready" ? state(seasonal) : (ch == nil ? .none : .unavailable), value: ch.map { $0.activeControls.isEmpty ? "none active on \($0.signsChecked ?? 0) signs" : "\($0.activeControls.count) active" } ?? "–", triggered: !(ch?.activeControls.isEmpty ?? true)))
            let snow = valley?.payload.snowfall
            inputs.append(.init(id: "snow", label: "Modelled snowfall next 24 h (Open-Meteo GFS)", state: snow?.state == "ready" ? state(valley) : (snow == nil ? .none : .unavailable), value: snow?.next24hIn.map { String(format: "%.1f in", $0) } ?? "–", triggered: (snow?.next24hIn ?? 0) >= 1))
        case "visibility":
            let v = valley?.payload.visibility
            inputs.append(.init(id: "vis", label: "Modelled 12 h minimum visibility (Open-Meteo GFS)", state: v?.state == "ready" ? state(valley) : (v == nil ? .none : .unavailable), value: v?.minMiles12h.map { String(format: "%.0f mi", $0) } ?? "–", triggered: (v?.minMiles12h ?? 99) < 3))
        case "insects", "water":
            if let w = store.conditions?.payload.wilderness { inputs.append(.init(id: "wilderness", label: "NPS wilderness narrative (dated)", state: state(store.conditions, 6 * 3600), value: w.reportDate.map { "report \(DateText.long($0))" } ?? "\(w.items.count) items", triggered: false)) }
        default: break
        }
        return RiskEvaluation(inputs: inputs, matchedNotices: matched)
    }

    static func allNotices(store: ConditionsStore) -> [NoticeItem] {
        var out: [NoticeItem] = []
        if let c = store.conditions, !c.isExpired { out += c.payload.allItems }
        if let s = store.seasonal, !s.isExpired { out += s.payload.notices.items }
        if let f = store.fire, !f.isExpired {
            out += f.payload.alerts.items.map { NoticeItem(id: "nws-\($0.id)", kind: "alert", title: $0.event, text: $0.headline ?? $0.description, area: $0.areaDesc, url: $0.url, sourceDate: $0.onset) }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }
}

struct RisksScreen: View {
    @EnvironmentObject private var content: ContentStore
    @ObservedObject private var conditions = ConditionsStore.shared

    var body: some View {
        if let c = content.content {
            let month = YosemiteGeo.calendar.component(.month, from: Date())
            let lead = c.status.riskChecks.filter { $0.leadMonths.contains(month) }
            let shoulder = c.status.riskChecks.filter { $0.shoulderMonths.contains(month) }
            let other = c.status.riskChecks.filter { !$0.leadMonths.contains(month) && !$0.shoulderMonths.contains(month) }
            FieldScroll {
                FieldCard {
                    FeedHeader(title: "Seasonal checks · \(monthName(month))", snapshot: conditions.seasonal, refreshing: conditions.isRefreshing("seasonal"), error: conditions.errors["seasonal"], staleAfter: 3 * 3600) { Task { await conditions.refresh(.seasonal) } }
                    Text("Each check lists its own inputs with their state. Trigger rules are this app's disclosed heuristics; official warnings are shown separately and in full.").font(.caption2).foregroundStyle(.secondary)
                }
                group("Lead checks this month", lead, c)
                group("Shoulder-season checks", shoulder, c)
                group("Other months", other, c)
                allNotices
            }
            .fieldNavigationTitle("Seasonal risks")
            .task { await conditions.refreshStale() }
        }
    }

    private func monthName(_ m: Int) -> String { DateFormatter().monthSymbols[m - 1] }

    @ViewBuilder private func group(_ title: String, _ checks: [RiskCheck], _ c: Content) -> some View {
        if !checks.isEmpty {
            Text(title).font(.fieldHeading)
            ForEach(checks) { check in
                NavigationLink(value: Route.riskCheck(check.id)) { RiskCheckCard(check: check, evaluation: RiskEvaluator.evaluate(check: check, content: c, store: conditions)) }.buttonStyle(.plain)
            }
        }
    }

    private var allNotices: some View {
        FieldCard(eyebrow: "All official notices in saved snapshots") {
            let items = RiskEvaluator.allNotices(store: conditions)
            if items.isEmpty { Text("No notices saved. Refresh with the companion server for NPS alerts, NWS alerts and seasonal notices.").font(.fieldCaption).foregroundStyle(.secondary) }
            ForEach(items) { NoticeRow(item: $0) }
        }
    }
}

struct RiskCheckCard: View {
    let check: RiskCheck
    let evaluation: RiskEvaluation
    var body: some View {
        FieldCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(check.title).font(.fieldHeading)
                        if evaluation.triggered { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.accent) }
                    }
                    Text(check.action).font(.fieldCaption).foregroundStyle(.secondary)
                    ForEach(evaluation.inputs) { input in
                        HStack(spacing: 5) {
                            Circle().fill(Palette.stateColor(input.state)).frame(width: 7, height: 7)
                            Text("\(input.label): \(input.value)").font(.caption2).foregroundStyle(input.triggered ? Palette.accent : .secondary)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
    }
}

struct RiskCheckDetailView: View {
    let checkId: String
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var conditions = ConditionsStore.shared

    var body: some View {
        if let c = content.content, let check = c.status.riskChecks.first(where: { $0.id == checkId }) {
            let eval = RiskEvaluator.evaluate(check: check, content: c, store: conditions)
            FieldScroll {
                RiskCheckCard(check: check, evaluation: eval)
                FieldCard(eyebrow: "Trigger rules (this app's heuristics)") {
                    Text(rules(check.id)).font(.fieldCaption)
                    Text("Lead months: \(check.leadMonths.map { DateFormatter().shortMonthSymbols[$0 - 1] }.joined(separator: ", ")) · shoulder: \(check.shoulderMonths.map { DateFormatter().shortMonthSymbols[$0 - 1] }.joined(separator: ", "))").font(.caption2).foregroundStyle(.secondary)
                    if let view = check.linkView, let section = AppSection(rawValue: view) {
                        Button { router.show(section) } label: { Label("Open \(section.title)", systemImage: section.symbol) }.buttonStyle(.bordered).font(.fieldCaption)
                    }
                }
                FieldCard(eyebrow: "Matched official notices") {
                    if eval.matchedNotices.isEmpty { Text("No saved notice matched this check's keywords. Unmatched notices remain listed under Seasonal risks.").font(.fieldCaption).foregroundStyle(.secondary) }
                    ForEach(eval.matchedNotices) { NoticeRow(item: $0) }
                }
            }
            .fieldNavigationTitle(check.title)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            EmptyStateView(symbol: "exclamationmark.triangle", title: "Check not found", message: "")
        }
    }

    private func rules(_ id: String) -> String {
        switch id {
        case "fire": "Triggers when a saved notice matches fire/smoke/air-quality terms, when the modelled 12-hour AQI exceeds 100, when a monitor reads above 100, or when the fire assessment is level 3 or higher."
        case "uv": "Triggers when the EPA UV index forecast is 6 or more, or the NWS 24-hour high reaches 90°F."
        case "insects": "Triggers only on notices mentioning ticks, mosquitoes, plague, hantavirus, rabies or disease. The dated NPS wilderness narrative is shown for context."
        case "water": "Triggers only on notices mentioning water contamination, boil orders, algae or sewage."
        case "river": "Triggers on flood/high-water notices or a provisional Pohono Bridge discharge of 4,000 cfs or more."
        case "snow": "Triggers on winter/snow/chain notices, any active Caltrans chain control, or 1 inch or more of modelled snowfall in 24 hours."
        case "visibility": "Triggers on fog/smoke/visibility notices or a modelled 12-hour minimum visibility under 3 miles."
        default: ""
        }
    }
}
