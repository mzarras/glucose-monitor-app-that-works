// UIKit launch hooks the SwiftUI lifecycle does not offer: creating the composition root during
// launch (CoreBluetooth state restoration needs the G7 central before launch finishes), whether iOS
// relaunched the app for Bluetooth (force-quit gap detection), and the notification center
// delegate, which must be set before launch finishes (docs/alerts.md §9).

import UIKit
import UserNotifications

final class SensorAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        _ = AppEnvironment.shared
        return true
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Present when iOS relaunched the app to handle a restored CoreBluetooth central's event.
        let bluetooth = launchOptions?[.bluetoothCentrals] != nil
        AppEnvironment.shared.didFinishLaunching(launchedByBluetoothRestoration: bluetooth)
        return true
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Acknowledge / Snooze / open / swipe on an alert notification → the alert engine.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let actionIdentifier = response.actionIdentifier
        let userInfo = Self.stringPairs(response.notification.request.content.userInfo)
        await AppEnvironment.shared.handleNotificationResponse(actionIdentifier: actionIdentifier, userInfo: userInfo)
    }

    /// Alerts are shown and heard while the app is open too (docs/alerts.md §9).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// AlertEngine puts only strings in `userInfo` (the alert kind and the snooze minutes).
    private nonisolated static func stringPairs(_ userInfo: [AnyHashable: Any]) -> [String: String] {
        var pairs: [String: String] = [:]
        for (key, value) in userInfo {
            if let key = key as? String, let value = value as? String { pairs[key] = value }
        }
        return pairs
    }
}
