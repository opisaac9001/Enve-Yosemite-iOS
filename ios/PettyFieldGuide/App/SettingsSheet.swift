import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var server = ServerConfig.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    ForEach(AppearanceChoice.allCases) { choice in
                        Button { theme.appearance = choice } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(choice.title).font(.fieldBody)
                                    Text(choice.detail).font(.fieldCaption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if theme.appearance == choice { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    let times = SolarCalculator.dayTimes(on: Date(), at: YosemiteGeo.valleyCenter, timeZone: YosemiteGeo.timeZone)
                    if let r = times.sunrise, let s = times.sunset {
                        Text("Today in Yosemite Valley: sunrise \(DateText.time(r)), solar noon \(DateText.time(times.solarNoon)), sunset \(DateText.time(s)) · Pacific, computed offline.")
                            .font(.fieldCaption).foregroundStyle(.secondary)
                    }
                }
                Section("Night vision") {
                    Toggle("Night vision", isOn: $theme.nightVision)
                    Text("Dims app content with a red tint. System controls may remain bright; lower screen brightness in Control Center if needed.")
                        .font(.fieldCaption).foregroundStyle(.secondary)
                }
                Section("Readability") {
                    Picker("Text size", selection: $theme.textSize) { ForEach(TextSizeChoice.allCases) { Text($0.title).tag($0) } }
                    Toggle("Bold text", isOn: $theme.boldText)
                    Picker("Map element size", selection: $theme.mapElementSize) { ForEach(MapElementSize.allCases) { Text($0.title).tag($0) } }
                    Text("System Dynamic Type and Bold Text settings also apply.").font(.fieldCaption).foregroundStyle(.secondary)
                }
                Section("Conditions server") {
                    TextField("https://your-server.example", text: $server.baseURLString)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text(server.isConfigured ? "Live weather, fire, smoke, road and event feeds refresh from this address. Everything else works without it." : "Not configured. The app stays fully usable offline; live feeds show as unavailable until a companion server address is entered. See server/README.md in the project for setup.")
                        .font(.fieldCaption).foregroundStyle(.secondary)
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    Text("Enve Yosemite is an independent visitor guide, not a National Park Service product. Data sources and licences are listed in each section and in the map key.").font(.fieldCaption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
