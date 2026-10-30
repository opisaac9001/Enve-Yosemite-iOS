import SwiftUI

struct EventFiltersSheet: View {
    let content: Content
    @ObservedObject private var state = EventsState.shared
    @EnvironmentObject private var saved: SavedStore
    @Environment(\.dismiss) private var dismiss
    @State private var includeDraft = ""
    @State private var excludeDraft = ""
    @State private var viewName = ""
    @State private var customName = ""
    @State private var customKeywords = ""
    @State private var showQR = false

    private var areas: [String] { Array(Set(content.events.events.map(\.area))).sorted() }
    private var categories: [String] { Array(Set(content.events.events.map(\.category))).sorted() }

    var body: some View {
        NavigationStack {
            Form {
                Section("Region") { toggles(areas, selection: $state.filter.regions) }
                Section("Category") { toggles(categories, selection: $state.filter.categories) }
                Section("Cost") { toggles(["free", "paid", "restricted", "unknown"], selection: $state.filter.costs) }
                Section("Sources") {
                    Toggle("Include saved NPS calendar listings", isOn: $state.filter.includeNPS)
                    Toggle("Show ended events", isOn: $state.filter.showEnded)
                }
                Section("Only titles containing") { phraseList($state.filter.includeTitles, draft: $includeDraft) }
                Section("Exclude titles containing") { phraseList($state.filter.excludeTitles, draft: $excludeDraft) }
                Section("Custom categories") {
                    ForEach(state.customCategories) { cat in
                        Toggle(isOn: Binding(get: { state.filter.customCategories.contains(cat.id) }, set: { on in
                            if on { state.filter.customCategories.append(cat.id) } else { state.filter.customCategories.removeAll { $0 == cat.id } }
                        })) {
                            VStack(alignment: .leading) { Text(cat.name); Text(cat.keywords.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { state.customCategories[$0].id }
                        state.customCategories.remove(atOffsets: offsets)
                        state.filter.customCategories.removeAll { ids.contains($0) }
                    }
                    TextField("Name", text: $customName)
                    TextField("Title keywords, comma separated", text: $customKeywords)
                    Button("Add custom category") {
                        let words = customKeywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        guard !customName.isEmpty, !words.isEmpty else { return }
                        state.customCategories.append(CustomEventCategory(id: UUID().uuidString, name: customName, keywords: words))
                        customName = ""; customKeywords = ""
                    }
                }
                Section("Saved views") {
                    ForEach(saved.state.eventViews) { view in
                        HStack {
                            Button { if let f = EventFilter.decode(view.encodedFilter) { state.filter = f } } label: {
                                VStack(alignment: .leading) { Text(view.name); if view.isDefault { Text("Default on launch").font(.caption2).foregroundStyle(.secondary) } }
                            }
                            Spacer()
                            Button { saved.update { s in for i in s.eventViews.indices { s.eventViews[i].isDefault = s.eventViews[i].id == view.id } } } label: { Image(systemName: view.isDefault ? "star.fill" : "star") }
                                .buttonStyle(.plain).accessibilityLabel("Make default")
                        }
                    }
                    .onDelete { offsets in saved.update { $0.eventViews.remove(atOffsets: offsets) } }
                    TextField("View name", text: $viewName)
                    Button("Save current filter as a view") {
                        guard !viewName.isEmpty, let enc = state.filter.encoded() else { return }
                        saved.update { $0.eventViews.append(SavedEventView(id: UUID().uuidString, name: viewName, encodedFilter: enc, isDefault: false, savedAt: .stamp)) }
                        viewName = ""
                    }
                }
                Section("Share this filter") {
                    if let enc = state.filter.encoded(), let url = AppRouter.eventFilterURL(encoded: enc) {
                        ShareLink(item: url, subject: Text("Event filter")) { Label("Share link", systemImage: "square.and.arrow.up") }
                        Button { showQR = true } label: { Label("Show QR code", systemImage: "qrcode") }
                        Text("Links carry only the filter, never private data.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Clear all filters", role: .destructive) { state.filter = EventFilter() }
                }
            }
            .navigationTitle("Event filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showQR) { QRSheet(title: "Event filter", url: state.filter.encoded().flatMap { AppRouter.eventFilterURL(encoded: $0) }) }
        }
    }

    private func toggles(_ options: [String], selection: Binding<[String]>) -> some View {
        ForEach(options, id: \.self) { option in
            Toggle(option, isOn: Binding(get: { selection.wrappedValue.contains(option) }, set: { on in
                if on { selection.wrappedValue.append(option) } else { selection.wrappedValue.removeAll { $0 == option } }
            }))
        }
    }

    private func phraseList(_ list: Binding<[String]>, draft: Binding<String>) -> some View {
        Group {
            ForEach(list.wrappedValue, id: \.self) { phrase in
                HStack { Text(phrase); Spacer(); Button { list.wrappedValue.removeAll { $0 == phrase } } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain) }
            }
            HStack {
                TextField("Exact title or phrase", text: draft)
                Button("Add") {
                    let t = draft.wrappedValue.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    list.wrappedValue.append(t); draft.wrappedValue = ""
                }
            }
        }
    }
}
