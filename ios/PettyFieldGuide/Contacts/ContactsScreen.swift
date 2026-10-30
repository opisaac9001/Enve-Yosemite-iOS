import SwiftUI

struct ContactsScreen: View {
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var router: AppRouter
    @State private var query = ""
    @Environment(\.bottomBarInset) private var inset

    var body: some View {
        if let c = content.content {
            List {
                Section {
                    EmergencyCard(shortcuts: c.contacts.emergency)
                        .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                }
                ForEach(c.contacts.groups) { group in
                    let items = filtered(c.contacts.contacts.filter { $0.group == group.id })
                    if !items.isEmpty {
                        Section(group.label) {
                            ForEach(items) { contact in
                                NavigationLink(value: Route.contact(contact.id)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(contact.name).font(.fieldBody.weight(.semibold))
                                        Text(contact.numbers.map(\.number).joined(separator: " · ")).font(.fieldCaption).foregroundStyle(Palette.accent)
                                        Text(contact.reaches).font(.fieldCaption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                }
                Color.clear.frame(height: inset).listRowBackground(Color.clear)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .searchable(text: $query, prompt: "Name, number or service")
            .fieldNavigationTitle("Contacts")
        }
    }

    private func filtered(_ contacts: [Contact]) -> [Contact] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return contacts }
        let digits = q.filter(\.isNumber)
        let n = SearchIndex.normalise(q)
        return contacts.filter { c in
            SearchIndex.normalise(c.name + " " + c.reaches + " " + c.hours.joined(separator: " ") + " " + c.location.joined(separator: " ")).contains(n)
                || (digits.count >= 3 && c.numbers.contains { PhoneFormat.digits($0.number).contains(digits) })
        }
    }
}

struct EmergencyCard: View {
    let shortcuts: EmergencyShortcuts
    var body: some View {
        FieldCard(eyebrow: "Emergency · separate from the directory") {
            if let url = URL(string: "tel:911") {
                Link(destination: url) { Label(shortcuts.emergency, systemImage: "sos").font(.fieldHeading).foregroundStyle(Palette.ember) }
            }
            shortcut(shortcuts.conditions, symbol: "road.lanes")
            shortcut(shortcuts.switchboard, symbol: "phone")
            shortcut(shortcuts.roadside, symbol: "car")
            HStack(alignment: .top) {
                Image(systemName: "bus").frame(width: 20)
                VStack(alignment: .leading) { Text(shortcuts.shuttle.label).font(.fieldBody); Text(shortcuts.shuttle.detail ?? "").font(.fieldCaption).foregroundStyle(.secondary) }
            }
            HStack(alignment: .top) {
                Image(systemName: "fuelpump").frame(width: 20)
                VStack(alignment: .leading) {
                    Text(shortcuts.fuel.label).font(.fieldBody)
                    Text(shortcuts.fuel.detail ?? "").font(.fieldCaption).foregroundStyle(.secondary)
                    if let u = shortcuts.fuel.url, let url = URL(string: u) { Link("Crane Flat station", destination: url).font(.fieldCaption) }
                }
            }
            Text("Shortcut numbers were checked on the dates shown in each contact's sources. Texting is only assumed where a source documents it.").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private func shortcut(_ s: EmergencyShortcut, symbol: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: symbol).frame(width: 20)
            VStack(alignment: .leading) {
                Text(s.label).font(.fieldBody)
                if let n = s.number, let url = PhoneFormat.telURL(n) { Link(n, destination: url).font(.fieldCaption.weight(.semibold)) }
                if let c = s.checked { Text("checked \(DateText.long(c))").font(.caption2).foregroundStyle(.tertiary) }
            }
        }
    }
}

struct ContactDetailView: View {
    let contactId: String
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        if let c = content.content, let contact = c.contact(contactId) {
            FieldScroll {
                FieldCard {
                    Text(c.contacts.groups.first { $0.id == contact.group }?.label ?? contact.group).font(.fieldEyebrow).foregroundStyle(.secondary)
                    Text(contact.reaches).font(.fieldBody)
                }
                FieldCard(eyebrow: "Numbers") {
                    ForEach(contact.numbers, id: \.number) { n in
                        PhoneRow(phone: PhoneNumber(label: n.label, number: n.number, note: n.note, hours: n.hours))
                    }
                    if let email = contact.email, let url = URL(string: "mailto:\(email)") { ExternalLinkRow(label: email, url: url) }
                    Text("Texting: \(contact.texting.note)").font(.caption2).foregroundStyle(.secondary)
                }
                if !contact.hours.isEmpty {
                    FieldCard(eyebrow: "Hours") { ForEach(contact.hours, id: \.self) { Text($0).font(.fieldBody) } }
                }
                if !contact.location.isEmpty {
                    FieldCard(eyebrow: "Location") {
                        ForEach(contact.location, id: \.self) { Text($0).font(.fieldBody) }
                        if let pid = contact.placeId, c.place(pid) != nil {
                            Button { router.showOnMap(.place(pid)) } label: { Label("Show on map", systemImage: "map") }.buttonStyle(.bordered).font(.fieldCaption)
                        }
                    }
                }
                FieldCard(eyebrow: "Sources") { SourceList(sources: contact.sources, checked: contact.checked) }
            }
            .fieldNavigationTitle(contact.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            EmptyStateView(symbol: "phone", title: "Contact not found", message: "This link points to a contact that is not in the guide.")
        }
    }
}
