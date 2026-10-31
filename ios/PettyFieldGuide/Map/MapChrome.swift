import SwiftUI

/// The map's search field with settings and updates; one row when it fits, stacked otherwise.
struct MapTopBar<Field: View>: View {
    @ViewBuilder let field: () -> Field

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                field().frame(minWidth: 220)
                MapAppButtons()
            }
            VStack(alignment: .trailing, spacing: 8) {
                MapAppButtons()
                field()
            }
        }
    }
}

struct MapAppButtons: View {
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var updates = UpdatesStore.shared

    var body: some View {
        HStack(spacing: 8) {
            Button { router.sheet = .settings } label: {
                Image(systemName: "gearshape.fill").padding(10).background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Settings")
            Button { router.sheet = .updates } label: {
                Image(systemName: "bell.fill").padding(10).background(.regularMaterial, in: Circle())
                    .overlay(alignment: .topTrailing) {
                        if updates.unreadCount > 0 {
                            Text("\(updates.unreadCount)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .padding(4).background(Palette.accent, in: Circle())
                        }
                    }
            }
            .accessibilityLabel(updates.unreadCount > 0 ? "Updates, \(updates.unreadCount) unread" : "Updates")
        }
    }
}

struct MapControlGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.cardStroke(scheme)))
    }
}

struct MapControlButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    init(_ symbol: String, _ label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct TopChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 96
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct BottomChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 44
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
