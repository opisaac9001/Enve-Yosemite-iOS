import SwiftUI

struct UpdatesSheet: View {
    enum Tab: String, CaseIterable, Identifiable { case updates, changelog, suggestions; var id: String { rawValue } }
    @State var initialTab: Tab
    @State private var tab: Tab = .updates
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var saved: SavedStore
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var updates = UpdatesStore.shared
    @ObservedObject private var push = PushRegistration.shared
    @ObservedObject private var server = ServerConfig.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var submitting = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Tab", selection: $tab) {
                    Text("Updates").tag(Tab.updates)
                    Text("Changelog").tag(Tab.changelog)
                    Text("Suggestions").tag(Tab.suggestions)
                }
                .pickerStyle(.segmented).padding()
                switch tab {
                case .updates: updatesTab
                case .changelog: changelogTab
                case .suggestions: suggestionsTab
                }
            }
            .navigationTitle("Updates & feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { tab = initialTab; Task { await updates.check() } }
        }
    }

    // MARK: Updates

    private var updatesTab: some View {
        Form {
            if let c = content.content {
                Section("Tracked topics") {
                    ForEach(c.status.updateTopics) { topic in
                        let pref = updates.preferences(saved: saved.state, topics: c.status.updateTopics)[topic.id] ?? TopicPreference(track: false, push: false)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Toggle(isOn: Binding(get: { pref.track }, set: { on in setPref(topic.id, track: on, push: pref.push && on) })) {
                                    HStack {
                                        Text(topic.label).font(.fieldBody)
                                        if updates.unread.contains(topic.id) { Circle().fill(Palette.accent).frame(width: 8, height: 8) }
                                    }
                                }
                            }
                            Toggle("Push", isOn: Binding(get: { pref.push }, set: { on in setPref(topic.id, track: pref.track || on, push: on) })).font(.fieldCaption).disabled(!pref.track)
                            Text(topic.cadence).font(.caption2).foregroundStyle(.secondary)
                            if let ch = updates.feed?.channels[topic.id] { Text("Revision \(ch.revision.prefix(8))… changed \(ch.changedAt.map(DateText.long) ?? "–")").font(.caption2).foregroundStyle(.tertiary) }
                            Button("Open") { dismiss(); if let s = AppSection(rawValue: topic.view) { router.show(s) } }.font(.caption2)
                        }
                    }
                }
                Section("Check") {
                    HStack {
                        Button(updates.checking ? "Checking…" : "Check now") { Task { await updates.check() } }.disabled(updates.checking || !server.isConfigured)
                        Spacer()
                        Button("Mark all read") { updates.markRead() }.disabled(updates.unread.isEmpty)
                    }
                    Text(updates.lastCheck.map { "Last check \(DateText.short($0)). Also checked every 15 minutes while open and when returning." } ?? "Not checked yet.").font(.caption2).foregroundStyle(.secondary)
                    if let m = updates.message { Text(m).font(.caption2).foregroundStyle(Palette.ember) }
                }
                Section("Push notifications · APNs") {
                    Text(pushStatusText).font(.fieldCaption)
                    if case .registered = push.status {
                        Button("Turn push off", role: .destructive) { Task { await push.disable() } }
                    } else {
                        Button("Enable push for selected topics") { Task { await push.enable(preferences: updates.preferences(saved: saved.state, topics: c.status.updateTopics)) } }
                            .disabled(!(updates.feed?.pushReady ?? false))
                    }
                    if let m = push.message { Text(m).font(.caption2).foregroundStyle(.secondary) }
                    Text("Delivery requires the operator to configure APNs credentials on the companion server and signing for this app. Until then the server reports push as not ready and in-app tracking is the only channel.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var pushStatusText: String {
        if !server.isConfigured { return "Unavailable: no companion server configured." }
        if updates.feed?.pushReady == false { return "Unavailable: the server is not configured for push (pushReady is false)." }
        switch push.status {
        case .idle: return "Off. Choose topics with Push enabled, then turn it on."
        case .requesting: return "Requesting permission…"
        case .registered(let token): return "Registered with Apple (token \(token.prefix(8))…)\(push.serverAccepted ? ", accepted by the server." : ", waiting for the server.")"
        case .failed(let e): return "Failed: \(e)"
        case .denied: return "Notification permission denied in Settings."
        }
    }

    private func setPref(_ id: String, track: Bool, push on: Bool) {
        saved.update { $0.trackedTopics[id] = TopicPreference(track: track, push: on) }
        if let c = content.content { Task { await push.updatePreferences(updates.preferences(saved: saved.state, topics: c.status.updateTopics)) } }
    }

    // MARK: Changelog

    private var changelogTab: some View {
        List {
            if let c = content.content {
                ForEach(c.changelog) { entry in
                    Section {
                        ForEach(Array(entry.items.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .top, spacing: 6) {
                                    Text(item.kind).font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2).background(Palette.accent.opacity(0.2), in: Capsule())
                                    Text(item.text).font(.fieldCaption)
                                }
                                if let href = item.href, let label = item.linkLabel {
                                    Button(label) { dismiss(); open(href: href) }.font(.caption2)
                                }
                            }
                        }
                        if let action = entry.actionRequired { Text("Action required: \(action)").font(.caption2).foregroundStyle(Palette.ember) }
                    } header: {
                        VStack(alignment: .leading) {
                            Text(entry.title)
                            Text("\(DateText.long(entry.date)) · release \(entry.releaseId)").font(.caption2)
                        }
                    }
                }
            }
        }
        .onAppear { if let first = content.content?.changelog.first { saved.update { $0.changelogSeenId = first.id } } }
    }

    /// Changelog links use the reference's query form (`?view=…&entry=…`); map them to routes.
    private func open(href: String) {
        guard let comps = URLComponents(string: href.hasPrefix("?") ? "x://x/\(href)" : href) else { return }
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).compactMap { q in q.value.map { (q.name, $0) } })
        if items["notifications"] == "updates" { router.sheet = .updates; return }
        if items["notifications"] == "suggestions" { router.sheet = .suggestions; return }
        guard let view = items["view"], let section = AppSection(rawValue: view) else { return }
        if let entry = items["entry"] {
            if entry.hasPrefix("event-") { router.push(.event(String(entry.dropFirst(6))), in: .events); return }
            if entry.hasPrefix("document-") { router.push(.document(String(entry.dropFirst(9))), in: .documents); return }
            if entry.hasPrefix("cg-") { router.push(.campground(entry), in: .trails); return }
            if entry.hasPrefix("trail-") { router.push(.trail(entry), in: .trails); return }
            if entry.hasPrefix("webcam-") { router.push(.webcam(String(entry.dropFirst(7))), in: .status); return }
        }
        if let place = items["place"] { router.showOnMap(.place(place)); return }
        if let region = items["region"] { router.push(.region(region), in: .park); return }
        router.show(section)
    }

    // MARK: Suggestions

    private var suggestionsTab: some View {
        Form {
            Section("Send a suggestion") {
                TextField("Name (optional, remembered)", text: $updates.draft.name)
                TextField("Title (optional)", text: $updates.draft.title)
                TextField("What should change? (250 characters)", text: $updates.draft.text, axis: .vertical).lineLimit(3...8)
                Text("\(updates.draft.text.count)/250").font(.caption2).foregroundStyle(updates.draft.text.count > 250 ? Palette.ember : .secondary)
                Toggle("Include layout details", isOn: $updates.draft.includeLayout)
                if updates.draft.includeLayout {
                    let l = layoutMetadata()
                    Text("Will send: section \(l.section), \(l.orientation), \(l.sizeClass) width, text \(l.textSize), \(l.appearance), app \(l.appVersion). No location or device identifier.").font(.caption2).foregroundStyle(.secondary)
                }
                Button(submitting ? "Sending…" : "Submit") { Task { submitting = true; _ = await updates.submit(layout: updates.draft.includeLayout ? layoutMetadata() : nil); submitting = false } }
                    .disabled(submitting || !server.isConfigured || updates.draft.text.trimmingCharacters(in: .whitespaces).isEmpty)
                if !server.isConfigured { Text("Needs the companion server. Your draft stays saved on this device.").font(.caption2).foregroundStyle(.secondary) }
                if let m = updates.message { Text(m).font(.caption2) }
            }
            Section("Your submissions · \(updates.submissions.count)") {
                if updates.submissions.isEmpty { Text("None yet.").font(.fieldCaption).foregroundStyle(.secondary) }
                ForEach(updates.submissions) { s in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(s.title.isEmpty ? "Untitled" : s.title).font(.fieldBody.weight(.semibold)); Spacer(); Text(s.status).font(.caption2).foregroundStyle(Palette.accent) }
                        Text(s.text).font(.fieldCaption)
                        if let r = s.reply { Text("Reply: \(r)").font(.fieldCaption).foregroundStyle(Palette.meadow) }
                        Text("Sent \(DateText.long(s.createdAt)) · updated \(DateText.long(s.updatedAt))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Check for replies") { Task { await updates.pollReceipts() } }.disabled(!server.isConfigured)
                    Spacer()
                    Button("Mark read") { updates.markRepliesRead() }.disabled(updates.unreadReplies == 0)
                }
                .font(.fieldCaption)
            }
        }
    }

    private func layoutMetadata() -> ConditionsClient.LayoutMetadata {
        ConditionsClient.LayoutMetadata(section: router.section.rawValue,
                                        orientation: verticalSizeClass == .compact ? "landscape" : "portrait",
                                        sizeClass: sizeClass == .regular ? "regular" : "compact",
                                        textSize: theme.textSize.rawValue, appearance: theme.appearance.rawValue,
                                        appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    }
}
