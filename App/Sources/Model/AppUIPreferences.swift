// UI-only preferences the app keeps itself (everything else is owned by `AppServices`): whether
// onboarding was completed, light/dark appearance, and whether the sensor is still waiting for a
// calibration (review minor 4, kept across relaunches with the Now state). UserDefaults of the
// app's own container; injectable for tests.

import Foundation

@MainActor
final class AppUIPreferences {
    private let defaults: UserDefaults

    private enum Key {
        static let onboardingCompleted = "ui.onboardingCompleted"
        static let appearance = "ui.appearance"
        static let sensorNeedsCalibration = "ui.sensorNeedsCalibration"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: Key.onboardingCompleted) }
        set { defaults.set(newValue, forKey: Key.onboardingCompleted) }
    }

    var appearance: AppearancePreference {
        get { defaults.string(forKey: Key.appearance).flatMap(AppearancePreference.init(rawValue:)) ?? .default }
        set { defaults.set(newValue.rawValue, forKey: Key.appearance) }
    }

    var sensorNeedsCalibration: Bool {
        get { defaults.bool(forKey: Key.sensorNeedsCalibration) }
        set { defaults.set(newValue, forKey: Key.sensorNeedsCalibration) }
    }
}
