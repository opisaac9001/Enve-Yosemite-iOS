import SwiftUI

struct FieldCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var title: String?
    var eyebrow: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if eyebrow != nil || title != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let eyebrow { Text(eyebrow).font(.fieldEyebrow).foregroundStyle(.secondary).textCase(.uppercase) }
                    if let title { Text(title).font(.fieldHeading) }
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.card(scheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.cardStroke(scheme)))
    }
}

struct LabeledTextList: View {
    let items: [LabeledText]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items, id: \.label) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label).font(.fieldEyebrow).foregroundStyle(.secondary)
                    Text(item.text).font(.fieldBody)
                }
            }
        }
    }
}

struct SourceList: View {
    let sources: [SourceLink]
    var note: String?
    var checked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let checked { Text("Reviewed \(DateText.long(checked))").font(.fieldCaption).foregroundStyle(.secondary) }
            if let note { Text(note).font(.fieldCaption).foregroundStyle(.secondary) }
            ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                if let urlString = source.url, let url = URL(string: urlString) {
                    Link(destination: url) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "arrow.up.right.square").font(.caption)
                            Text(sourceTitle(source)).font(.fieldCaption).multilineTextAlignment(.leading)
                        }
                    }
                } else {
                    Text(sourceTitle(source)).font(.fieldCaption)
                }
            }
        }
    }

    private func sourceTitle(_ s: SourceLink) -> String {
        var parts = [s.label]
        if let updated = s.updated { parts.append("updated \(DateText.long(updated))") }
        if let checked = s.checked, s.updated == nil { parts.append("checked \(DateText.long(checked))") }
        return parts.joined(separator: " · ")
    }
}

struct PhoneRow: View {
    let phone: PhoneNumber
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(phone.label).font(.fieldCaption).foregroundStyle(.secondary)
                Text(phone.number).font(.fieldBody.weight(.semibold))
                if let note = phone.note { Text(note).font(.fieldCaption) }
                if let hours = phone.hours { Text(hours).font(.fieldCaption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let url = PhoneFormat.telURL(phone.number) {
                Link(destination: url) { Image(systemName: "phone.circle.fill").font(.title2).foregroundStyle(Palette.accent) }
                    .accessibilityLabel("Call \(phone.label)")
            }
        }
    }
}

enum PhoneFormat {
    static func digits(_ s: String) -> String { s.filter(\.isNumber) }

    static func telURL(_ number: String) -> URL? {
        let d = digits(number)
        guard d.count >= 3 else { return nil }
        return URL(string: "tel:\(d)")
    }
}

enum DateText {
    // Formatters are thread-safe for formatting once configured; they are never mutated after creation.
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = YosemiteGeo.calendar
        f.timeZone = YosemiteGeo.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parse(_ s: String) -> Date? {
        iso.date(from: s) ?? isoPlain.date(from: s) ?? dayFormatter.date(from: s)
    }

    static func isoString(_ date: Date) -> String { iso.string(from: date) }

    /// "2026-10-05" → "October 5, 2026"; ISO timestamps → date and Pacific time.
    static func long(_ s: String) -> String {
        guard let date = parse(s) else { return s }
        let f = DateFormatter()
        f.timeZone = YosemiteGeo.timeZone
        f.dateStyle = .long
        f.timeStyle = s.count > 10 ? .short : .none
        return f.string(from: date)
    }

    static func short(_ date: Date, time: Bool = true) -> String {
        let f = DateFormatter()
        f.timeZone = YosemiteGeo.timeZone
        f.dateStyle = .medium
        f.timeStyle = time ? .short : .none
        return f.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = YosemiteGeo.timeZone
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
}

struct StatusPill: View {
    let state: SourceState
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Palette.stateColor(state)).frame(width: 8, height: 8)
            Text(text).font(.fieldCaption)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.fieldHeading)
            Text(message).font(.fieldCaption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }
}

/// Scroll container that pads for the floating pill bar.
struct FieldScroll<Content: View>: View {
    @Environment(\.bottomBarInset) private var inset
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, inset + 16)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

struct ChipButton: View {
    let title: String
    var symbol: String?
    var active: Bool
    var color: Color = Palette.accent
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.caption) }
                Text(title).font(.fieldCaption.weight(.semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(active ? color : Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(active ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct ExternalLinkRow: View {
    let label: String
    let url: URL
    var body: some View {
        Link(destination: url) {
            HStack {
                Text(label).font(.fieldBody)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

extension View {
    func fieldNavigationTitle(_ title: String) -> some View {
        navigationTitle(title).toolbarBackground(.hidden, for: .navigationBar)
    }
}
