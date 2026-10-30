import SwiftUI

struct PillTabBar: View {
    @Binding var selection: AppSection
    @Binding var showMore: Bool
    @Environment(\.colorScheme) private var scheme

    private var moreIsActive: Bool { !AppSection.pillTabs.contains(selection) }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppSection.pillTabs) { section in
                tab(symbol: section.symbol, title: section.compactTitle, active: selection == section) {
                    selection = section
                }
            }
            tab(symbol: moreIsActive ? selection.symbol : "ellipsis.circle.fill",
                title: moreIsActive ? selection.compactTitle : "More",
                active: moreIsActive) { showMore = true }
        }
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.cardStroke(scheme), lineWidth: 1))
        .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.14), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }

    private func tab(symbol: String, title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(active ? Color.white : Color.primary.opacity(0.75))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(active ? Palette.accent : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
    }
}

struct MoreSheet: View {
    let choose: (AppSection) -> Void
    @Environment(\.colorScheme) private var scheme

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(AppSection.groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.title).font(.fieldEyebrow).foregroundStyle(.secondary).textCase(.uppercase)
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(group.sections) { section in
                                    Button { choose(section) } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Image(systemName: section.symbol)
                                                .font(.title3.weight(.semibold))
                                                .foregroundStyle(Palette.accent)
                                            Text(section.title).font(.fieldHeading).multilineTextAlignment(.leading)
                                            Text(section.blurb).font(.fieldCaption).foregroundStyle(.secondary)
                                                .multilineTextAlignment(.leading)
                                                .lineLimit(3)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(14)
                                        .background(Palette.card(scheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.cardStroke(scheme)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    SettingsEntryCard()
                }
                .padding(16)
            }
            .background(DynamicBackground())
            .navigationTitle("All sections")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
    }
}
