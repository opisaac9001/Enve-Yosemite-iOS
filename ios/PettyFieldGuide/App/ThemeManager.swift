import SwiftUI
import Combine

enum AppearanceChoice: String, CaseIterable, Codable, Identifiable {
    case system, sunset, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Follow system"
        case .sunset: "Sunset to sunrise"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var detail: String {
        switch self {
        case .system: "Match the device appearance."
        case .sunset: "Dark after sunset in Yosemite Valley, light after sunrise. Calculated on this device."
        case .light: "Always light."
        case .dark: "Always dark, with true black for OLED screens."
        }
    }
}

enum TextSizeChoice: String, CaseIterable, Codable, Identifiable {
    case system, larger, largest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .larger: "Larger"
        case .largest: "Largest"
        }
    }
}

enum MapElementSize: String, CaseIterable, Codable, Identifiable {
    case compact, standard, large
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: "Compact"
        case .standard: "Standard"
        case .large: "Large"
        }
    }
    var scale: CGFloat {
        switch self {
        case .compact: 0.85
        case .standard: 1.0
        case .large: 1.25
        }
    }
}

/// Appearance and readability preferences. Published through `didSet` so changes made from
/// anywhere propagate, which `@AppStorage` inside an `ObservableObject` does not do.
@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var appearance: AppearanceChoice { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) } }
    @Published var textSize: TextSizeChoice { didSet { defaults.set(textSize.rawValue, forKey: Keys.textSize) } }
    @Published var boldText: Bool { didSet { defaults.set(boldText, forKey: Keys.boldText) } }
    @Published var mapElementSize: MapElementSize { didSet { defaults.set(mapElementSize.rawValue, forKey: Keys.mapElementSize) } }
    @Published private(set) var sunIsUp = true

    private let defaults = UserDefaults.standard
    private var minuteTimer: Timer?

    private enum Keys {
        static let appearance = "theme.appearance"
        static let textSize = "theme.textSize"
        static let boldText = "theme.boldText"
        static let mapElementSize = "theme.mapElementSize"
    }

    private init() {
        appearance = AppearanceChoice(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        textSize = TextSizeChoice(rawValue: defaults.string(forKey: Keys.textSize) ?? "") ?? .system
        boldText = defaults.bool(forKey: Keys.boldText)
        mapElementSize = MapElementSize(rawValue: defaults.string(forKey: Keys.mapElementSize) ?? "") ?? .standard
        refreshSun()
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSun() }
        }
    }

    var resolvedColorScheme: ColorScheme? {
        switch appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        case .sunset: sunIsUp ? .light : .dark
        }
    }

    var dynamicTypeOverride: DynamicTypeSize? {
        switch textSize {
        case .system: nil
        case .larger: .xLarge
        case .largest: .xxxLarge
        }
    }

    private func refreshSun() {
        let times = SolarCalculator.dayTimes(on: Date(), at: YosemiteGeo.valleyCenter, timeZone: YosemiteGeo.timeZone)
        let now = Date()
        if let rise = times.sunrise, let set = times.sunset {
            sunIsUp = now >= rise && now < set
        } else {
            sunIsUp = true
        }
    }
}
