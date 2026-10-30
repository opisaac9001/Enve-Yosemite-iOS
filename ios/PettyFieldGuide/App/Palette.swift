import SwiftUI

enum Palette {
    static let accent = Color(red: 0xF5 / 255, green: 0x92 / 255, blue: 0x1A / 255)
    static let pine = Color(red: 0x1F / 255, green: 0x4D / 255, blue: 0x3F / 255)
    static let granite = Color(red: 0x8A / 255, green: 0x90 / 255, blue: 0x98 / 255)
    static let river = Color(red: 0x3B / 255, green: 0x7E / 255, blue: 0xA8 / 255)
    static let ember = Color(red: 0xC9 / 255, green: 0x3B / 255, blue: 0x2E / 255)
    static let meadow = Color(red: 0x6E / 255, green: 0x9C / 255, blue: 0x4A / 255)

    /// Backgrounds: true black in dark mode for OLED, warm paper in light mode.
    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black : Color(red: 0.97, green: 0.95, blue: 0.91)
    }

    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.09) : Color.white.opacity(0.78)
    }

    static func cardStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    static func stateColor(_ state: SourceState) -> Color {
        switch state {
        case .ready: meadow
        case .stale: accent
        case .expired, .unavailable: ember
        case .unknown, .none: granite
        }
    }
}

enum SourceState: String, Codable, Sendable {
    case ready, stale, expired, unavailable, unknown, none
}

extension Font {
    static let fieldTitle = Font.system(.title2, design: .rounded).weight(.bold)
    static let fieldHeading = Font.system(.headline, design: .rounded).weight(.semibold)
    static let fieldEyebrow = Font.system(.caption, design: .rounded).weight(.semibold)
    static let fieldBody = Font.system(.body)
    static let fieldCaption = Font.system(.caption)
    static let fieldMono = Font.system(.caption, design: .monospaced)
}
