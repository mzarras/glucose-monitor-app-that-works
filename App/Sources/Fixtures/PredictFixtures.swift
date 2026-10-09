// DEBUG only: Predict tab states for previews, screenshots and the fixture model. Each is built by
// the real `PredictMapping` from a `ForecastStatus` whose documents went through ForecastKit's decoder
// (ForecastFixtureDocuments) and from the Now fixtures' readings. All values are made up.

#if DEBUG
import ForecastKit
import Foundation
import GlucoseCore
import WidgetCore

enum PredictFixtures {
    enum Scenario: String, CaseIterable, Identifiable {
        /// A run 3 min old with the stored reading it ran on, accuracy published.
        case current
        /// A current run, but this phone has no reading at the run's time.
        case currentWithoutReading
        /// Predictions at the model's low clip edge (≤40).
        case clippedLow
        /// Predictions at the model's high clip edge (≥400).
        case clippedHigh
        /// The last run is 32 min old: out of date.
        case stale
        /// The run is dated 5 min ahead of the phone's clock.
        case aheadOfClock
        case noRunYet
        /// On, nothing fetched yet.
        case waiting
        /// Fetching fails while a current run is held.
        case failingWithRun
        /// Fetching fails and nothing is held.
        case failingNothingHeld
        case notConfigured
        case turnedOff

        var id: String { rawValue }
    }

    static let host = "zen.example.com"
    static let offline = "Could not reach the forecast feed: The Internet connection appears to be offline."

    static func state(_ scenario: Scenario, at now: Date = Fixtures.referenceNow, context: DisplayContext = .current) -> PredictViewState {
        PredictMapping.make(status: status(scenario, at: now), readings: readings(scenario, at: now), at: ForecastFixtureDocuments.instant(now),
                            context: context)
    }

    static func status(_ scenario: Scenario, at now: Date = Fixtures.referenceNow) -> ForecastStatus {
        var status = ForecastStatus(setup: .on(host: host), buildHost: host)
        let ranAt = now.addingTimeInterval(-3 * 60)
        func held(generatedAt: Date?, zen: [Int: Double]? = ForecastFixtureDocuments.zen, decodedAt: Date = now) {
            status.latest = ForecastFixtureDocuments.decodedLatest(asOf: generatedAt ?? now.addingTimeInterval(-60), generatedAt: generatedAt,
                                                                   zen: zen, at: ForecastFixtureDocuments.instant(decodedAt))
            status.accuracy = ForecastFixtureDocuments.decodedAccuracy(asOf: now.addingTimeInterval(-10 * 60), at: ForecastFixtureDocuments.instant(now))
            status.lastAttemptAt = now.addingTimeInterval(-40)
            status.lastSuccessAt = now.addingTimeInterval(-40)
        }
        switch scenario {
        case .current, .currentWithoutReading:
            held(generatedAt: ranAt)
        case .clippedLow:
            held(generatedAt: ranAt, zen: [5: 52.3, 30: 40, 60: 40, 120: 47.6])
        case .clippedHigh:
            held(generatedAt: ranAt, zen: [5: 371.2, 30: 400, 60: 400, 120: 396.4])
        case .stale:
            held(generatedAt: now.addingTimeInterval(-32 * 60))
        case .aheadOfClock:
            // Decoded before the phone's clock was set back 10 minutes.
            held(generatedAt: now.addingTimeInterval(5 * 60), decodedAt: now.addingTimeInterval(10 * 60))
        case .noRunYet:
            held(generatedAt: nil, zen: nil)
        case .waiting:
            status.isFetching = true
            status.lastAttemptAt = now
        case .failingWithRun:
            held(generatedAt: ranAt)
            status.lastAttemptAt = now.addingTimeInterval(-20)
            status.consecutiveFailures = 2
            status.lastError = offline
        case .failingNothingHeld:
            status.lastAttemptAt = now.addingTimeInterval(-20)
            status.consecutiveFailures = 3
            status.lastError = offline
        case .notConfigured:
            status = .notConfigured
        case .turnedOff:
            status = ForecastStatus(setup: .off(host: host), buildHost: host)
        }
        return status
    }

    /// The Now fixtures' readings (the mockup curve, last reading 3 min before `now`, i.e. at the
    /// fixture run's time) as stored live readings. `currentWithoutReading` ends 9 min before `now`.
    static func readings(_ scenario: Scenario, at now: Date = Fixtures.referenceNow) -> [GlucoseReading] {
        let age: Double = scenario == .currentWithoutReading ? 9 : 3
        return Fixtures.dayOfPoints(now: now, lastReadingAge: age).map { point in
            GlucoseReading(id: "fixture-\(Int(point.date.timeIntervalSince1970))", date: point.date, value: point.value, trendRate: 0,
                           isBackfill: false, source: .sensor, sensorSerial: "SAMPLE0001")
        }
    }

    static func settings(_ scenario: Scenario, at now: Date = Fixtures.referenceNow) -> PredictionsSettings {
        PredictMapping.settings(status(scenario, at: now))
    }
}
#endif
