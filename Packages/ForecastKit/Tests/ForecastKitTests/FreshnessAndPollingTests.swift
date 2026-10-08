// Original to Sensor (no ported code).
import XCTest
@testable import ForecastKit

/// The 15-minute rule by both clocks. Instants are built from whole numbers so every boundary is
/// exact: the run is at `generatedAt`; its document arrives `arrivalAge` seconds later at monotonic
/// reading 1_000.
final class FreshnessTests: XCTestCase {
    private let generatedAt = FeedFixtures.october8(14, 25, 5)
    private let arrivalAge: TimeInterval = 60
    private var arrived: ForecastInstant { ForecastInstant(wall: generatedAt.addingTimeInterval(arrivalAge), monotonic: 1_000) }

    /// Both clocks agree: `age` seconds after the run.
    private func atAge(_ age: TimeInterval) -> ForecastInstant {
        ForecastInstant(wall: generatedAt.addingTimeInterval(age), monotonic: 1_000 + age - arrivalAge)
    }

    /// The wall clock reads `wallAge` after the run while `elapsed` real seconds passed since arrival.
    private func at(wallAge: TimeInterval, elapsed: TimeInterval) -> ForecastInstant {
        ForecastInstant(wall: generatedAt.addingTimeInterval(wallAge), monotonic: 1_000 + elapsed)
    }

    private func classify(_ now: ForecastInstant) -> ForecastFreshness {
        ForecastFreshness.classify(generatedAt: generatedAt, receivedAt: arrived, at: now)
    }

    func testLimits() {
        XCTAssertEqual(ForecastLimits.staleAfter, 900, "D57: 15 minutes")
        XCTAssertEqual(ForecastLimits.clockSkewTolerance, 120)
    }

    func testCurrentUpToAndIncludingFifteenMinutes() {
        XCTAssertEqual(classify(atAge(60)), .current(age: 60))
        XCTAssertEqual(classify(atAge(299)), .current(age: 299))
        XCTAssertEqual(classify(atAge(900)), .current(age: 900))
    }

    func testStaleAfterFifteenMinutes() {
        XCTAssertEqual(classify(atAge(900.5)), .stale(age: 900.5))
        XCTAssertEqual(classify(atAge(3600)), .stale(age: 3600))
        XCTAssertFalse(classify(atAge(900.5)).isCurrent)
    }

    func testBoundaryByTheWallClock() {
        // Clock set forward 10 minutes right after arrival: the wall clock decides.
        XCTAssertEqual(classify(at(wallAge: 900, elapsed: 240)), .current(age: 900))
        XCTAssertEqual(classify(at(wallAge: 900.5, elapsed: 240)), .stale(age: 900.5))
    }

    func testBoundaryByTheMonotonicClock() {
        // Clock set back right after arrival: the wall clock says 100 s, real time says 900 s.
        XCTAssertEqual(classify(at(wallAge: 100, elapsed: 840)), .current(age: 900))
        XCTAssertEqual(classify(at(wallAge: 100, elapsed: 840.5)), .stale(age: 900.5))
    }

    func testClockSetForwardMakesTheRunStaleEarly() {
        // Real age 5 minutes, but the phone now reads 25 minutes after the run: errs safe.
        XCTAssertEqual(classify(at(wallAge: 1500, elapsed: 240)), .stale(age: 1500))
    }

    func testSlightlyAheadOfTheClockIsCurrentWithAgeZero() {
        // Arrived 2 minutes before the run by the phone's clock (an uploader clock running fast).
        let early = ForecastInstant(wall: generatedAt.addingTimeInterval(-120), monotonic: 1_000)
        func classify(wallAge: TimeInterval, elapsed: TimeInterval) -> ForecastFreshness {
            ForecastFreshness.classify(generatedAt: generatedAt, receivedAt: early, at: at(wallAge: wallAge, elapsed: elapsed))
        }
        XCTAssertEqual(classify(wallAge: -120, elapsed: 0), .current(age: 0))
        XCTAssertEqual(classify(wallAge: -1, elapsed: 119), .current(age: 0))
        XCTAssertEqual(classify(wallAge: 60, elapsed: 180), .current(age: 60))
        // Ages are measured against the phone's clock, so a run stamped up to 2 minutes fast stays
        // current up to 2 minutes longer (ForecastLimits.clockSkewTolerance).
        XCTAssertEqual(classify(wallAge: 900, elapsed: 1020), .current(age: 900))
        XCTAssertEqual(classify(wallAge: 901, elapsed: 1021), .stale(age: 901))
    }

    func testFarAheadOfTheClockIsNotCurrent() {
        XCTAssertEqual(classify(at(wallAge: -120.5, elapsed: 1)), .aheadOfClock(by: 120.5))
        XCTAssertFalse(classify(at(wallAge: -121, elapsed: 1)).isCurrent)
        // Even when real time says the run is young.
        XCTAssertEqual(classify(at(wallAge: -3600, elapsed: 0)), .aheadOfClock(by: 3600))
    }

    func testMonotonicClockGoingBackwardsIsStale() {
        XCTAssertEqual(classify(at(wallAge: 120, elapsed: -1)), .stale(age: 120))
        XCTAssertEqual(classify(at(wallAge: 30, elapsed: -500)), .stale(age: 60), "the age on arrival when larger")
    }

    func testConservativeAgeIsNeverNegative() {
        let early = ForecastInstant(wall: generatedAt.addingTimeInterval(-100), monotonic: 1_000)
        let now = ForecastInstant(wall: generatedAt.addingTimeInterval(-90), monotonic: 1_010)
        XCTAssertEqual(ForecastFreshness.conservativeAge(generatedAt: generatedAt, receivedAt: early, at: now), 0)
    }

    func testLatestForecastAccessorsAgree() throws {
        let latest = try ForecastFeedDecoder.decodeLatest(FeedFixtures.latestBody(runAt: generatedAt), at: arrived)
        XCTAssertEqual(latest.zenRunTime, generatedAt)
        for (now, expected) in [(atAge(600), ForecastFreshness.current(age: 600)),
                                (at(wallAge: 100, elapsed: 1000), .stale(age: 1060)),
                                (at(wallAge: -500, elapsed: 0), .aheadOfClock(by: 500))] {
            XCTAssertEqual(latest.zenFreshness(at: now), expected)
            XCTAssertEqual(latest.currentRun(at: now) != nil, expected.isCurrent)
            switch expected {
            case .current(let age), .stale(let age): XCTAssertEqual(latest.zenRunAge(at: now), age)
            case .aheadOfClock: XCTAssertEqual(latest.zenRunAge(at: now), 60, "the age on arrival")
            }
        }
    }

    func testNoRunMeansNoFreshness() throws {
        let object = FeedFixtures.setting(["predictions", "zen"], to: NSNull(), in: FeedFixtures.latestObject())
        let latest = try ForecastFeedDecoder.decodeLatest(FeedFixtures.json(object), at: FeedFixtures.nowInstant)
        XCTAssertNil(latest.zenRunTime)
        XCTAssertNil(latest.zenRunAge(at: FeedFixtures.nowInstant))
        XCTAssertNil(latest.zenFreshness(at: FeedFixtures.nowInstant))
        XCTAssertNil(latest.currentRun(at: FeedFixtures.nowInstant))
    }

    func testLiveInstantReadsBothClocks() {
        let before = Date()
        let first = ForecastInstant.now()
        let second = ForecastInstant.now()
        XCTAssertGreaterThanOrEqual(first.wall, before)
        XCTAssertGreaterThan(first.monotonic, 0)
        XCTAssertGreaterThanOrEqual(second.monotonic, first.monotonic, "monotonic")
    }
}

final class PollingTests: XCTestCase {
    func testLatestBackoffSequence() {
        let delays = (0...6).map { ForecastPolling.delayBeforeNextLatestPoll(consecutiveFailures: $0) }
        XCTAssertEqual(delays, [60, 60, 120, 300, 300, 300, 300])
        XCTAssertEqual(ForecastPolling.delayBeforeNextLatestPoll(consecutiveFailures: -1), 60)
        XCTAssertEqual(ForecastPolling.delayBeforeNextLatestPoll(consecutiveFailures: .max), 300)
    }

    func testBackoffResetsAfterASuccess() {
        // The app counts failures and resets to 0 on success (a 304 included).
        var failures = 0
        var delays: [TimeInterval] = []
        for succeeded in [false, false, false, false, true, false] {
            failures = succeeded ? 0 : failures + 1
            delays.append(ForecastPolling.delayBeforeNextLatestPoll(consecutiveFailures: failures))
        }
        XCTAssertEqual(delays, [60, 120, 300, 300, 60, 60])
    }

    func testMetricsAtMostEveryThirtyMinutes() {
        let last = FeedFixtures.now
        XCTAssertTrue(ForecastPolling.isMetricsFetchDue(lastSuccessfulFetch: nil, now: last))
        XCTAssertFalse(ForecastPolling.isMetricsFetchDue(lastSuccessfulFetch: last, now: last))
        XCTAssertFalse(ForecastPolling.isMetricsFetchDue(lastSuccessfulFetch: last, now: last.addingTimeInterval(1799)))
        XCTAssertTrue(ForecastPolling.isMetricsFetchDue(lastSuccessfulFetch: last, now: last.addingTimeInterval(1800)))
        XCTAssertTrue(ForecastPolling.isMetricsFetchDue(lastSuccessfulFetch: last, now: last.addingTimeInterval(-1)), "clock moved back")
    }

    func testIntervals() {
        XCTAssertEqual(ForecastPolling.latestInterval, 60)
        XCTAssertEqual(ForecastPolling.failureBackoff, [60, 120, 300])
        XCTAssertEqual(ForecastPolling.metricsInterval, 1800)
    }
}
