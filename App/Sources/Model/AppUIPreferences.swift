// UI-only preferences the app keeps itself (everything else is owned by `AppServices`): whether
// onboarding was completed, light/dark appearance, whether the sensor is still waiting for a
// calibration (review minor 4, kept across relaunches with the Now state), and the Trends period
// (restored after the app is killed and relaunched; a cold launch always opens Now, review m6). UserDefaults of the app's
// own container; injectable for tests.

import Foundation

@MainActor
final class AppUIPreferences {
    private let defaults: UserDefaults

    private enum Key {
        static let onboardingCompleted = "ui.onboardingCompleted"
        static let appearance = "ui.appearance"
        static let sensorNeedsCalibration = "ui.sensorNeedsCalibration"
        static let trendsPeriodDays = "ui.trendsPeriodDays"
        static let connectionModeChosen = "ui.connectionModeChosen"
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

    /// D45: the person has chosen how the app connects (listen or pair). Until then no screen
    /// presents pairing as the default (the facade's stored `.pair` is only a storage default) and
    /// no pairing-code field is shown.
    var connectionModeChosen: Bool {
        get { defaults.bool(forKey: Key.connectionModeChosen) }
        set { defaults.set(newValue, forKey: Key.connectionModeChosen) }
    }

    /// The Trends period last selected; nil if never stored (14 D).
    var trendsPeriod: TrendsPeriod? {
        get { defaults.object(forKey: Key.trendsPeriodDays).flatMap { ($0 as? Int).flatMap(TrendsPeriod.init(rawValue:)) } }
        set { defaults.set(newValue?.rawValue, forKey: Key.trendsPeriodDays) }
    }
}
