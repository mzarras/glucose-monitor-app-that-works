// DEBUG only: `-forecastFixture <kind>` makes the forecast service read a fixture feed instead of the
// network, so UI tests and app-run screenshots never make a request (and show the same thing on
// every machine, whatever Signing.xcconfig's ZEN_PREDICT_FEED_HOST says). The launch also starts
// from the build's settings: the host and switch saved in Settings › Predictions are cleared
// (AppEnvironment). Compiled out of Release.

#if DEBUG
import ForecastKit
import Foundation

enum ForecastFixtureFeed {
    static let launchArgument = "-forecastFixture"
    /// The host the fixture answers for: a reserved example name (RFC 2606), never a real site.
    static let host = "zen.example.com"

    enum Kind: String, CaseIterable {
        /// A run made 3 minutes before launch, with accuracy; it ages on the real clock.
        case current
        /// A run made 32 minutes before launch: "out of date".
        case stale
        /// latest.json with no Zen run yet.
        case noRun
        /// Every request fails as if offline.
        case offline
        /// No host at all (the build's and the saved one ignored).
        case notConfigured
    }

    /// The kind named after `-forecastFixture`, nil without the argument (or an unknown name).
    static func kind(arguments: [String]) -> Kind? {
        guard let index = arguments.firstIndex(of: launchArgument), index + 1 < arguments.count else { return nil }
        return Kind(rawValue: arguments[index + 1])
    }

    /// The feed for `kind`, with times relative to `launch`.
    static func feed(_ kind: Kind, launch: Date) -> ForecastService.Feed {
        if kind == .notConfigured { return .none }
        return ForecastService.Feed(buildHost: host, transport: FixtureForecastTransport(kind: kind, launch: launch))
    }

    /// Steady around the replay scenario `steady` (112–114 mg/dL, docs/replay.md), so the forecast
    /// line in an app-run screenshot starts near the readings. Made up.
    static let zen: [Int: Double] = [5: 113.4, 30: 118.6, 60: 126.2, 120: 138.9]
}

/// Answers latest.json and metrics.json from `ForecastFixtureDocuments`, every time with 200.
struct FixtureForecastTransport: ForecastTransport {
    let kind: ForecastFixtureFeed.Kind
    let launch: Date

    func send(_ request: URLRequest) async throws(ForecastTransportError) -> ForecastHTTPResponse {
        let now = Date()
        let body: Data
        switch (kind, request.url?.lastPathComponent) {
        case (.offline, _), (.notConfigured, _):
            throw ForecastTransportError(message: "The Internet connection appears to be offline.")
        case (_, "metrics.json"):
            body = ForecastFixtureDocuments.metrics(asOf: now)
        case (.current, _):
            body = ForecastFixtureDocuments.latest(asOf: now, generatedAt: launch.addingTimeInterval(-3 * 60), zen: ForecastFixtureFeed.zen, feedGlucose: 113)
        case (.stale, _):
            body = ForecastFixtureDocuments.latest(asOf: now, generatedAt: launch.addingTimeInterval(-32 * 60), zen: ForecastFixtureFeed.zen, feedGlucose: 113)
        case (.noRun, _):
            body = ForecastFixtureDocuments.latest(asOf: now, generatedAt: nil, zen: nil, oref: nil, feedGlucose: 113)
        }
        return ForecastHTTPResponse(statusCode: 200, eTag: nil, body: body)
    }
}
#endif
