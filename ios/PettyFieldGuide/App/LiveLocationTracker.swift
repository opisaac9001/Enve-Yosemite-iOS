import Foundation
import Combine
import CoreLocation
import UIKit

struct LiveFix: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    /// Radius in metres that iOS reports for this fix; not an independent measurement.
    let horizontalAccuracy: Double
    let timestamp: Date

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    init(latitude: Double, longitude: Double, horizontalAccuracy: Double, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
    }

    init(_ location: CLLocation) {
        self.init(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                  horizontalAccuracy: location.horizontalAccuracy, timestamp: location.timestamp)
    }
}

/// Session state for live, foreground-only position tracking. Pure, so every transition is testable
/// without CoreLocation. Nothing here is persisted.
struct LiveLocationState: Equatable {
    enum Phase: Equatable { case off, awaitingPermission, searching, tracking, denied, restricted, failed(String) }

    enum Authorization: Equatable { case notDetermined, denied, restricted, authorized }

    /// A fix older than this is shown as a last-known position, never as where you are.
    static let staleAfter: TimeInterval = 30

    private(set) var phase: Phase = .off
    private(set) var lastFix: LiveFix?
    var reducedAccuracy = false
    /// Visible maps that show the overlay; updates only run while at least one is on screen.
    private(set) var hosts = 0
    var inForeground = true

    var isOn: Bool { phase == .searching || phase == .tracking }
    var shouldRunUpdates: Bool { isOn && hosts > 0 && inForeground }

    /// Returns true when the system permission prompt should be shown.
    mutating func start(authorization: Authorization) -> Bool {
        lastFix = nil
        switch authorization {
        case .notDetermined: phase = .awaitingPermission; return true
        case .denied: phase = .denied
        case .restricted: phase = .restricted
        case .authorized: phase = .searching
        }
        return false
    }

    mutating func stop() {
        phase = .off
        lastFix = nil
    }

    mutating func authorizationChanged(_ authorization: Authorization) {
        switch (phase, authorization) {
        case (.awaitingPermission, .authorized): phase = .searching
        case (.awaitingPermission, .denied), (.searching, .denied), (.tracking, .denied):
            phase = .denied; lastFix = nil
        case (.awaitingPermission, .restricted), (.searching, .restricted), (.tracking, .restricted):
            phase = .restricted; lastFix = nil
        case (.searching, .notDetermined), (.tracking, .notDetermined):
            phase = .awaitingPermission; lastFix = nil
        default: break
        }
    }

    /// Invalid, out-of-order and cached fixes older than the stale limit are dropped.
    mutating func received(_ fix: LiveFix, now: Date) {
        guard isOn, fix.horizontalAccuracy >= 0, now.timeIntervalSince(fix.timestamp) <= Self.staleAfter else { return }
        if let lastFix, fix.timestamp < lastFix.timestamp { return }
        lastFix = fix
        phase = .tracking
    }

    mutating func failed(_ code: CLError.Code?, description: String) {
        guard isOn else { return }
        switch code {
        case .locationUnknown?: break
        case .denied?: phase = .denied; lastFix = nil
        default: phase = .failed(description); lastFix = nil
        }
    }

    mutating func hostAppeared() { hosts += 1 }
    mutating func hostDisappeared() { hosts = max(0, hosts - 1) }

    func isStale(at now: Date) -> Bool {
        guard let lastFix else { return false }
        return now.timeIntervalSince(lastFix.timestamp) > Self.staleAfter
    }
}

/// Continuous When-In-Use tracking for the map overlays, started only from an explicit control.
/// One manager serves every map so the session survives moving between them; updates pause whenever
/// no map is visible or the app leaves the foreground. Coordinates never leave memory.
@MainActor
final class LiveLocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LiveLocationTracker()

    @Published private(set) var state = LiveLocationState()
    /// Advances while updates run so stale fixes are re-evaluated without a new delivery.
    @Published private(set) var clock = Date()

    private let manager = CLLocationManager()
    private var updating = false
    private var clockTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // A distance filter would starve a stationary hiker of fresh fixes and wrongly mark them stale.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mutate { $0.inForeground = false } }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mutate { $0.inForeground = true } }
        })
    }

    func start() {
        var askPermission = false
        mutate { askPermission = $0.start(authorization: Self.authorization(manager.authorizationStatus)) }
        if askPermission { manager.requestWhenInUseAuthorization() }
    }

    func stop() { mutate { $0.stop() } }

    func hostAppeared() { mutate { $0.hostAppeared() } }
    func hostDisappeared() { mutate { $0.hostDisappeared() } }

    private func mutate(_ change: (inout LiveLocationState) -> Void) {
        var next = state
        change(&next)
        if next != state { state = next }
        sync()
    }

    private func sync() {
        let run = state.shouldRunUpdates
        guard run != updating else { return }
        updating = run
        if run {
            state.reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
            manager.startUpdatingLocation()
            clockTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.clock = Date()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        } else {
            manager.stopUpdatingLocation()
            clockTask?.cancel()
            clockTask = nil
        }
    }

    private static func authorization(_ status: CLAuthorizationStatus) -> LiveLocationState.Authorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        default: .authorized
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let reduced = manager.accuracyAuthorization == .reducedAccuracy
        Task { @MainActor in
            mutate {
                $0.authorizationChanged(Self.authorization(status))
                $0.reducedAccuracy = reduced
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        let fix = LiveFix(latest)
        Task { @MainActor in
            clock = Date()
            mutate { $0.received(fix, now: clock) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        let description = error.localizedDescription
        Task { @MainActor in mutate { $0.failed(code, description: description) } }
    }
}
