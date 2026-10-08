// The Predict tab and Settings › Predictions in the app model (PROGRESS D57). The forecast is read
// from the facade (`AppServices.forecast`, in memory only) and mapped on the UI clock; nothing here
// writes a forecast anywhere.

import ForecastKit
import Foundation

extension AppModel {
    /// Rebuilds the Predict tab at `forecastClock.read()` (the UI clock): after each `.forecast` change,
    /// readings reload and clock tick. A run older than 15 minutes is shown as "out of date" from the
    /// first tick after it ages out, whether or not any fetch happened (S1, D57).
    func refreshPredict() {
        guard let services else { return }
        let next = PredictMapping.make(status: services.forecast, readings: predictReadings, at: forecastClock.read())
        if next != predict { predict = next }
    }

    /// The Predict tab appeared: the facade fetches at once if its last attempt is > 30 s old.
    func predictTabAppeared() {
        services?.predictTabAppeared()
    }

    /// "Set up in Settings" on the Predict tab.
    func openPredictionsSettings() {
        openSettings(.predictions)
    }

    func setPredictionsEnabled(_ enabled: Bool) {
        guard let services else {
            if let host = settings.predictions.setup.host {
                settings.predictions.setup = enabled ? .on(host: host) : .off(host: host)
            }
            return
        }
        track { await services.setPredictionsEnabled(enabled) }
    }

    /// Validates (ForecastFeedEndpoint) and saves the feed host; the reason it was refused, or
    /// "Saved.", goes under the field.
    func savePredictionsHost(_ input: String) {
        settings.feedback.predictions = nil
        guard let services else {
            do throws(ForecastEndpointError) {
                let endpoint = try ForecastFeedEndpoint(input)
                settings.predictions.setup = .on(host: endpoint.host)
                settings.feedback.predictions = Self.predictionsSaved
            } catch {
                settings.feedback.predictions = error.description
            }
            return
        }
        track { [weak self] in
            do throws(ForecastHostRefusal) {
                try await services.savePredictionsHost(input)
                self?.settings.feedback.predictions = Self.predictionsSaved
            } catch {
                self?.settings.feedback.predictions = error.message
            }
        }
    }

    static let predictionsSaved = "Saved."
}
