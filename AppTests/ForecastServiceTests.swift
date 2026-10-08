// PROGRESS D57, docs/forecast.md "Polling": the forecast service fetches only between
// enterForeground() and enterBackground(), at once and then on ForecastPolling's schedule, keeps
// everything in memory, and forgets it when the host changes or predictions are turned off. No
// network (FakeForecastTransport) and no waiting (ManualSleeper, an injected clock).

import ForecastKit
import Foundation
import XCTest
@testable import Sensor

@MainActor
final class ForecastServiceTests: XCTestCase {
    private var clock = PipelineTestClock(t0)
    private let sleeper = ManualSleeper()
    private var transport = FakeForecastTransport(latest: FakeForecastTransport.offline(), metrics: FakeForecastTransport.offline())

    private func makeService(buildHost: String? = ForecastTestDocuments.host) -> ForecastService {
        let clock = self.clock
        let sleeper = self.sleeper
        transport = FakeForecastTransport(latest: FakeForecastTransport.ok(ForecastTestDocuments.latest(run: minutes(-3))),
                                          metrics: FakeForecastTransport.ok(ForecastFixtureDocuments.metrics(asOf: minutes(-10))))
        let feed = ForecastService.Feed(buildHost: buildHost, transport: transport,
                                        sleep: { try await sleeper.sleep($0) }, clock: { ForecastFixtureDocuments.instant(clock.now) })
        return ForecastService(feed: feed)
    }

    /// Lets the poll task run until it is asleep (or the request count settles).
    private func waitForSleep(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let sleeper = self.sleeper
        await waitUntil("sleep #\(count)", file: file, line: line) { sleeper.requested.count >= count && sleeper.sleeping > 0 }
    }

    /// Gives any (wrongly) running task plenty of turns, then reports the request count.
    private func settledCount() async -> Int {
        for _ in 0..<50 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        return await transport.count
    }

    // MARK: - Foreground only

    func test_D57_nothingIsFetchedUntilTheForeground() async {
        let service = makeService()
        XCTAssertEqual(service.status.setup, .on(host: ForecastTestDocuments.host), "on by default with the build's host")
        service.configure(savedHost: nil, savedEnabled: nil) // bootstrap
        service.predictTabAppeared() // not in the foreground: nothing
        let count = await settledCount()
        XCTAssertEqual(count, 0)
        XCTAssertFalse(service.isPolling)
    }

    func test_D57_foregroundFetchesAtOnceThenEverySixtySeconds() async {
        let service = makeService()
        service.enterForeground()
        await waitForSleep(1)
        let paths = await transport.paths
        XCTAssertEqual(paths, ["latest.json", "metrics.json"], "latest at once, metrics never fetched before: due")
        let hosts = await transport.hosts
        XCTAssertEqual(Set(hosts), [ForecastTestDocuments.host])
        XCTAssertEqual(sleeper.requested, [60])
        XCTAssertNotNil(service.status.latest)
        XCTAssertNotNil(service.status.accuracy)
        XCTAssertEqual(service.status.lastAttemptAt, t0)
        XCTAssertEqual(service.status.lastSuccessAt, t0)
        XCTAssertEqual(service.status.consecutiveFailures, 0)
        XCTAssertFalse(service.status.isFetching)

        clock.advance(by: 60)
        sleeper.wake()
        await waitForSleep(2)
        let next = await transport.paths
        XCTAssertEqual(next, ["latest.json", "metrics.json", "latest.json"], "metrics not due again for 30 min")
        XCTAssertEqual(sleeper.requested, [60, 60])
        XCTAssertEqual(service.status.lastSuccessAt, t0.addingTimeInterval(60))
        service.enterBackground()
    }

    func test_D57_failuresBackOffSixtyOneTwentyThreeHundredThenSixtyAfterASuccess() async {
        let service = makeService()
        await transport.setDefaultLatest(FakeForecastTransport.offline())
        service.enterForeground()
        await waitForSleep(1)
        XCTAssertEqual(service.status.consecutiveFailures, 1)
        XCTAssertEqual(service.status.lastError, "Could not reach the forecast feed: The Internet connection appears to be offline.")
        XCTAssertNil(service.status.latest)
        let first = await transport.paths
        XCTAssertEqual(first, ["latest.json"], "no metrics request after a failed latest poll")
        for expected in [2, 3, 4] {
            sleeper.wake()
            await waitForSleep(expected)
        }
        XCTAssertEqual(sleeper.requested, [60, 120, 300, 300])
        XCTAssertEqual(service.status.consecutiveFailures, 4)

        await transport.setDefaultLatest(FakeForecastTransport.ok(ForecastTestDocuments.latest(run: minutes(-3))))
        sleeper.wake()
        await waitForSleep(5)
        XCTAssertEqual(sleeper.requested.last, 60, "back to 60 s after a success")
        XCTAssertEqual(service.status.consecutiveFailures, 0)
        XCTAssertNil(service.status.lastError)
        XCTAssertNotNil(service.status.latest)
        service.enterBackground()
    }

    /// D59: a `.cancelled` answer while polling is still wanted (the system cancelled the request,
    /// or a poll joined a shared request a stopped poll cancelled) is not a failure: no backoff, no
    /// error shown, the status is not left "updating", and polling goes on: at once the first time,
    /// then on the schedule the earlier failures set.
    func test_D59_aCancelledAnswerIsNotAFailureAndPollingGoesOn() async {
        let service = makeService()
        await transport.setDefaultLatest(FakeForecastTransport.offline())
        service.enterForeground()
        await waitForSleep(1)
        sleeper.wake()
        await waitForSleep(2)
        XCTAssertEqual(service.status.consecutiveFailures, 2)
        let error = service.status.lastError

        // One cancelled answer, then success: retried at once, no sleep in between, backoff untouched.
        await transport.cancelNextLatestRequests(1)
        await transport.setDefaultLatest(FakeForecastTransport.ok(ForecastTestDocuments.latest(run: minutes(-3))))
        sleeper.wake()
        await waitForSleep(3)
        var paths = await transport.paths
        XCTAssertEqual(paths, ["latest.json", "latest.json", "latest.json", "latest.json", "metrics.json"], "cancelled, then asked again at once")
        XCTAssertEqual(sleeper.requested, [60, 120, 60])
        XCTAssertEqual(service.status.consecutiveFailures, 0)
        XCTAssertFalse(service.status.isFetching)

        // Failures again, then two cancelled answers in a row: neither counts, the error stays the
        // last real one, and the next poll waits as two failures say (120 s), not three (300 s).
        await transport.setDefaultLatest(FakeForecastTransport.offline())
        for expected in [4, 5] {
            sleeper.wake()
            await waitForSleep(expected)
        }
        XCTAssertEqual(service.status.consecutiveFailures, 2)
        await transport.cancelNextLatestRequests(2)
        sleeper.wake()
        await waitForSleep(6)
        paths = await transport.paths
        XCTAssertEqual(paths.suffix(2), ["latest.json", "latest.json"])
        XCTAssertEqual(sleeper.requested.last, 120, "two failures, not four")
        XCTAssertEqual(service.status.consecutiveFailures, 2)
        XCTAssertEqual(service.status.lastError, error, "no \"cancelled\" error shown")
        XCTAssertFalse(service.status.isFetching, "not left updating")
        XCTAssertTrue(service.isPolling)
        service.enterBackground()
    }

    func test_D57_aFailedFetchKeepsWhatIsHeld() async {
        let service = makeService()
        service.enterForeground()
        await waitForSleep(1)
        let held = service.status.latest
        XCTAssertNotNil(held)
        await transport.setDefaultLatest(.success(ForecastHTTPResponse(statusCode: 403, eTag: nil, body: Data())))
        sleeper.wake()
        await waitForSleep(2)
        XCTAssertEqual(service.status.latest, held, "kept; it goes stale on the UI clock")
        XCTAssertEqual(service.status.consecutiveFailures, 1)
        XCTAssertEqual(service.status.lastError, "The forecast feed answered HTTP 403.")
        XCTAssertTrue(service.status.isFailing)
        service.enterBackground()
    }

    func test_D57_metricsAreFetchedAgainAfterThirtyMinutesAndRetriedAfterAFailure() async {
        let service = makeService()
        await transport.enqueueMetrics(FakeForecastTransport.offline())
        service.enterForeground()
        await waitForSleep(1)
        XCTAssertNil(service.status.accuracy, "the first metrics fetch failed")
        XCTAssertEqual(service.status.consecutiveFailures, 0, "a metrics failure is not a latest failure")
        clock.advance(by: 60)
        sleeper.wake()
        await waitForSleep(2)
        var paths = await transport.paths
        XCTAssertEqual(paths, ["latest.json", "metrics.json", "latest.json", "metrics.json"], "retried with the next poll")
        XCTAssertNotNil(service.status.accuracy)

        clock.advance(by: 29 * 60)
        sleeper.wake()
        await waitForSleep(3)
        paths = await transport.paths
        XCTAssertEqual(paths.count, 5, "29 min after the success: not due")
        clock.advance(by: 60)
        sleeper.wake()
        await waitForSleep(4)
        paths = await transport.paths
        XCTAssertEqual(Array(paths.suffix(2)), ["latest.json", "metrics.json"], "30 min after the success: due")
        service.enterBackground()
    }

    func test_D57_backgroundStopsPollingAndForegroundFetchesAtOnceAgain() async {
        let service = makeService()
        service.enterForeground()
        await waitForSleep(1)
        service.enterBackground()
        XCTAssertFalse(service.isPolling)
        await waitUntil("the sleeping poll ends") { self.sleeper.sleeping == 0 }
        sleeper.wake()
        let afterBackground = await settledCount()
        XCTAssertEqual(afterBackground, 2, "no request in the background")
        XCTAssertNotNil(service.status.latest, "what is held stays (it ages on the UI clock)")

        clock.advance(by: 10 * 60)
        service.enterForeground()
        await waitForSleep(2)
        let paths = await transport.paths
        XCTAssertEqual(paths, ["latest.json", "metrics.json", "latest.json"], "at once on the next foreground")
        service.enterForeground() // already polling: no second loop
        let count = await settledCount()
        XCTAssertEqual(count, 3)
        service.enterBackground()
    }

    /// The answer is an HTTP 403 that arrives after the app left the foreground (a plain answer, not
    /// a cancellation, so only the service's own stop guard can drop it).
    func test_D57_anAnswerAfterTheAppLeftTheForegroundIsDroppedNotCounted() async {
        let service = makeService()
        await transport.holdNextRequest() // answers whatever happens to the request's task
        service.enterForeground()
        await waitUntil("request on its way") { await self.transport.isHolding }
        XCTAssertTrue(service.status.isFetching)
        service.enterBackground()
        XCTAssertFalse(service.status.isFetching)
        await transport.setDefaultLatest(.success(ForecastHTTPResponse(statusCode: 403, eTag: nil, body: Data())))
        await transport.release()
        _ = await settledCount()
        XCTAssertEqual(service.status.consecutiveFailures, 0, "an answer after leaving the foreground is not a failure")
        XCTAssertNil(service.status.lastError)
        XCTAssertFalse(service.status.isFetching)
        XCTAssertTrue(sleeper.requested.isEmpty)
    }

    /// Host change while the old host's request is out: its 200 arrives after the change and must
    /// not become the new host's forecast.
    func test_D57_anOldHostsAnswerAfterAHostChangeIsDropped() async {
        let service = makeService()
        await transport.holdNextRequest() // zen.example.com
        await transport.holdNextRequest() // other.example.com
        service.enterForeground()
        await waitUntil("old host's request out") { await self.transport.heldCount == 1 }
        service.configure(savedHost: "other.example.com", savedEnabled: nil)
        await waitUntil("new host's request out") { await self.transport.heldCount == 2 }
        let hosts = await transport.hosts
        XCTAssertEqual(hosts, [ForecastTestDocuments.host, "other.example.com"])

        await transport.release() // the old host answers 200 with a current run
        _ = await settledCount()
        XCTAssertNil(service.status.latest, "the old host's document is never the new host's forecast")
        XCTAssertEqual(service.status.setup, .on(host: "other.example.com"))
        XCTAssertNil(service.status.lastSuccessAt)
        XCTAssertEqual(service.status.consecutiveFailures, 0)
        XCTAssertTrue(service.status.isFetching, "the new host's request is still out")

        await transport.release()
        await waitForSleep(1)
        XCTAssertNotNil(service.status.latest, "the new host's own answer is applied")
        service.enterBackground()
    }

    /// m2: opening the tab while a poll runs neither cancels it (single-flight requests are shared)
    /// nor sends a second request; the answer that comes back is applied.
    func test_D57_openingTheTabDuringAFetchNeitherCancelsNorRepeatsIt() async {
        let service = makeService()
        await transport.holdNextRequest(cancellable: true) // ends at once if its task is cancelled
        service.enterForeground()
        await waitUntil("request on its way") { await self.transport.isHolding }
        clock.advance(by: 31)
        service.predictTabAppeared()
        var count = await settledCount()
        XCTAssertEqual(count, 1, "no second request")
        let stillHeld = await transport.isHolding
        XCTAssertTrue(stillHeld, "the running request was not cancelled")
        XCTAssertEqual(service.status.lastAttemptAt, t0, "the running poll is still the attempt")
        XCTAssertTrue(service.status.isFetching)

        await transport.release()
        await waitForSleep(1)
        XCTAssertNotNil(service.status.latest, "its answer is applied")
        XCTAssertEqual(service.status.lastSuccessAt, t0.addingTimeInterval(31))
        count = await transport.count
        XCTAssertEqual(count, 2, "latest once, then metrics")
        XCTAssertEqual(sleeper.requested, [60])
        service.enterBackground()
    }

    /// While fetches fail, opening the tab waits out the failure backoff instead of adding requests.
    func test_D57_openingTheTabRespectsTheFailureBackoff() async {
        let service = makeService()
        await transport.setDefaultLatest(FakeForecastTransport.offline())
        service.enterForeground()
        await waitForSleep(1)
        for expected in [2, 3] {
            sleeper.wake()
            await waitForSleep(expected)
        }
        XCTAssertEqual(service.status.consecutiveFailures, 3)
        XCTAssertEqual(sleeper.requested, [60, 120, 300])
        clock.advance(by: 31)
        service.predictTabAppeared()
        var count = await settledCount()
        XCTAssertEqual(count, 3, "31 s into a 300 s backoff: nothing")
        clock.advance(by: 269) // 300 s since the last attempt
        service.predictTabAppeared()
        count = await settledCount()
        XCTAssertEqual(count, 3, "still within the backoff")
        clock.advance(by: 1)
        service.predictTabAppeared()
        await waitForSleep(4)
        count = await transport.count
        XCTAssertEqual(count, 4, "past the backoff: at once")
        service.enterBackground()
    }

    /// m1: a document rejected for a 700 mg/dL value. The full reason goes to the diagnostic log;
    /// the Predict tab and Settings name only the field, never the value.
    func test_D57_aRejectedDocumentsValueIsNeverShown() async {
        let clock = self.clock
        let sleeper = self.sleeper
        let logged = LogBox()
        transport = FakeForecastTransport(
            latest: FakeForecastTransport.ok(ForecastTestDocuments.latest(run: minutes(-3), zen: [5: 110, 30: 700, 60: 120, 120: 130])),
            metrics: FakeForecastTransport.ok(ForecastFixtureDocuments.metrics(asOf: minutes(-10))))
        let feed = ForecastService.Feed(buildHost: ForecastTestDocuments.host, transport: transport,
                                        sleep: { try await sleeper.sleep($0) }, clock: { ForecastFixtureDocuments.instant(clock.now) })
        let service = ForecastService(feed: feed) { logged.lines.append($0) }
        service.enterForeground()
        await waitForSleep(1)
        XCTAssertEqual(service.status.lastError, "The forecast feed failed validation (predictions.zen.30).")
        XCTAssertTrue(logged.lines.contains { $0.contains("700") }, "the log keeps the full reason: \(logged.lines)")

        let predict = PredictMapping.make(status: service.status, readings: [], at: ForecastFixtureDocuments.instant(t0), context: testContext)
        let settings = PredictMapping.settings(service.status)
        let shown = [String(describing: predict), settings.lastError ?? "", settings.rowValue].joined(separator: " ")
        XCTAssertTrue(shown.contains("predictions.zen.30"), shown)
        XCTAssertFalse(shown.contains("700"), shown)
        service.enterBackground()
    }

    func test_D57_predictTabFetchesAtOnceOnlyWhenTheLastAttemptIsOverThirtySecondsOld() async {
        let service = makeService()
        service.enterForeground()
        await waitForSleep(1)
        clock.advance(by: 30)
        service.predictTabAppeared()
        var count = await settledCount()
        XCTAssertEqual(count, 2, "30 s: nothing")
        clock.advance(by: 1)
        service.predictTabAppeared()
        await waitForSleep(2)
        count = await transport.count
        XCTAssertEqual(count, 3, "31 s: at once")
        XCTAssertEqual(sleeper.requested, [60, 60], "the next poll is a full interval after it")
        await waitUntil("the replaced loop's sleep ends") { self.sleeper.sleeping == 1 }
        _ = await settledCount()
        XCTAssertEqual(sleeper.sleeping, 1, "one polling loop, never two")
        service.enterBackground()
    }

    // MARK: - Settings changes

    func test_D57_turningPredictionsOffStopsPollingAndForgetsWhatWasHeld() async {
        let service = makeService()
        service.enterForeground()
        await waitForSleep(1)
        service.configure(savedHost: nil, savedEnabled: false)
        XCTAssertEqual(service.status.setup, .off(host: ForecastTestDocuments.host))
        XCTAssertNil(service.status.latest)
        XCTAssertNil(service.status.accuracy)
        XCTAssertNil(service.status.lastSuccessAt)
        XCTAssertFalse(service.isPolling)
        sleeper.wake()
        let count = await settledCount()
        XCTAssertEqual(count, 2)

        service.configure(savedHost: nil, savedEnabled: true)
        await waitForSleep(2)
        let paths = await transport.paths
        XCTAssertEqual(Array(paths.suffix(2)), ["latest.json", "metrics.json"], "on again in the foreground: fetched at once, metrics too")
        service.enterBackground()
    }

    func test_D57_aNewHostForgetsTheOldHostsForecastAndFetchesFromTheNewOne() async {
        let service = makeService()
        service.enterForeground()
        await waitForSleep(1)
        await transport.holdNextRequest()
        service.configure(savedHost: "other.example.org", savedEnabled: nil)
        XCTAssertEqual(service.status.setup, .on(host: "other.example.org"))
        XCTAssertNil(service.status.latest, "the old host's run is forgotten at once")
        await waitUntil("new host requested") { await self.transport.isHolding }
        let hosts = await transport.hosts
        XCTAssertEqual(hosts.last, "other.example.org")
        await transport.release()
        await waitForSleep(2)
        XCTAssertNotNil(service.status.latest)
        service.enterBackground()
    }

    func test_D57_noHostMeansNoRequests() async {
        let service = makeService(buildHost: "")
        XCTAssertEqual(service.status.setup, .notConfigured)
        service.enterForeground()
        service.predictTabAppeared()
        let count = await settledCount()
        XCTAssertEqual(count, 0)
        XCTAssertFalse(service.isPolling)
    }
}

/// Collects the forecast service's diagnostic lines.
@MainActor
private final class LogBox {
    var lines: [String] = []
}
