import SwiftUI

struct HikeStatsRow: View {
    let difficulty: String
    let published: TrailRoute?
    let route: HikeRoute
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var stacked: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        let distance = stat(value: published.map { HikeFormat.miles($0.distanceMi) } ?? "–", label: published?.kind ?? route.kind.title.lowercased())
        let gain = stat(value: published?.gainFt.map { HikeFormat.feet($0) } ?? "–", label: published?.gainFt == nil ? "gain not published" : "elevation gain")
        let time = stat(value: published?.timeHours ?? "–", label: published?.timeHours == nil ? "no published time" : "published time")
        let level = stat(value: difficulty, label: published?.difficulty == nil ? "difficulty" : "NPS difficulty")
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 10) { distance; gain; time; level }
            } else if sizeClass == .regular {
                HStack(alignment: .top, spacing: 12) { distance; gain; time; level }
            } else {
                // Four columns run together on a phone ("1–1.5 hoursModerate"), so a 2×2 grid keeps the reading order.
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 12) { distance; gain }
                    HStack(alignment: .top, spacing: 12) { time; level }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: stacked ? .leading : .center, spacing: 2) {
            Text(value).font(.fieldTitle).minimumScaleFactor(0.7).lineLimit(stacked ? 2 : 1)
            Text(label).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(stacked ? .leading : .center)
        }
        .frame(maxWidth: .infinity, alignment: stacked ? .leading : .center)
    }
}

struct HikeRoutePicker: View {
    let trail: Trail
    let routes: [HikeRoute]
    @Binding var selection: String

    var body: some View {
        if routes.count > 1 {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(routes) { route in
                    let published = trail.route(route.id)
                    Button { selection = route.id } label: {
                        HStack(spacing: 8) {
                            Image(systemName: selection == route.id ? "largecircle.fill.circle" : "circle").foregroundStyle(Palette.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(route.label).font(.fieldCaption.weight(selection == route.id ? .semibold : .regular)).multilineTextAlignment(.leading)
                                Text([published.map { HikeFormat.miles($0.distanceMi) }, published?.difficulty ?? trail.difficulty, route.kind.title.lowercased()].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == route.id ? [.isSelected] : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Published route")
        }
    }
}

struct HikeMiniMap: UIViewRepresentable {
    let scene: MapScene
    let route: HikeRoute
    let trace: MapRouteTrace
    let dark: Bool
    var cursor: CGPoint?

    private var content: MapFrameContent {
        MapFrameContent(markers: MapMarker.routeMarkers(for: trace, compactLabels: true) + MapMarker.milestoneMarkers(for: HikeLandmark.landmarks(for: route, trace: trace), labelled: false),
                        routeCursor: cursor)
    }

    private var options: MapFrameOptions {
        var o = MapFrameOptions(dark: dark)
        o.highlightedRouteId = trace.id
        o.elementScale = 0.9
        o.showOneWayArrows = false
        return o
    }

    private static func fit(_ trace: MapRouteTrace, in size: CGSize) -> MapCamera {
        let bounds = trace.bounds.insetBy(dx: -max(40, trace.bounds.width * 0.08), dy: -max(40, trace.bounds.height * 0.08))
        return MapCamera.fitting(bounds, in: size, padding: 14)
    }

    /// Refits this trace whenever the canvas is laid out at a new size (no gestures reach a disabled canvas).
    private static func follow(_ trace: MapRouteTrace, on canvas: MapCanvas) {
        canvas.onCameraChange = { [weak canvas] camera in
            guard let canvas else { return }
            let fit = fit(trace, in: camera.viewSize)
            if canvas.camera != fit { canvas.camera = fit }
        }
    }

    func makeUIView(context: Context) -> MapCanvas {
        let canvas = MapCanvas(camera: Self.fit(trace, in: CGSize(width: 320, height: 220)), options: options)
        canvas.isUserInteractionEnabled = false
        canvas.scene = scene
        canvas.content = content
        Self.follow(trace, on: canvas)
        return canvas
    }

    func updateUIView(_ canvas: MapCanvas, context: Context) {
        canvas.scene = scene
        canvas.options = options
        canvas.content = content
        // Later layout passes must refit the trace shown now, not the one the canvas was made with.
        Self.follow(trace, on: canvas)
        if canvas.bounds.width > 0 { canvas.camera = Self.fit(trace, in: canvas.bounds.size) }
    }
}

struct HikeSequenceCard: View {
    let route: HikeRoute
    @State private var showMapping = false

    var body: some View {
        FieldCard(eyebrow: "Route · \(route.kind.title)") {
            Text(route.sequence).font(.fieldBody)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(route.milestoneRows) { row in
                    let m = row.milestone
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: m.role == "start" ? "figure.walk" : m.role == "destination" ? (route.kind == .loop ? "arrow.uturn.left" : "flag.fill") : "circle.fill")
                            .font(.caption2).foregroundStyle(m.role == "start" ? Palette.pine : m.role == "destination" ? Palette.ember : Palette.river).frame(width: 16)
                        Text(m.name).font(.fieldCaption.weight(m.role == "waypoint" ? .regular : .semibold))
                        Spacer(minLength: 8)
                        Text(String(format: "%.1f mi", m.chainageMiles)).font(.fieldCaption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text("GIS trace \(HikeFormat.miles(route.traceMiles)) as walked · NPS publishes \(HikeFormat.miles(route.publishedMiles)). \(route.traceNote)")
                .font(.caption2).foregroundStyle(.secondary)
            DisclosureGroup(isExpanded: $showMapping) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mapped on \(route.segments.count) NPS trail features\(route.unnamedFeatures > 0 ? ", \(route.unnamedFeatures) of them unnamed in the NPS layer" : ""). NPS positional accuracy is mostly unknown; the line is for orientation, not navigation.")
                        .font(.caption2).foregroundStyle(.secondary)
                    ForEach(route.milestoneRows) { row in
                        Text("\(row.milestone.name): \(row.milestone.source)\(row.milestone.offsetMetres > 5 ? String(format: " (%.0f m from the mapped line)", row.milestone.offsetMetres) : "")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("How this route was mapped").font(.fieldCaption)
            }
            .frame(minHeight: 44)
        }
    }
}

struct HikeGuideCards: View {
    let guide: HikeGuide

    private var context: String {
        let updated = guide.source.updated.map { "updated \(DateText.long($0))" }
        let checked = guide.source.checked.map { "checked \(DateText.long($0))" }
        return "As published on the NPS trail page (\([updated, checked].compactMap { $0 }.joined(separator: ", "))). Typical conditions and amenities, not today's status; current closures are in the warnings and official notices."
    }

    var body: some View {
        FieldCard(eyebrow: "Terrain & effort · as published") {
            Text(guide.terrain).font(.fieldBody)
            Text(context).font(.caption2).foregroundStyle(.secondary)
        }
        FieldCard(eyebrow: "Getting there · as published") {
            LabeledTextList(items: [LabeledText(label: "Trailhead & shuttle", text: guide.access), LabeledText(label: "Parking", text: guide.parking)])
            Text(context).font(.caption2).foregroundStyle(.secondary)
        }
        FieldCard(eyebrow: "Typical seasons · as published") {
            Text(guide.seasons).font(.fieldBody)
            Text(context).font(.caption2).foregroundStyle(.secondary)
        }
        FieldCard(eyebrow: "Water & toilets · as published") {
            LabeledTextList(items: [LabeledText(label: "Drinking water", text: guide.water), LabeledText(label: "Toilets", text: guide.toilets)])
            if let etiquette = guide.etiquette { Text(etiquette).font(.fieldCaption).foregroundStyle(.secondary) }
            Text(context).font(.caption2).foregroundStyle(.secondary)
            SourceList(sources: [guide.source])
        }
    }
}
