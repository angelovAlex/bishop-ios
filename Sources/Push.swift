//
//  Push.swift
//  Remote push for the Bishop app: ask for permission, register with APNs, and
//  hand the device token to the Mac (POST /api/push_token) so tools.apns_push()
//  can reach this phone.
//
//  A development-signed build gets a SANDBOX token. The Mac sends to
//  api.sandbox.push.apple.com for that reason - a production token would need a
//  token from a distribution-signed build and the prod host.
//

import SwiftUI
import UserNotifications

final class PushNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    /// One instance for the whole app: the AppDelegate callbacks are not tied to
    /// a view, so they need a way to reach it.
    static let shared = PushNotifier()
    @Published var status = "not asked"
    weak var api: BishopAPI?

    /// Ask once, then register. Called from the app's launch task; safe to call
    /// again - registration is idempotent and the token is re-posted on every
    /// launch, because it can change and the Mac only keeps the latest one.
    func start(api: BishopAPI) {
        self.api = api
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            DispatchQueue.main.async {
                if let error {
                    self.status = "denied: \(error.localizedDescription)"
                    return
                }
                self.status = granted ? "allowed" : "denied"
                guard granted else { return }
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// APNs handed us a token: forward it as hex to the Mac.
    func got(token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        status = "registered \(hex.prefix(8))…"
        Task { @MainActor in
            guard let api else { return }
            _ = try? await api.post("/api/push_token", ["token": hex])
        }
    }

    func failed(_ error: Error) {
        status = "APNs: \(error.localizedDescription)"
    }

    /// Show the banner even while the app is open, so a push is never silent.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               willPresent notification: UNNotification,
                               withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }
}
