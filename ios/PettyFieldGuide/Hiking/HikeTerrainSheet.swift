import SwiftUI

struct HikeTerrainSheet: View {
    let trail: Trail
    let route: HikeRoute
    let figures: String
    let inspection: HikeInspectorLoad
    @ObservedObject var model: MapViewModel
    let onRetry: () -> Void
    @ObservedObject private var packs = GeoPackStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    private var inspector: HikeInspector? {
        if case .ready(let i) = inspection, i.routeId == route.id { return i } else { return nil }
    }

    private var cursor: CGPoint? { inspector.flatMap { i in model.inspectedMetres.map { i.chainage.point(at: $0) } } }

    var body: some View {
        NavigationStack {
            GeometryReader { p in
                if p.size.width > p.size.height * 1.4, !typeSize.isAccessibilitySize {
                    HStack(alignment: .top, spacing: 14) {
                        miniMap.frame(maxWidth: .infinity, maxHeight: .infinity)
                        ScrollView(.vertical) { terrain }.frame(maxWidth: .infinity).scrollBounceBehavior(.basedOnSize)
                    }
                    .padding(16)
                } else {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 12) {
                            miniMap.frame(height: 220)
                            terrain
                        }
                        .padding(16)
                    }
                }
            }
            .background(DynamicBackground())
            .navigationTitle(trail.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder private var miniMap: some View {
        if case .ready(let scene) = packs.map, let trace = scene.hikeRoutes[route.id] {
            HikeMiniMap(scene: scene, route: route, trace: trace, dark: scheme == .dark, cursor: cursor)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Map of the route, north up, from \(route.start.name)\(route.kind == .loop ? " and back" : " to \(route.destination.name)")\(cursor == nil ? "" : ", with the inspected point marked").")
        } else {
            Text("Route geometry unavailable.").font(.fieldCaption).foregroundStyle(Palette.ember)
        }
    }

    private var terrain: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(route.label).font(.fieldHeading)
            Text(figures).font(.fieldCaption).foregroundStyle(.secondary)
            if let inspector {
                HikeTerrainInspector(inspector: inspector, metres: Binding(get: { model.inspectedMetres }, set: { model.inspect(metres: $0) }))
            } else if case .unavailable = inspection {
                Text("No terrain profile: the route or the relief grid could not be loaded.").font(.fieldCaption).foregroundStyle(Palette.ember)
                Button(action: onRetry) { Label("Try again", systemImage: "arrow.clockwise").frame(minHeight: 44) }.buttonStyle(.bordered).font(.fieldCaption)
            } else {
                ProgressView().frame(maxWidth: .infinity).frame(height: 150)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
