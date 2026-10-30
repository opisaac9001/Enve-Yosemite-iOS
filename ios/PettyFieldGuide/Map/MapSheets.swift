import SwiftUI

struct MapLayersSheet: View {
    @ObservedObject var model: MapViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Routes") {
                    Toggle("Shuttle routes", isOn: $model.layers.shuttleRoutes)
                    Toggle("Emphasize shuttle routes", isOn: $model.layers.emphasizeShuttle).disabled(!model.layers.shuttleRoutes)
                }
                Section("Terrain") {
                    Toggle("Contours (50 m from the relief grid)", isOn: $model.layers.contours)
                    Text("Shaded relief is always drawn from the bundled Mapzen/USGS elevation grid; contours add 50 m lines on top.").font(.fieldCaption).foregroundStyle(.secondary)
                }
                Section("Buildings") {
                    Toggle("Building footprints", isOn: $model.layers.buildings)
                    Picker("Building names", selection: $model.layers.buildingLabels) {
                        ForEach(BuildingLabelMode.allCases) { Text($0.title).tag($0) }
                    }
                    Text("Names appear when zoomed in; building numbers from NPS records show at the closest zoom.").font(.fieldCaption).foregroundStyle(.secondary)
                }
                Section("Smoke") {
                    Toggle("Satellite smoke plumes", isOn: $model.layers.smoke)
                    Text(model.smokePolygons.isEmpty ? "No saved smoke analysis yet. Refresh Fire & smoke with a connection; plumes expire after 48 hours." : "Showing \(model.smokePolygons.count) NOAA HMS plume polygons from the saved snapshot.")
                        .font(.fieldCaption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Map layers")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

/// Every place category with its own toggle; the quick chips on the map are a subset of these.
struct MapCategoriesSheet: View {
    @ObservedObject var model: MapViewModel
    let categories: [PlaceCategory]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Button("Show all") { model.activeCategories = Set(categories.map(\.id)) }
                        Spacer()
                        Button("Default set") { model.activeCategories = MapViewModel.defaultCategories }
                        Spacer()
                        Button("Hide all") { model.activeCategories = [] }
                    }
                    .buttonStyle(.bordered).font(.fieldCaption)
                }
                Section("Categories") {
                    ForEach(categories) { category in
                        Toggle(isOn: binding(for: category.id)) {
                            Label {
                                Text(category.label)
                            } icon: {
                                Image(systemName: category.symbol).foregroundStyle(Color(UIColor(hex: category.color)))
                            }
                        }
                    }
                }
                Section {
                    Text("Saved places, your parked car, your campsite and whatever is selected stay on the map whichever categories are hidden. Choices are kept on this device.")
                        .font(.fieldCaption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Map filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { model.activeCategories.contains(id) },
                set: { on in if on { model.activeCategories.insert(id) } else { model.activeCategories.remove(id) } })
    }
}

struct MapKeySheet: View {
    let scene: MapScene?

    var body: some View {
        NavigationStack {
            List {
                Section("Terrain") {
                    HStack(spacing: 10) {
                        LinearGradient(colors: [Color(red: 0.90, green: 0.88, blue: 0.81), Color(red: 0.55, green: 0.53, blue: 0.49), Color(red: 0.76, green: 0.77, blue: 0.78)], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 28, height: 10).clipShape(RoundedRectangle(cornerRadius: 2))
                        Text("Shaded relief lit from the north-west, tinted from valley floor (warm) to high granite (cool). Terrain only: it does not classify meadows or forest.").font(.fieldCaption)
                    }
                    keyRow(color: Color(red: 0.50, green: 0.40, blue: 0.26).opacity(0.6), stroke: nil, "Contours every 50 m (optional layer)")
                }
                Section("Lines") {
                    keyRow(color: .white, stroke: Color(red: 0.46, green: 0.43, blue: 0.39), "Secondary roads (Northside/Southside Drive, El Portal, Wawona, Big Oak Flat)")
                    keyRow(color: Color(red: 0.985, green: 0.975, blue: 0.95), stroke: Color(red: 0.46, green: 0.43, blue: 0.39), "Local roads")
                    keyRow(color: Color(red: 0.93, green: 0.91, blue: 0.87), stroke: Color(red: 0.64, green: 0.62, blue: 0.58), "Service, parking-lot and private roads · appear when zoomed in; dashed when seasonal")
                    keyRow(color: Color(red: 0.55, green: 0.30, blue: 0.16), stroke: nil, "Hiking trails (dashed; minor paths appear when zoomed in)")
                    keyRow(color: Palette.accent, stroke: Color(red: 1.0, green: 0.96, blue: 0.88), "Selected hike route (complete published route on NPS trail features; start and destination badges)")
                    keyRow(color: Color(red: 0.12, green: 0.47, blue: 0.42), stroke: nil, "Paved bike paths")
                    keyRow(color: Color(red: 0.27, green: 0.50, blue: 0.71), stroke: nil, "Merced River (USGS NHD main stem)")
                    keyRow(color: Color(red: 0.40, green: 0.60, blue: 0.77), stroke: nil, "Creeks and tributaries (USGS NHD)")
                    keyRow(color: Color(hex: "#3eb649"), stroke: nil, "Valleywide shuttle (arrows show travel direction)")
                    keyRow(color: Color(hex: "#a8509e"), stroke: nil, "East Valley shuttle (dashed)")
                    Text("▶ One-way arrows follow the NPS digitized road direction.").font(.fieldCaption)
                }
                Section("Areas") {
                    keyRow(color: Color(red: 0.74, green: 0.67, blue: 0.58), stroke: nil, "Buildings (NPS footprints; grey when closed or decommissioned)")
                    keyRow(color: Color(red: 0.80, green: 0.78, blue: 0.74), stroke: nil, "Parking lots (NPS polygons; a lot on the map is not an open or available lot)")
                }
                Section("Markers") {
                    Text("Pin colours follow the filter categories; names appear beside important places as you zoom in. Orange marks saved places, your car and your campsite. Square green badges are numbered shuttle stops; when zoomed out, nearby stops or places merge into a count — tap it to zoom in. Site numbers appear at the closest zoom.").font(.fieldCaption)
                }
                Section("Sources") {
                    ForEach(scene?.sources ?? [], id: \.self) { Text($0).font(.fieldCaption) }
                    Text("NPS geometry is orientation data with mostly unknown positional accuracy, not survey data. Relief comes from Mapzen/Tilezen Terrarium tiles on AWS Open Data (USGS 3DEP/NED for this area); the sun preview uses its own smaller grid.").font(.fieldCaption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Map key")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func keyRow(color: Color, stroke: Color?, _ text: String) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 28, height: 6)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(stroke ?? .clear, lineWidth: 1))
            Text(text).font(.fieldCaption)
        }
    }
}

extension Color {
    init(hex: String) { self.init(UIColor(hex: hex)) }
}
