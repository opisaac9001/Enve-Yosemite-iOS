import SwiftUI
import CoreLocation

enum TrailheadDaylight {
    /// Midday of the Pacific calendar day `offset` days from the one containing `now`, so stepping lands on
    /// whole local days across daylight-saving changes and whatever zone the device is in.
    static func day(offset: Int, from now: Date) -> Date {
        let calendar = YosemiteGeo.calendar
        let start = calendar.startOfDay(for: now)
        let shifted = calendar.date(byAdding: .day, value: offset, to: start) ?? start
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: shifted) ?? shifted
    }

    static func length(_ times: SolarCalculator.DayTimes) -> String? {
        guard let rise = times.sunrise, let set = times.sunset else { return nil }
        let minutes = Int((set.timeIntervalSince(rise) / 60).rounded())
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// Offline sun times for the trailhead point on a chosen day.
struct TrailheadDaylightCard: View {
    let coordinate: CLLocationCoordinate2D
    @State private var offset = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let now = Date()
        let day = TrailheadDaylight.day(offset: offset, from: now)
        let times = SolarCalculator.dayTimes(on: day, at: coordinate, timeZone: YosemiteGeo.timeZone)
        FieldCard(eyebrow: "Daylight at the trailhead · Pacific time") {
            HStack {
                step(-1, symbol: "chevron.left", label: "Previous day")
                Button { offset = 0 } label: {
                    Text(offset == 0 ? "Today · \(DateText.short(day, time: false))" : DateText.short(day, time: false))
                        .font(.fieldBody.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(offset == 0)
                .accessibilityLabel(offset == 0 ? "Today, \(DateText.short(day, time: false))" : "\(DateText.short(day, time: false)). Return to today")
                step(1, symbol: "chevron.right", label: "Next day")
            }
            let rows: [(String, String)] = [("First light", times.civilDawn.map(DateText.time) ?? "–"), ("Sunrise", times.sunrise.map(DateText.time) ?? "–"),
                                            ("Sunset", times.sunset.map(DateText.time) ?? "–"), ("Last light", times.civilDusk.map(DateText.time) ?? "–")]
            if typeSize.isAccessibilitySize {
                ForEach(rows, id: \.0) { LabeledContent($0.0, value: $0.1).font(.fieldBody) }
            } else {
                HStack(alignment: .top) { ForEach(rows, id: \.0) { stat($0.0, $0.1) } }
            }
            if let length = TrailheadDaylight.length(times) {
                Text("Sun above the horizon for \(length).").font(.fieldCaption)
            }
            if offset == 0 { DaylightBar(now: now, times: times) }
            Text("Calculated on this device with NOAA solar equations for the trailhead point and a flat horizon. Ridges, cliffs and forest can hide the sun well before sunset; first and last light are civil twilight. Weather is not included.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func step(_ delta: Int, symbol: String, label: String) -> some View {
        Button { offset += delta } label: { Image(systemName: symbol).frame(width: 44, height: 44) }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accent)
            .accessibilityLabel(label)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.fieldBody.weight(.semibold)).minimumScaleFactor(0.75).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
