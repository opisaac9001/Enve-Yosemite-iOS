import SwiftUI

struct NoticeRow: View {
    let item: NoticeItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: symbol).foregroundStyle(color).font(.caption)
                Text(item.title).font(.fieldBody.weight(.semibold))
                Spacer()
                if let s = item.statusText { Text(s).font(.fieldCaption.weight(.semibold)).foregroundStyle(color) }
            }
            if !item.body.isEmpty { Text(item.body).font(.fieldCaption) }
            HStack(spacing: 6) {
                if let area = item.area { Text(area).font(.caption2).foregroundStyle(.secondary) }
                if let d = item.dated { Text("· \(DateText.long(d))").font(.caption2).foregroundStyle(.secondary) }
                if let u = item.url, let url = URL(string: u) { Link("source", destination: url).font(.caption2) }
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch item.kind {
        case "road": "road.lanes"
        case "roadwork": "cone.fill"
        case "trail": "figure.hiking"
        case "alert", nil: "exclamationmark.triangle.fill"
        case "wilderness": "tree.fill"
        default: "info.circle"
        }
    }

    private var color: Color {
        switch item.status {
        case "open": Palette.meadow
        case "closed": Palette.ember
        default: Palette.accent
        }
    }
}

/// Acquisition, retrieval and source timestamps plus state for a saved feed snapshot.
struct SnapshotFooter<T: Codable & Sendable>: View {
    let snapshot: Snapshot<T>?
    var staleAfter: TimeInterval = 60 * 60
    var sourceTime: String?

    var body: some View {
        HStack(spacing: 8) {
            if let snapshot {
                StatusPill(state: snapshot.freshness(staleAfter: staleAfter), text: label(snapshot))
            } else {
                StatusPill(state: .none, text: "No saved snapshot")
            }
        }
    }

    private func label(_ s: Snapshot<T>) -> String {
        var parts = ["data acquired \(DateText.relative(s.acquiredAt))"]
        if s.servedFromServerCache { parts.append("checked \(DateText.relative(s.retrievedAt))") }
        if let sourceTime { parts.append("source \(DateText.long(sourceTime))") }
        if s.isExpired { parts.append("expired · not current") } else if s.freshness(staleAfter: staleAfter) == .stale { parts.append("stale") }
        return parts.joined(separator: " · ")
    }
}

struct FeedStatusList: View {
    let statuses: [FeedStatus]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(statuses) { s in
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(Palette.stateColor(s.sourceState)).frame(width: 8, height: 8).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.label).font(.fieldCaption.weight(.semibold))
                        Text([s.state, s.detail, s.sourceTime.map { "source \(DateText.long($0))" }, "checked \(DateText.long(s.checkedAt))"].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary)
                        if let u = s.url, let url = URL(string: u) { Link("source", destination: url).font(.caption2) }
                    }
                }
            }
        }
    }
}

struct FeedHeader<T: Codable & Sendable>: View {
    let title: String
    let snapshot: Snapshot<T>?
    let refreshing: Bool
    let error: String?
    var staleAfter: TimeInterval = 60 * 60
    let refresh: () -> Void
    @ObservedObject private var server = ServerConfig.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.fieldHeading)
                Spacer()
                Button(action: refresh) { Label(refreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered).font(.fieldCaption).disabled(refreshing || !server.isConfigured)
            }
            SnapshotFooter(snapshot: snapshot, staleAfter: staleAfter)
            if !server.isConfigured {
                Text("Live refresh needs the companion server address (Trip prep › Conditions server). Saved snapshots stay available offline.").font(.caption2).foregroundStyle(.secondary)
            }
            if let error { Text("Last attempt failed: \(error)").font(.caption2).foregroundStyle(Palette.ember) }
        }
    }
}
