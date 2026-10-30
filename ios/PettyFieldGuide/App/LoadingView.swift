import SwiftUI

/// Park facts shown while bundled packs decode. Facts cite NPS pages.
struct ParkFact: Identifiable {
    let id = UUID()
    let title: String
    let text: String
    let sourcePath: String

    static let all: [ParkFact] = [
        ParkFact(title: "Mostly wilderness", text: "About 95 percent of Yosemite is designated wilderness. The Valley is a small fraction of the park.", sourcePath: "learn/nature/index.htm"),
        ParkFact(title: "Two rivers", text: "Both the Merced and the Tuolumne rise inside the park and flow west toward the Central Valley.", sourcePath: "learn/nature/index.htm"),
        ParkFact(title: "A fall in three steps", text: "Yosemite Falls drops 2,425 feet across its upper fall, middle cascades and lower fall.", sourcePath: "learn/nature/natural-resource-statistics.htm"),
        ParkFact(title: "Three sequoia groves", text: "Giant sequoias grow in the Mariposa, Tuolumne and Merced groves. Mariposa is the largest, with more than 500 mature trees.", sourcePath: "faqs.htm"),
        ParkFact(title: "World Heritage", text: "Yosemite was inscribed as a World Heritage Site in 1984 for its landscape.", sourcePath: "learn/nature/index.htm"),
        ParkFact(title: "Carved by ice", text: "Glaciers shaped the Valley's walls and polished the domes around Tuolumne Meadows.", sourcePath: "learn/nature/naturalfeaturesandecosystems.htm"),
    ]

    var sourceURL: URL { URL(string: "https://www.nps.gov/yose/\(sourcePath)")! }
}

struct LoadingView: View {
    @State private var index = Int.random(in: 0..<ParkFact.all.count)
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            DynamicBackground()
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "mountain.2.fill")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Text("Enve Yosemite")
                    .font(.fieldTitle)
                ProgressView("Opening the offline guide…")
                    .font(.fieldCaption)
                let fact = ParkFact.all[index]
                VStack(alignment: .leading, spacing: 8) {
                    Text(fact.title).font(.fieldHeading)
                    Text(fact.text).font(.fieldBody).foregroundStyle(.secondary)
                    Link("NPS source", destination: fact.sourceURL).font(.fieldCaption)
                }
                .padding(16)
                .frame(maxWidth: 420, alignment: .leading)
                .background(Palette.card(scheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Button("Another fact") { index = (index + 1) % ParkFact.all.count }
                    .font(.fieldCaption)
                Spacer()
                Text("Independent visitor guide, not an NPS product.")
                    .font(.fieldCaption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)
            }
            .padding(24)
        }
    }
}

struct LoadFailureView: View {
    let message: String

    var body: some View {
        ZStack {
            DynamicBackground()
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(Palette.ember)
                Text("The bundled guide could not be opened").font(.fieldHeading)
                Text(message).font(.fieldBody).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(32)
        }
    }
}
