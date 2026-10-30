import SwiftUI

struct PermitsScreen: View {
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var router: AppRouter
    @State private var query = ""

    private let groupOrder = ["visitor", "organizer", "clarifications"]

    var body: some View {
        if let c = content.content {
            FieldScroll {
                TextField("What do you want to do? e.g. Half Dome, fishing, wedding, drone", text: $query).textFieldStyle(.roundedBorder)
                FieldCard(eyebrow: "Fire-area notice") {
                    Text(c.permits.fireNotice).font(.fieldCaption)
                    Button { router.show(.fire) } label: { Label(c.permits.fireNoticeLink.label, systemImage: "flame") }.font(.fieldCaption)
                }
                ForEach(groupOrder, id: \.self) { key in
                    let guides = filtered(c.permits.guides.filter { $0.group == key })
                    if !guides.isEmpty {
                        if let g = c.permits.groups[key] {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(g.title).font(.fieldHeading)
                                Text(g.lede).font(.fieldCaption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(guides) { guide in
                            NavigationLink(value: Route.permit(guide.id)) { PermitCard(guide: guide, labels: c.permits.requirementLabels) }.buttonStyle(.plain)
                        }
                    }
                }
                FieldCard(eyebrow: "Official sources") {
                    SourceList(sources: Array(c.permits.sources.values).sorted { $0.label < $1.label })
                    Text("Applications are made on the official sites; this guide explains rules as published on the dates shown and never submits anything for you.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .fieldNavigationTitle("Permits & reservations")
        }
    }

    private func filtered(_ guides: [PermitGuide]) -> [PermitGuide] {
        let q = SearchIndex.normalise(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return guides }
        let tokens = q.split(separator: " ").map(String.init)
        return guides.filter { g in
            let hay = SearchIndex.normalise(([g.title, g.plan, g.summary] + g.keywords).joined(separator: " "))
            return tokens.allSatisfy { hay.contains($0) }
        }
    }
}

struct PermitCard: View {
    let guide: PermitGuide
    let labels: [String: String]

    var body: some View {
        FieldCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(guide.plan).font(.fieldEyebrow).foregroundStyle(.secondary)
                    Text(guide.title).font(.fieldHeading)
                    HStack(spacing: 6) {
                        Text(labels[guide.requirement] ?? guide.requirement).font(.caption2.weight(.bold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(badgeColor.opacity(0.2), in: Capsule())
                        if let note = guide.badgeNote { Text(note).font(.caption2).foregroundStyle(.secondary) }
                    }
                    Text(guide.summary).font(.fieldCaption).lineLimit(3)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
    }

    private var badgeColor: Color {
        switch guide.requirement {
        case "permit", "reservation", "license", "pass": Palette.accent
        case "prohibited": Palette.ember
        case "no-permit": Palette.meadow
        default: Palette.granite
        }
    }
}

struct PermitDetailView: View {
    let guideId: String
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        if let c = content.content, let guide = c.permit(guideId) {
            FieldScroll {
                FieldCard {
                    Text(guide.plan).font(.fieldEyebrow).foregroundStyle(.secondary)
                    Text(c.permits.requirementLabels[guide.requirement] ?? guide.requirement).font(.fieldHeading).foregroundStyle(Palette.accent)
                    if let note = guide.badgeNote { Text(note).font(.fieldCaption).foregroundStyle(.secondary) }
                    Text(guide.summary).font(.fieldBody)
                    if let action = guide.action, let url = URL(string: action.url) {
                        Link(destination: url) { Label(action.label, systemImage: "arrow.up.right.square") }.buttonStyle(.borderedProminent).font(.fieldCaption)
                    }
                    Text("Rules as published \(DateText.long(guide.checked)); verify the official page before applying.").font(.caption2).foregroundStyle(.secondary)
                }
                if let notices = guide.notices, !notices.isEmpty {
                    FieldCard(eyebrow: "Dated notices & source conflicts") {
                        ForEach(notices, id: \.self) { Label($0, systemImage: "exclamationmark.circle").font(.fieldCaption) }
                    }
                }
                FieldCard(eyebrow: "What the rules say") { LabeledTextList(items: guide.facts) }
                if let phones = guide.phones, !phones.isEmpty {
                    FieldCard(eyebrow: "Phone") { ForEach(phones, id: \.number) { PhoneRow(phone: $0) } }
                }
                if let emails = guide.emails, !emails.isEmpty {
                    FieldCard(eyebrow: "Email") {
                        ForEach(emails, id: \.address) { e in
                            if let url = URL(string: "mailto:\(e.address)") { ExternalLinkRow(label: "\(e.label): \(e.address)", url: url) }
                        }
                    }
                }
                if let places = guide.places, !places.isEmpty {
                    FieldCard(eyebrow: "On the map") {
                        ForEach(places, id: \.self) { pid in
                            if let t = c.trail(pid) {
                                Button { router.push(.trail(t.id), in: .trails) } label: { Label(t.name, systemImage: "figure.hiking") }.font(.fieldBody)
                            } else if let p = c.place(pid) {
                                Button { router.showOnMap(.place(p.id)) } label: { Label(p.name, systemImage: "mappin") }.font(.fieldBody)
                            }
                        }
                    }
                }
                if let links = guide.links, !links.isEmpty {
                    FieldCard(eyebrow: "Related") {
                        ForEach(links, id: \.label) { link in
                            if let view = link.view, let section = AppSection(rawValue: view) {
                                Button { router.show(section) } label: { Label(link.label, systemImage: section.symbol) }.font(.fieldBody)
                            } else if let rid = link.regionId {
                                Button { router.push(.region(rid), in: .park) } label: { Label(link.label, systemImage: "mountain.2") }.font(.fieldBody)
                            } else if let u = link.url, let url = URL(string: u) {
                                ExternalLinkRow(label: link.label, url: url)
                            }
                            if let note = link.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
                FieldCard(eyebrow: "Sources") { SourceList(sources: guide.sources, checked: guide.checked) }
            }
            .fieldNavigationTitle(guide.title)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            EmptyStateView(symbol: "checkmark.seal", title: "Guide not found", message: "This link points to a permit guide that is not in the app.")
        }
    }
}
