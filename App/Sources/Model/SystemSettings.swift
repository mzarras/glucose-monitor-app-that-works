// Opens this app's page in iOS Settings (notification and Bluetooth permissions). iOS offers no
// supported deep link to the Bluetooth switch itself.

import UIKit

@MainActor
enum SystemSettings {
    static func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    static func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
