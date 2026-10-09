// DEBUG only: predictions in the in-memory `AppServices` (PROGRESS D57). Nothing is fetched; the
// forecast is whatever a test or preview sets in `forecast`.

#if DEBUG
import ForecastKit
import Foundation

extension PreviewAppServices {
    /// As the live service: off forgets what was held; on with a host starts empty.
    func setPredictionsEnabled(_ enabled: Bool) async {
        record("setPredictionsEnabled(\(enabled))")
        guard let host = forecast.setup.host else { return }
        forecast = ForecastStatus(setup: enabled ? .on(host: host) : .off(host: host), buildHost: forecast.buildHost)
        send(.forecast)
    }

    /// As the live service: validated with ForecastKit, the switch kept, everything held forgotten.
    func savePredictionsHost(_ input: String) async throws(ForecastHostRefusal) {
        record("savePredictionsHost(\(input))")
        let endpoint: ForecastFeedEndpoint
        do throws(ForecastEndpointError) {
            endpoint = try ForecastFeedEndpoint(input)
        } catch {
            throw ForecastHostRefusal(message: error.description)
        }
        let enabled = forecast.setup.host == nil || forecast.setup.isOn
        forecast = ForecastStatus(setup: enabled ? .on(host: endpoint.host) : .off(host: endpoint.host), buildHost: forecast.buildHost)
        send(.forecast)
    }

    func predictTabAppeared() {
        record("predictTabAppeared")
    }
}
#endif
