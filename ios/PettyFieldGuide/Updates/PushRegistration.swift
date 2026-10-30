import Foundation
import Combine
import UIKit
import UserNotifications

/// Native APNs registration. The device token goes to the companion server, which can only
/// deliver pushes once APNs credentials are configured there; until then it reports `pushReady: false`.
@MainActor
final class PushRegistration: ObservableObject {
    static let shared = PushRegistration()

    enum Status: Equatable {
        case idle
        case requesting
        case registered(token: String)
        case failed(String)
        case denied
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var serverAccepted = false
    @Published private(set) var message: String?

    private var pendingPreferences: [String: TopicPreference] = [:]

    func enable(preferences: [String: TopicPreference]) async {
        pendingPreferences = preferences
        status = .requesting
        message = nil
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else { status = .denied; message = "Notification permission was not granted. You can change it in Settings."; return }
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func disable() async {
        if case .registered(let token) = status {
            try? await ConditionsClient.shared.unregisterPush(token: token)
        }
        UIApplication.shared.unregisterForRemoteNotifications()
        status = .idle
        serverAccepted = false
        message = "Push is off. In-app tracking still works."
    }

    func didReceive(deviceToken: String) {
        status = .registered(token: deviceToken)
        Task { await sendToServer(token: deviceToken) }
    }

    func didFail(error: Error) {
        status = .failed(error.localizedDescription)
        message = "The device could not register with Apple Push: \(error.localizedDescription)"
    }

    func updatePreferences(_ preferences: [String: TopicPreference]) async {
        pendingPreferences = preferences
        if case .registered(let token) = status { await sendToServer(token: token) }
    }

    private func sendToServer(token: String) async {
        do {
            let accepted = try await ConditionsClient.shared.registerPush(token: token, preferences: pendingPreferences)
            serverAccepted = accepted
            message = accepted ? "Push enabled for your selected topics." : "The server received the token but push delivery is not configured on it yet. In-app tracking still works."
        } catch {
            serverAccepted = false
            message = "The token could not be sent to the server: \(error.localizedDescription)"
        }
    }
}
