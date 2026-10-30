import SwiftUI

struct SunPreviewSheet: View {
    @ObservedObject var model: MapViewModel
    @ObservedObject private var packs = GeoPackStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var day = Date()
    @State private var minuteOfDay: Double = 720
    @State private var rendering = false
    @State private var litFraction: Double?

    private var times: SolarCalculator.DayTimes { SolarCalculator.dayTimes(on: day, at: YosemiteGeo.valleyCenter, timeZone: YosemiteGeo.timeZone) }
    private var previewDate: Date { YosemiteGeo.calendar.startOfDay(for: day).addingTimeInterval(minuteOfDay * 60) }
    private var position: SolarCalculator.Position { SolarCalculator.position(at: previewDate, coordinate: YosemiteGeo.valleyCenter) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    HStack {
                        Button { shift(days: -1) } label: { Image(systemName: "chevron.left") }
                        Spacer()
                        DatePicker("", selection: $day, displayedComponents: .date).labelsHidden().environment(\.timeZone, YosemiteGeo.timeZone)
                        Spacer()
                        Button { shift(days: 1) } label: { Image(systemName: "chevron.right") }
                    }
                    .buttonStyle(.bordered)
                    Button("Today") { day = Date(); minuteOfDay = currentMinute() }
                }
                Section("Time · Pacific") {
                    Slider(value: $minuteOfDay, in: 0...1439, step: 5) { Text("Time") }
                    HStack {
                        Text(DateText.time(previewDate)).font(.fieldHeading)
                        Spacer()
                        Button("Now") { minuteOfDay = currentMinute() }
                        if let r = times.sunrise { Button("Sunrise") { minuteOfDay = minute(of: r) } }
                        Button("Noon") { minuteOfDay = minute(of: times.solarNoon) }
                        if let s = times.sunset { Button("Sunset") { minuteOfDay = minute(of: s) } }
                    }
                    .font(.fieldCaption)
                    .buttonStyle(.bordered)
                }
                Section("Sun") {
                    let p = position
                    LabeledContent("Altitude", value: String(format: "%.1f°", p.altitude))
                    LabeledContent("Azimuth", value: String(format: "%.0f° %@", p.azimuth, SolarCalculator.compassName(forAzimuth: p.azimuth)))
                    LabeledContent("Phase", value: SolarCalculator.phase(forAltitude: p.altitude).title)
                    if let r = times.sunrise, let s = times.sunset {
                        LabeledContent("Sunrise · noon · sunset", value: "\(DateText.time(r)) · \(DateText.time(times.solarNoon)) · \(DateText.time(s))")
                    }
                    Text("Astronomical horizon at the central Valley point (zenith 90.833°). Cliffs put most of the Valley floor in shade well before sunset.")
                        .font(.fieldCaption).foregroundStyle(.secondary)
                }
                Section("Terrain shadow preview") {
                    if let terrain = packs.terrain {
                        Button(rendering ? "Rendering…" : "Show terrain occlusion on the map") { Task { await render(terrain) } }.disabled(rendering)
                        if let litFraction {
                            Text(String(format: "%.0f%% of grid cells are sunlit at this time.", litFraction * 100)).font(.fieldCaption)
                        }
                        if model.sunPreview != nil {
                            Button("Hide preview", role: .destructive) { model.sunPreview = nil; litFraction = nil }
                        }
                        Text("Computed from the bundled \(terrain.width)×\(terrain.height) elevation grid (\(terrain.source), fetched \(DateText.long(terrain.fetchedAt))) covering \(String(format: "%.3f", terrain.bounds.west))…\(String(format: "%.3f", terrain.bounds.east)) longitude. Clouds, trees, buildings and mountains outside the grid are not modelled; cells near the grid edge may be lit only because the blocking terrain lies outside it.")
                            .font(.fieldCaption).foregroundStyle(.secondary)
                    } else {
                        Text("Loading the elevation grid…").font(.fieldCaption)
                    }
                }
            }
            .navigationTitle("Sun & terrain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await packs.loadTerrain() }
            .onAppear { if let p = model.sunPreview { day = p.date; minuteOfDay = minute(of: p.date) } else { minuteOfDay = currentMinute() } }
        }
        .presentationDetents([.medium, .large])
    }

    private func currentMinute() -> Double {
        let c = YosemiteGeo.calendar.dateComponents([.hour, .minute], from: Date())
        return Double((c.hour ?? 12) * 60 + (c.minute ?? 0))
    }

    private func minute(of date: Date) -> Double {
        let c = YosemiteGeo.calendar.dateComponents([.hour, .minute], from: date)
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
    }

    private func shift(days: Int) {
        day = YosemiteGeo.calendar.date(byAdding: .day, value: days, to: day) ?? day
    }

    private func render(_ terrain: TerrainGrid) async {
        rendering = true
        let date = previewDate
        let pos = position
        let projection = model.scene?.projection ?? LocalProjection(origin: YosemiteGeo.valleyCenter)
        let result = await Task.detached(priority: .userInitiated) {
            ShadowRenderer.render(grid: terrain, altitudeDeg: pos.altitude, azimuthDeg: pos.azimuth, projection: projection)
        }.value
        rendering = false
        guard let result else { return }
        litFraction = result.litFraction
        model.sunPreview = SunPreviewState(date: date, altitude: pos.altitude, azimuth: pos.azimuth,
                                           overlay: MapOverlayImage(image: result.image, rect: result.rect, alpha: 1))
    }
}
