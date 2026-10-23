//
//  BishopApp.swift
//  Bishop on the phone: the same chat as the web page, talking to webui.py on
//  the Mac. The voice mic uses the native keyboard's dictation, so there is no
//  speech framework here on purpose.
//

import SwiftUI
import UserNotifications

@main
struct BishopApp: App {
    // APNs answers through the UIApplicationDelegate callbacks, so the app needs
    // one even though it is SwiftUI: the delegate hands the device token to
    // PushNotifier (see Push.swift).
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { ChatView() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ app: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        PushNotifier.shared.got(token: token)
    }

    func application(_ app: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushNotifier.shared.failed(error)
    }
}
