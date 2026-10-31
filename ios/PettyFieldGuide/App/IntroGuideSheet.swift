import SwiftUI

struct IntroGuideSheet: View {
    @EnvironmentObject private var saved: SavedStore
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Page { let section: AppSection?; let title: String; let detail: String; let controls: [(String, String)] }

    private let pages: [Page] = [
        Page(section: nil, title: "Welcome to Enve Yosemite", detail: "An offline Yosemite Valley companion with park-wide context. Everything here works without signal; live feeds add to it when you refresh.", controls: []),
        Page(section: .map, title: "One offline park map", detail: "Zoom from the whole park's terrain, rivers, lakes and roads down to Valley buildings and campsite numbers without switching maps. Category chips choose which pins show; saved places, your car and your campsite always show.", controls: [("Mountains", "Find a region, park hike or campground."), ("+ / − / Fit", "Zoom, or frame the whole park or the Valley."), ("Layers", "Shuttle routes, contours, smoke."), ("Locate", "Shows your position only when you ask."), ("Sun", "Daylight and terrain-shadow preview."), ("Lock", "Freezes pinch zoom; buttons still work.")]),
        Page(section: .directory, title: "Places", detail: "Every mapped place with hours, access, phone numbers and the sources behind them. Quick filters find toilets, water, ice, showers and accessible spots.", controls: []),
        Page(section: .search, title: "Search", detail: "One box for places, campsite numbers, Housekeeping units, phone numbers, trails, permits, events and documents. Try “Upper Pines site 18”.", controls: []),
        Page(section: .trip, title: "Trip prep", detail: "Save weather and condition snapshots before you lose signal, back up your saved items, and check that the bundled packs are intact.", controls: []),
        Page(section: .status, title: "Conditions", detail: "Field status, Fire & smoke and Seasonal risks show each source with its own time and state. Nothing is presented as current after 48 hours.", controls: []),
    ]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                let p = pages[page]
                Text("Field guide · \(page + 1) of \(pages.count)").font(.fieldEyebrow).foregroundStyle(.secondary)
                if let s = p.section { Image(systemName: s.symbol).font(.largeTitle).foregroundStyle(Palette.accent) }
                Text(p.title).font(.fieldTitle)
                Text(p.detail).font(.fieldBody)
                ForEach(p.controls, id: \.0) { c in
                    HStack(alignment: .top) { Text(c.0).font(.fieldCaption.weight(.semibold)).frame(width: 90, alignment: .leading); Text(c.1).font(.fieldCaption) }
                }
                Spacer()
                HStack {
                    Button("Back") { page = max(0, page - 1) }.disabled(page == 0)
                    Spacer()
                    if page < pages.count - 1 {
                        Button("Next") { page += 1 }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Start") { finish() }.buttonStyle(.borderedProminent)
                    }
                }
                if let s = pages[page].section {
                    Button("Open \(s.title)") { finish(); router.show(s) }.font(.fieldCaption)
                }
            }
            .padding(24)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Skip") { finish() } } }
        }
        .presentationDetents([.large])
    }

    private func finish() {
        saved.update { $0.introGuideSeen = true }
        dismiss()
    }
}
