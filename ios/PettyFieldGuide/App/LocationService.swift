import Foundation
import Combine
import CoreLocation

/// One-shot location requests. Permission is only asked when the user invokes a location tool.
@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum PendingAction: Equatable { case centre, car, sortByDistance }

    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var message: String?
    var pendingAction: PendingAction?

    private let manager = CLLocationManager()
    private var messageTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func request(_ action: PendingAction) {
        pendingAction = action
        switch manager.authorizationStatus {
        case .notDetermined:
            show("Location is optional. Allow it once to use this tool.")
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            show("Location permission is off for this app. Enable it in Settings, or choose the spot on the map instead.")
            pendingAction = nil
        default:
            show("Locating…")
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if status == .authorizedWhenInUse || status == .authorizedAlways, pendingAction != nil {
                show("Locating…")
                self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let latest = locations.last
        Task { @MainActor in
            lastLocation = latest
            if let latest, latest.horizontalAccuracy > 150 {
                show("Position is approximate (±\(Int(latest.horizontalAccuracy)) m).")
            } else {
                message = nil
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            show("Location failed: \(error.localizedDescription). Try again with a clearer view of the sky.")
            pendingAction = nil
        }
    }

    private func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { message = nil }
        }
    }
}
