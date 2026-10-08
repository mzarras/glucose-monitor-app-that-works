// Predictions in the live services (PROGRESS D57; docs/forecast.md). The host and the switch are
// saved in `AppPreferences`; the forecast itself is held by `ForecastService` in memory only and is
// read only by the Predict tab and Settings › Predictions. Nothing here touches the reading
// pipeline, the store, alerts, Trio, uploads or the widget.

import ForecastKit
import Foundation

extension LiveAppServices {
    var forecast: ForecastStatus { forecastService.status }

    func setPredictionsEnabled(_ enabled: Bool) async {
        guard isBootstrapped else { return } // preferences are unreadable before the first unlock
        preferences.forecastEnabled = enabled
        applyForecastSettings()
    }

    func savePredictionsHost(_ input: String) async throws(ForecastHostRefusal) {
        let endpoint: ForecastFeedEndpoint
        do throws(ForecastEndpointError) {
            endpoint = try ForecastFeedEndpoint(input)
        } catch {
            throw ForecastHostRefusal(message: error.description)
        }
        // Before the first unlock after a restart the preferences can't be written: say so rather
        // than "Saved.".
        guard isBootstrapped else { throw ForecastHostRefusal(message: Self.notSavedBeforeUnlock) }
        preferences.forecastFeedHost = endpoint.host
        applyForecastSettings()
    }

    static let notSavedBeforeUnlock = "Not saved: unlock the phone once since it restarted, then save again."

    func predictTabAppeared() {
        forecastService.predictTabAppeared()
    }

    /// What Settings › Predictions saved → the forecast service (bootstrap and every change). Fetches
    /// start only if the app is in the foreground (`ForecastService.enterForeground()`).
    func applyForecastSettings() {
        forecastService.configure(savedHost: preferences.forecastFeedHost, savedEnabled: preferences.forecastEnabled)
    }
}
