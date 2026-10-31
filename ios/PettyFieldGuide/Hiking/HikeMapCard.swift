import SwiftUI

struct HikeMapCard: View {
    let trail: Trail
    let route: HikeRoute
    let content: Content
    @ObservedObject var model: MapViewModel
    var maxHeight: CGFloat = .infinity
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var packs = GeoPackStore.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showsTerrain = false
    @State private var inspection: HikeInspectorLoad = .loading
    @State private var attempt = 0
    @State private var bodyHeight: CGFloat = 0

    /// Chart, units, readout and controls need about this much viewport to be inspected together with the map.
    static let inlineTerrainViewport: CGFloat = 300

    private var published: TrailRoute? { trail.route(route.id) }
    private var figures: String { HikeFormat.figures(published, difficulty: published.map { trail.difficulty(for: $0) } ?? trail.difficulty, route: route) }
    private var variants: [HikeRoute] { content.hikeRoutes(for: trail.id) }
    private var layout: AnyLayout { typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8)) }
    private var viewportCap: CGFloat { max(44, maxHeight - 28) }
    private var bodyViewport: CGFloat { min(max(bodyHeight, 1), viewportCap) }
    private var inlineFits: Bool { !typeSize.isAccessibilitySize && verticalSizeClass != .compact && viewportCap >= Self.inlineTerrainViewport }
    private var sheetShown: Binding<Bool> { Binding(get: { showsTerrain && !inlineFits }, set: { if !$0 { showsTerrain = false } }) }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                summary
                rows
                if showsTerrain && inlineFits { terrain }
            }
            .background(GeometryReader { p in Color.clear.preference(key: BodyHeightKey.self, value: p.size.height) })
        }
        .frame(height: bodyViewport)
        .scrollBounceBehavior(.basedOnSize)
        .overlay(alignment: .topTrailing) {
            Button { model.clearHike() } label: { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary).frame(width: 44, height: 44) }
                .accessibilityLabel("Clear the hike from the map")
                .offset(x: 8, y: -8)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.cardStroke(scheme)))
        .onPreferenceChange(BodyHeightKey.self) { bodyHeight = $0 }
        .sheet(isPresented: sheetShown) {
            HikeTerrainSheet(trail: trail, route: route, figures: figures, inspection: inspection, model: model) { attempt += 1 }
                .nightVision()
        }
        .task(id: "\(route.id)#\(attempt)") {
            inspection = .loading
            let result = await packs.hikeInspector(for: route)
            // A variant switch cancels this task; its late result must not land under the new route.
            guard !Task.isCancelled else { return }
            inspection = result.map { .ready($0) } ?? .unavailable
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(trail.name).font(.fieldHeading)
            Text(figures).font(.fieldCaption).foregroundStyle(.secondary)
            Text(route.kind == .loop ? "Loop from \(route.start.name)" : "\(route.start.name) → \(route.destination.name)").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 36)
    }

    @ViewBuilder private var rows: some View {
        layout {
            if variants.count > 1 {
                Menu {
                    ForEach(variants) { variant in
                        Button { model.selectHike(variant.id) } label: {
                            if variant.id == route.id { Label(variant.label, systemImage: "checkmark") } else { Text(variant.label) }
                        }
                    }
                } label: { Label(route.label, systemImage: "arrow.triangle.branch").lineLimit(2).frame(minHeight: 44) }
                .accessibilityLabel("Route variant: \(route.label)")
            } else {
                Label(route.label, systemImage: "arrow.triangle.branch").lineLimit(2).frame(minHeight: 44)
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 4) }
            Button { model.fitActiveRoute() } label: { Label("Fit", systemImage: "arrow.down.left.and.arrow.up.right").frame(minHeight: 44) }
                .accessibilityLabel("Fit the whole route")
            Button { router.push(.hikeRoute(trailId: trail.id, routeId: route.id), in: .trails) } label: { Label("Details", systemImage: "info.circle").frame(minHeight: 44) }
        }
        .buttonStyle(.bordered).font(.fieldCaption)
        layout {
            Button { withAnimation(.easeInOut(duration: 0.2)) { showsTerrain.toggle() } } label: {
                Label("Terrain", systemImage: inlineFits ? (showsTerrain ? "chevron.up" : "chevron.down") : "chart.xyaxis.line").frame(minHeight: 44)
            }
            .buttonStyle(.bordered).font(.fieldCaption)
            .accessibilityLabel(showsTerrain && inlineFits ? "Hide the terrain inspector" : "Show the terrain inspector")
            if !typeSize.isAccessibilitySize { Spacer(minLength: 4) }
            Picker("Map content", selection: $model.focusesHike) {
                Text("Focus").tag(true)
                Text("All places").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            .accessibilityLabel("Map content")
            .accessibilityHint("Focus quiets places unrelated to the hike without changing your filters")
        }
    }

    @ViewBuilder private var terrain: some View {
        if case .ready(let inspector) = inspection, inspector.routeId == route.id {
            HikeTerrainInspector(inspector: inspector,
                                 metres: Binding(get: { model.inspectedMetres }, set: { model.inspect(metres: $0) }),
                                 chartHeight: 110, reservesReadoutSpace: true,
                                 onCenter: { model.centerOnInspection() })
        } else if case .unavailable = inspection {
            Text("No terrain profile: the route or the relief grid could not be loaded.").font(.fieldCaption).foregroundStyle(Palette.ember)
            Button { attempt += 1 } label: { Label("Try again", systemImage: "arrow.clockwise").frame(minHeight: 44) }.buttonStyle(.bordered).font(.fieldCaption)
        } else {
            ProgressView().frame(maxWidth: .infinity).frame(height: 110)
        }
    }
}

private struct BodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

enum HikeFormat {
    /// "Strenuous · 2.4 mi round trip · 1,000 ft gain · about 2–4 hours" from the published figures.
    static func figures(_ published: TrailRoute?, difficulty: String, route: HikeRoute) -> String {
        guard let published else { return "\(difficulty) · \(route.kind.title)" }
        var parts = [difficulty, "\(miles(published.distanceMi)) \(published.kind)"]
        if let gain = published.gainFt { parts.append("\(feet(gain)) gain") }
        if let time = published.timeHours { parts.append("about \(time)") }
        return parts.joined(separator: " · ")
    }

    static func miles(_ value: Double) -> String {
        String(format: value == value.rounded() ? "%.0f mi" : "%.1f mi", value)
    }

    /// Mapped distance along a trace, always to a tenth of a mile.
    static func inspectionMiles(_ metres: Double) -> String {
        String(format: "%.1f mi", metres / 1609.344)
    }

    static func feet(_ value: Int) -> String {
        "\(value.formatted(.number.grouping(.automatic))) ft"
    }

    static func feet(metres: Double) -> String {
        feet(Int((metres * 3.28084).rounded()))
    }
}
