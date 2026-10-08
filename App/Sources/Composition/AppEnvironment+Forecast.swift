// The composition root's part of predictions (PROGRESS D57): which feed the forecast service reads.

import ForecastKit
import Foundation
import GlucoseCore

extension AppEnvironment {
    /// The Zen Predict feed host from Info.plist `ZenPredictFeedHost` (= `ZEN_PREDICT_FEED_HOST` from
    /// the gitignored Signing.xcconfig; empty = predictions not set up) over URLSession. DEBUG
    /// `-forecastFixture <kind>`: a fixture feed instead (no network), starting from the build's
    /// settings (the saved host and switch are cleared), so UI tests and screenshots are the same on
    /// every machine.
    static func makeForecastFeed(arguments: [String], preferences: AppPreferences, diagnostics: any DiagnosticLog) -> ForecastService.Feed {
        #if DEBUG
        if let fixture = ForecastFixtureFeed.kind(arguments: arguments) {
            preferences.forecastFeedHost = nil
            preferences.forecastEnabled = nil
            diagnostics.record(DiagnosticEvent(date: Date(), category: .app, message: "forecast feed: fixture \(fixture.rawValue) (\(ForecastFixtureFeed.launchArgument), DEBUG)"))
            return ForecastFixtureFeed.feed(fixture, launch: Date())
        }
        #endif
        let host = Bundle.main.object(forInfoDictionaryKey: "ZenPredictFeedHost") as? String
        return ForecastService.Feed(buildHost: host, transport: URLSessionForecastTransport())
    }
}
