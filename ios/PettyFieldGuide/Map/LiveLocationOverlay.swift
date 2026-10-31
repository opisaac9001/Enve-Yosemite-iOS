import SwiftUI
import UIKit

/// Wording for the live-position banner. Pure, so state-to-text rules are testable.
enum LiveLocationSummary {
    enum Kind: Equatable { case off, waiting, searching, live, weak, stale, denied, restricted, failed }

    static let weakAccuracy: Double = 100

    static func kind(_ state: LiveLocationState, now: Date) -> Kind {
        switch state.phase {
        case .off: .off
        case .awaitingPermission: .waiting
        case .denied: .denied
        case .restricted: .restricted
        case .failed: .failed
        case .searching: .searching
        case .tracking:
            if state.isStale(at: now) { .stale }
            else if let fix = state.lastFix, fix.horizontalAccuracy > weakAccuracy { .weak }
            else { .live }
        }
    }

    static func text(_ state: LiveLocationState, now: Date, onMap: Bool) -> String {
        var text: String
        switch state.phase {
        case .off: return "Live GPS is off."
        case .awaitingPermission: return "Waiting for location permission…"
        case .denied: return "Location access is off for Enve Yosemite. Turn it on in Settings to see your position."
        case .restricted: return "Location is restricted on this device, so the map cannot show your position."
        case .failed(let message): return "Location unavailable: \(message)"
        case .searching: text = "Live GPS on · waiting for a first fix. Open sky helps; cliffs and tree cover can block it."
        case .tracking:
            guard let fix = state.lastFix else { return "Live GPS on." }
            let accuracy = "±\(Int(fix.horizontalAccuracy.rounded())) m"
            let age = self.age(now.timeIntervalSince(fix.timestamp))
            switch kind(state, now: now) {
            case .stale: text = "No new fix for \(age) (last \(accuracy)). You may have moved since."
            case .weak: text = "Weak fix · \(accuracy) iOS estimate · \(age) ago"
            default: text = "Live GPS · \(accuracy) iOS estimate · \(age) ago"
            }
            if !onMap { text += " · Outside this map's area" }
        }
        if state.reducedAccuracy { text += " Precise Location is off, so iOS reports only an approximate area." }
        return text
    }

    static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h"
    }
}

/// Map control behaviour shared by the Map tab and the region, fire and hike maps: start, centre/follow, stop.
enum LiveLocationControl {
    static func symbol(isOn: Bool, following: Bool) -> String {
        isOn && following ? "location.fill" : "location"
    }

    static func label(isOn: Bool, following: Bool) -> String {
        if !isOn { return "Start live GPS position" }
        return following ? "Stop live GPS position" : "Centre on my position"
    }

    @MainActor
    static func activate(model: MapViewModel, tracker: LiveLocationTracker, followScale: CGFloat) {
        let state = tracker.state
        guard state.isOn else {
            tracker.start()
            model.followsUser = true
            return
        }
        if model.followsUser {
            tracker.stop()
        } else {
            model.followsUser = true
            model.centerOnUser(minScale: followScale)
        }
    }
}

/// Registers the map as a tracking host while visible and mirrors the tracker into the map's frame.
private struct LiveLocationHost: ViewModifier {
    typealias Content = _ViewModifier_Content<LiveLocationHost>

    @ObservedObject var model: MapViewModel
    let followScale: CGFloat
    @ObservedObject private var tracker = LiveLocationTracker.shared

    func body(content: Content) -> some View {
        content
            .onAppear { tracker.hostAppeared(); sync() }
            .onDisappear { tracker.hostDisappeared(); model.followsUser = false }
            .onChange(of: tracker.state.lastFix) { old, _ in sync(recenter: model.followsUser, zoom: old == nil) }
            .onChange(of: tracker.clock) { _, _ in sync() }
            .onChange(of: tracker.state.isOn) { _, on in if !on { model.followsUser = false } }
            .onChange(of: model.scene != nil) { _, _ in sync(recenter: model.followsUser, zoom: true) }
    }

    private func sync(recenter: Bool = false, zoom: Bool = false) {
        let state = tracker.state
        model.userFix = state.lastFix.map { MapUserFix(fix: $0, stale: state.isStale(at: tracker.clock)) }
        if recenter { model.centerOnUser(minScale: zoom ? followScale : nil) }
    }
}

extension View {
    func liveLocationHost(model: MapViewModel, followScale: CGFloat) -> some View {
        modifier(LiveLocationHost(model: model, followScale: followScale))
    }
}

struct LiveLocationBanner: View {
    @ObservedObject var model: MapViewModel
    /// Limits of the map underneath, shown while tracking.
    let note: String
    @ObservedObject private var tracker = LiveLocationTracker.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        let state = tracker.state
        let kind = LiveLocationSummary.kind(state, now: tracker.clock)
        if kind != .off {
            let onMap = state.lastFix.map { model.isOnMap($0.coordinate) } ?? true
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol(kind))
                    .foregroundStyle(kind == .live ? Palette.river : kind == .denied || kind == .restricted || kind == .failed ? Palette.ember : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LiveLocationSummary.text(state, now: tracker.clock, onMap: onMap))
                        .font(.fieldCaption)
                        .fixedSize(horizontal: false, vertical: true)
                    if let routeText = routeText(state) {
                        Text("Selected route · \(routeText)")
                            .font(.fieldCaption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if state.isOn {
                        Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                actions(kind)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Live GPS")
            .onChange(of: kind) { old, new in announce(from: old, to: new, state: state, onMap: onMap) }
        }
    }

    /// The highlighted hike on this map, compared with the latest fix.
    private func routeText(_ state: LiveLocationState) -> String? {
        guard state.phase == .tracking, let fix = state.lastFix, let scene = model.scene,
              let id = model.frameOptions.highlightedRouteId, let trace = scene.hikeRoutes[id] else { return nil }
        return RouteProximity.evaluate(fix: scene.projection.project(fix.coordinate), accuracy: fix.horizontalAccuracy,
                                       stale: state.isStale(at: tracker.clock), reducedAccuracy: state.reducedAccuracy, line: trace.points)
            .text(kind: trace.kind)
    }

    @ViewBuilder private func actions(_ kind: LiveLocationSummary.Kind) -> some View {
        VStack(spacing: 4) {
            switch kind {
            case .denied:
                Button("Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                    .buttonStyle(.borderedProminent)
                Button("Close") { tracker.stop() }
            case .restricted:
                Button("Close") { tracker.stop() }
            case .failed:
                Button("Retry") { tracker.start(); model.followsUser = true }
                    .buttonStyle(.borderedProminent)
                Button("Close") { tracker.stop() }
            default:
                Button("Stop") { tracker.stop() }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Stop live GPS")
            }
        }
        .font(.fieldCaption.weight(.semibold))
        .controlSize(.small)
    }

    private func symbol(_ kind: LiveLocationSummary.Kind) -> String {
        switch kind {
        case .live: "location.fill"
        case .weak, .stale: "location.slash"
        case .denied, .restricted, .failed: "exclamationmark.triangle.fill"
        default: "location"
        }
    }

    /// Speaks phase changes, but not every flip between a good and a weak fix.
    private func announce(from old: LiveLocationSummary.Kind, to kind: LiveLocationSummary.Kind, state: LiveLocationState, onMap: Bool) {
        let fixed: Set<LiveLocationSummary.Kind> = [.live, .weak]
        guard kind != .off, !(fixed.contains(old) && fixed.contains(kind)) else { return }
        AccessibilityNotification.Announcement(LiveLocationSummary.text(state, now: tracker.clock, onMap: onMap)).post()
    }
}
