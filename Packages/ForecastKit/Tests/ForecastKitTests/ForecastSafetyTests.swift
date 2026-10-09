// Original to Sensor (no ported code).
// Safety tests for the forecast feed (PROGRESS D57 applies S1, S3 and S4 to forecasts).
// scripts/check.sh gate 3 counts these by name; each one checks a refusal, not just a happy path.
import XCTest
@testable import ForecastKit

final class ForecastSafetyTests: XCTestCase {
    private let now = FeedFixtures.now
    private let minute: TimeInterval = 60

    private func decodeLatest(_ data: Data, at instant: ForecastInstant) throws -> LatestForecast {
        try ForecastFeedDecoder.decodeLatest(data, at: instant)
    }

    // MARK: - S1: a stale or doubtful forecast is never presented as current

    func test_S1_staleRunIsNeverCurrent() throws {
        // The document arrives at the run's own time; both clocks then move together. (Instants
        // are built from whole numbers so the 900 s boundary is exact.)
        let generatedAt = try XCTUnwrap(FeedTimestamp.parse("2026-10-08T14:20:05.112233+00:00"))
        let arrived = ForecastInstant(wall: generatedAt, monotonic: 1_000)
        func at(_ age: TimeInterval) -> ForecastInstant { ForecastInstant(wall: generatedAt.addingTimeInterval(age), monotonic: 1_000 + age) }
        let latest = try decodeLatest(try FeedFixtures.data("synthetic_latest_live_format"), at: arrived)
        XCTAssertEqual(latest.zenRunTime, generatedAt)
        // Anything older than 15 minutes is stale, however far past the limit.
        let ages: [TimeInterval] = [900.001, 901, 1800, 3600, 86_400, 30 * 86_400]
        for age in ages {
            let instant = at(age)
            let freshness = try XCTUnwrap(latest.zenFreshness(at: instant))
            XCTAssertNil(latest.currentRun(at: instant), "age \(age)")
            guard case .stale(let reported) = freshness else { return XCTFail("age \(age): \(freshness)") }
            XCTAssertEqual(reported, age, accuracy: 1e-6)
            XCTAssertEqual(try XCTUnwrap(latest.zenRunAge(at: instant)), age, accuracy: 1e-6)
        }
        // And exactly 15 minutes is the last current instant.
        XCTAssertNotNil(latest.currentRun(at: at(900)))
    }

    func test_S1_currentRunIsNilOnceTheRunIsStale() throws {
        let latest = try decodeLatest(FeedFixtures.json(FeedFixtures.latestObject()), at: FeedFixtures.nowInstant)
        let zen = try XCTUnwrap(latest.zen)
        XCTAssertEqual(latest.currentRun(at: FeedFixtures.instant(zen.generatedAt.addingTimeInterval(900))), zen)
        XCTAssertNil(latest.currentRun(at: FeedFixtures.instant(zen.generatedAt.addingTimeInterval(901))))
        XCTAssertEqual(latest.zenRunTime, zen.generatedAt, "the stale run's time stays available (\"out of date since …\")")
    }

    func test_S1_runAheadOfThePhonesClockIsNeverCurrent() throws {
        // Possible only if the phone's clock was set back after the document arrived.
        let latest = try decodeLatest(FeedFixtures.json(FeedFixtures.latestObject()), at: FeedFixtures.nowInstant)
        let generatedAt = try XCTUnwrap(latest.zenRunTime)
        for ahead in [120.5, 600, 86_400] {
            // Set back so the wall clock reads `ahead` before the run; one real second has passed.
            let at = FeedFixtures.instant(generatedAt.addingTimeInterval(-ahead), monotonic: FeedFixtures.monotonicAtNow + 1)
            XCTAssertEqual(latest.zenFreshness(at: at), .aheadOfClock(by: ahead))
            XCTAssertNil(latest.currentRun(at: at))
        }
    }

    func test_S1_clockSetBackDoesNotMakeAnOldRunCurrent() throws {
        // Review of 79c2c40, M2: a run made at real time T arrives at once; at real T+14 min the
        // phone's clock is set back by Δ. A newer run is then refused as future-dated, so the app
        // keeps the old document. By the wall clock alone the old run would read "current" until
        // the phone reads T+15, i.e. real T+15+Δ. It must stop being current at real T+15.
        let realT = now
        let monotonicAtT: TimeInterval = 7_000
        func real(_ minutes: Double, setBackBy delta: TimeInterval = 0) -> ForecastInstant {
            ForecastInstant(wall: realT.addingTimeInterval(minutes * minute - delta), monotonic: monotonicAtT + minutes * minute)
        }
        let old = try decodeLatest(FeedFixtures.latestBody(runAt: realT), at: real(0))
        XCTAssertNotNil(old.currentRun(at: real(0)))

        for delta in [10 * minute, 60 * minute] {
            // At real T+14 the newer run (made at real T+10) is refused: the phone now reads T+14−Δ.
            let newer = FeedFixtures.latestBody(runAt: realT.addingTimeInterval(10 * minute))
            XCTAssertThrowsError(try decodeLatest(newer, at: real(14, setBackBy: delta)), "Δ \(delta)") { error in
                guard case .futureDated = error as? ForecastDocumentError else { return XCTFail("\(error)") }
            }
            // At real T+14 the run is 14 minutes old. Set back 10 minutes it is still current (by
            // its real age); set back an hour the phone reads 46 minutes before the run, which is
            // "ahead of the clock" and not current either. Never current after real T+15.
            XCTAssertEqual(old.zenFreshness(at: real(14, setBackBy: delta)),
                           delta == 10 * minute ? .current(age: 14 * minute) : .aheadOfClock(by: 46 * minute))
            var minutes = 15.0 + 1.0 / 60
            while minutes <= 15 + delta / minute + 5 {
                let at = real(minutes, setBackBy: delta)
                XCTAssertNil(old.currentRun(at: at), "Δ \(delta / minute) min: current at real T+\(minutes) min")
                XCTAssertFalse(try XCTUnwrap(old.zenFreshness(at: at)).isCurrent)
                minutes += 0.5
            }
            // The scenario's exact instant: the phone reads T+15 at real T+15+Δ.
            let phoneReadsTPlus15 = real(15 + delta / minute, setBackBy: delta)
            XCTAssertEqual(phoneReadsTPlus15.wall, realT.addingTimeInterval(15 * minute))
            XCTAssertNil(old.currentRun(at: phoneReadsTPlus15))
            XCTAssertEqual(try XCTUnwrap(old.zenRunAge(at: phoneReadsTPlus15)), 15 * minute + delta, accuracy: 1e-6,
                           "the age is the real age, not the phone clock's")
        }
    }

    func test_S1_monotonicClockGoingBackwardsIsNeverCurrent() throws {
        // Impossible within one boot (documents live only in memory), but the rule is total.
        let arrived = FeedFixtures.nowInstant
        let latest = try decodeLatest(FeedFixtures.json(FeedFixtures.latestObject()), at: arrived)
        let later = ForecastInstant(wall: arrived.wall.addingTimeInterval(10), monotonic: arrived.monotonic - 1)
        guard case .stale(let age) = try XCTUnwrap(latest.zenFreshness(at: later)) else {
            return XCTFail("a run whose elapsed time is unknown must be stale")
        }
        XCTAssertEqual(age, 130, accuracy: 1e-6, "the larger of the wall age (130 s) and the age on arrival (120 s)")
        XCTAssertNil(latest.currentRun(at: later))
        XCTAssertEqual(try XCTUnwrap(latest.zenRunAge(at: later)), 130, accuracy: 1e-6)
    }

    func test_S1_notModifiedAfterTheClockIsSetBackKeepsTheRunsAge() async throws {
        // A 304 keeps the document's original receipt instant. Re-stamping it at the 304 would
        // restart its age from a phone clock that had been set back.
        let runAt = now
        let clock = TestClock(ForecastInstant(wall: runAt.addingTimeInterval(60), monotonic: 3_000))
        let transport = MockForecastTransport([
            MockForecastTransport.ok(FeedFixtures.latestBody(runAt: runAt), eTag: "\"E1\""),
            MockForecastTransport.status(304, eTag: "\"E1\""),
        ])
        let client = ForecastFeedClient(endpoint: try ForecastFeedEndpoint("zen.example.com"), transport: transport, now: { clock.now })
        let first = try await client.fetchLatest()

        clock.advance(by: 13 * minute)         // real run age 14 min
        clock.changeWallClock(by: -10 * minute) // the phone now reads 4 min after the run
        let second = try await client.fetchLatest()
        XCTAssertEqual(second, first, "a 304 returns the earlier document unchanged, receipt instant included")
        XCTAssertNotNil(second.currentRun(at: clock.now), "14 minutes old: still current")

        clock.advance(by: 1.5 * minute)        // real age 15.5 min; the phone reads 5.5 min
        XCTAssertNil(second.currentRun(at: clock.now))
        XCTAssertEqual(second.zenFreshness(at: clock.now), .stale(age: 15.5 * minute))
    }

    func test_S1_futureDatedFeedIsRejected() throws {
        let skew = ForecastLimits.clockSkewTolerance
        let futureAsOf = FeedFixtures.setting(["as_of"], to: FeedFixtures.pythonISO(now.addingTimeInterval(skew + 1)), in: FeedFixtures.latestObject())
        XCTAssertThrowsError(try decodeLatest(FeedFixtures.json(futureAsOf), at: FeedFixtures.nowInstant)) { error in
            XCTAssertEqual(error as? ForecastDocumentError, .futureDated(field: "as_of"))
        }
        var futureRun = FeedFixtures.setting(["as_of"], to: FeedFixtures.pythonISO(now), in: FeedFixtures.latestObject())
        futureRun = FeedFixtures.setting(["predictions", "generated_at"], to: FeedFixtures.pythonISO(now.addingTimeInterval(skew + 1)), in: futureRun)
        XCTAssertThrowsError(try decodeLatest(FeedFixtures.json(futureRun), at: FeedFixtures.nowInstant)) { error in
            XCTAssertEqual(error as? ForecastDocumentError, .futureDated(field: "predictions.generated_at"))
        }
        let futureMetrics = FeedFixtures.setting(["as_of"], to: FeedFixtures.pythonISO(now.addingTimeInterval(skew + 1)), in: FeedFixtures.metricsObject())
        XCTAssertThrowsError(try ForecastFeedDecoder.decodeAccuracy(FeedFixtures.json(futureMetrics), at: FeedFixtures.nowInstant))
        // A document in the live format, judged by a phone clock an hour behind: rejected.
        XCTAssertThrowsError(try decodeLatest(try FeedFixtures.data("synthetic_latest_live_format"), at: FeedFixtures.instant(FeedFixtures.october8(13, 21))))
    }

    func test_S1_implausibleForecastRejectsWholeDocument() {
        // Three good Zen points and one bad one: nothing from the document may be used.
        let badZen = FeedFixtures.setting(["predictions", "zen", "60"], to: 1_500, in: FeedFixtures.latestObject())
        XCTAssertThrowsError(try decodeLatest(FeedFixtures.json(badZen), at: FeedFixtures.nowInstant)) { error in
            XCTAssertEqual(error as? ForecastDocumentError, .implausibleForecast(field: "predictions.zen.60", value: 1_500))
        }
        // A bad oref value rejects the Zen run with it.
        let badOref = FeedFixtures.setting(["predictions", "oref", "5"], to: -40, in: FeedFixtures.latestObject())
        XCTAssertThrowsError(try decodeLatest(FeedFixtures.json(badOref), at: FeedFixtures.nowInstant))
        // An mmol/L value leaking into the feed (6.1 mmol/L ≈ 110 mg/dL).
        let mmol = FeedFixtures.setting(["predictions", "zen", "30"], to: 6.1, in: FeedFixtures.latestObject())
        XCTAssertThrowsError(try decodeLatest(FeedFixtures.json(mmol), at: FeedFixtures.nowInstant))
    }

    func test_S1_forecastValuesWithoutTheirRunTimeAreRejected() {
        let noTime = FeedFixtures.setting(["predictions", "generated_at"], to: NSNull(), in: FeedFixtures.latestObject())
        XCTAssertThrowsError(try decodeLatest(FeedFixtures.json(noTime), at: FeedFixtures.nowInstant)) { error in
            XCTAssertEqual(error as? ForecastDocumentError, .valueWithoutTimestamp(field: "predictions.zen"))
        }
    }

    func test_S1_rejectedDocumentIsNeverServedLater() async throws {
        // In sequence: after a rejected document the client forgets the earlier one, so no later
        // 304 can bring back a document that is no longer what the server holds.
        let bad = FeedFixtures.json(FeedFixtures.setting(["predictions", "zen", "5"], to: 0, in: FeedFixtures.latestObject()))
        let transport = MockForecastTransport([
            MockForecastTransport.ok(FeedFixtures.json(FeedFixtures.latestObject()), eTag: "\"good\""),
            MockForecastTransport.ok(bad, eTag: "\"bad\""),
            MockForecastTransport.status(304, eTag: "\"good\""),
        ])
        let client = ForecastFeedClient(endpoint: try ForecastFeedEndpoint("zen.example.com"), transport: transport, now: { FeedFixtures.nowInstant })
        _ = try await client.fetchLatest()
        do {
            _ = try await client.fetchLatest()
            XCTFail("the implausible document was accepted")
        } catch {
            XCTAssertEqual(error, .invalidDocument(.implausibleForecast(field: "predictions.zen.5", value: 0)))
        }
        do {
            _ = try await client.fetchLatest()
            XCTFail("a 304 after a rejected document returned a value")
        } catch {
            XCTAssertEqual(error, .notModifiedWithoutCachedValue)
        }
        let conditions = await transport.ifNoneMatchHeaders()
        XCTAssertEqual(conditions, [nil, "\"good\"", nil], "the request after a rejection must be unconditional")
    }

    func test_S1_rejectedDocumentIsNeverServedLaterWhenFetchesOverlap() async throws {
        // Review of 79c2c40, m1, scenario 2: with the old document remembered, two fetches overlap;
        // the one answered first gets a rejected document and the other a 304 for the old ETag.
        // Before the fix the 304 returned the old document and remembered it again. Now the second
        // fetch joins the first (one request), and nothing returns a value after the rejection.
        let old = FeedFixtures.latestBody(runAt: now.addingTimeInterval(-14 * minute), zen5: 111)
        let bad = FeedFixtures.latestBody(runAt: now.addingTimeInterval(-1 * minute), zen5: 9_999)
        let transport = GatedTransport()
        let client = ForecastFeedClient(endpoint: try ForecastFeedEndpoint("zen.example.com"), transport: transport, now: { FeedFixtures.nowInstant })
        let first = Task { try await client.fetchLatest() }
        await transport.waitUntilSent(1)
        await transport.answer(0, with: ForecastHTTPResponse(statusCode: 200, eTag: "\"E1\"", body: old))
        _ = try await first.value

        let a = Task { try await client.fetchLatest() }
        await transport.waitUntilSent(2)
        let b = Task { try await client.fetchLatest() }
        for _ in 0..<1_000 { await Task.yield() }   // give b every chance to send its own request
        // Answer newest first: the rejected document, then 304 "unchanged since E1" to the rest.
        await transport.answerAll(expecting: 2) { _, answeredBefore in
            answeredBefore == 0
                ? ForecastHTTPResponse(statusCode: 200, eTag: "\"BAD\"", body: bad)
                : ForecastHTTPResponse(statusCode: 304, eTag: "\"E1\"", body: Data())
        }
        for (name, task) in [("a", a), ("b", b)] {
            if case .success(let value) = await task.result {
                XCTFail("\(name) returned a document after a rejection: zen 5 = \(String(describing: value.zen?.point(at: .fiveMinutes)?.predictedMgdl))")
            }
        }
        let most = await transport.mostOutstanding
        XCTAssertEqual(most, 1, "one request per URL at a time")

        // The next request is unconditional, so no 304 can restore the pre-rejection document.
        let index = await transport.sent.count
        let next = Task { try await client.fetchLatest() }
        await transport.waitUntilSent(index + 1)
        let condition = await transport.sent[index]
        XCTAssertNil(condition, "the request after a rejection must be unconditional")
        await transport.answer(index, with: ForecastHTTPResponse(statusCode: 304, eTag: "\"E1\"", body: Data()))
        do {
            _ = try await next.value
            XCTFail("a 304 after a rejection returned a value")
        } catch {
            XCTAssertEqual(error as? ForecastFeedError, .notModifiedWithoutCachedValue)
        }
    }

    func test_S1_overlappingFetchesNeverReturnAnOlderDocumentAfterANewerOne() async throws {
        // Review of 79c2c40, m1, scenario 1: with the old document remembered (E1), two fetches
        // overlap; the one answered first gets a newer document (E2), the other a 304 for E1.
        // Before the fix the 304 then returned (and remembered) the older document.
        let old = FeedFixtures.latestBody(runAt: now.addingTimeInterval(-10 * minute), zen5: 111)
        let new = FeedFixtures.latestBody(runAt: now.addingTimeInterval(-1 * minute), zen5: 222)
        let transport = GatedTransport()
        let client = ForecastFeedClient(endpoint: try ForecastFeedEndpoint("zen.example.com"), transport: transport, now: { FeedFixtures.nowInstant })
        let first = Task { try await client.fetchLatest() }
        await transport.waitUntilSent(1)
        await transport.answer(0, with: ForecastHTTPResponse(statusCode: 200, eTag: "\"E1\"", body: old))
        _ = try await first.value

        let a = Task { try await client.fetchLatest() }
        await transport.waitUntilSent(2)
        let b = Task { try await client.fetchLatest() }
        for _ in 0..<1_000 { await Task.yield() }
        await transport.answerAll(expecting: 2) { _, answeredBefore in
            answeredBefore == 0
                ? ForecastHTTPResponse(statusCode: 200, eTag: "\"E2\"", body: new)
                : ForecastHTTPResponse(statusCode: 304, eTag: "\"E1\"", body: Data())
        }
        for (name, task) in [("a", a), ("b", b)] {
            let value = try await task.value
            XCTAssertEqual(value.zen?.point(at: .fiveMinutes)?.predictedMgdl, 222, "\(name) returned the older document")
        }
        let most = await transport.mostOutstanding
        XCTAssertEqual(most, 1, "one request per URL at a time")

        let index = await transport.sent.count
        let next = Task { try await client.fetchLatest() }
        await transport.waitUntilSent(index + 1)
        let condition = await transport.sent[index]
        XCTAssertEqual(condition, "\"E2\"", "the client must remember the newest document's ETag")
        await transport.answer(index, with: ForecastHTTPResponse(statusCode: 304, eTag: "\"E2\"", body: Data()))
        let latest = try await next.value
        XCTAssertEqual(latest.zen?.point(at: .fiveMinutes)?.predictedMgdl, 222)
    }

    // MARK: - S3: no assumed timestamps

    func test_S3_orefForecastIsNotGivenTheZenRunTime() throws {
        // The feed does not publish when oref ran, so OrefForecast carries no date at all rather
        // than borrowing `generated_at` (which is the Zen run's time).
        let latest = try decodeLatest(try FeedFixtures.data("synthetic_latest_lagging_run"), at: FeedFixtures.instant(FeedFixtures.october8(14, 33)))
        let oref = try XCTUnwrap(latest.oref)
        let dates = Mirror(reflecting: oref).children.filter { $0.value is Date || $0.value is Date? }
        XCTAssertTrue(dates.isEmpty, "OrefForecast must not hold a timestamp the feed does not publish")
        for point in oref.points {
            XCTAssertTrue(Mirror(reflecting: point).children.allSatisfy { !($0.value is Date) })
        }
    }

    // MARK: - S4: LOW and HIGH stay flags; the model's clip edges stay bounds

    func test_S4_feedLowAndHighAreFlagsNotNumbers() throws {
        let low = try decodeLatest(
            FeedFixtures.json(FeedFixtures.setting(["bg", "mg_dl"], to: 39, in: FeedFixtures.latestObject())), at: FeedFixtures.nowInstant)
        XCTAssertEqual(low.feedGlucose?.value, .belowRange)
        XCTAssertNotEqual(low.feedGlucose?.value, .mgdl(39))
        XCTAssertNotEqual(low.feedGlucose?.value, .mgdl(40))

        let high = try decodeLatest(
            FeedFixtures.json(FeedFixtures.setting(["bg", "mg_dl"], to: 401, in: FeedFixtures.latestObject())), at: FeedFixtures.nowInstant)
        XCTAssertEqual(high.feedGlucose?.value, .aboveRange)
        XCTAssertNotEqual(high.feedGlucose?.value, .mgdl(400))
        XCTAssertNotEqual(high.feedGlucose?.value, .mgdl(401))

        // A Dexcom error code stored as an entry is not glucose either.
        let code = try decodeLatest(
            FeedFixtures.json(FeedFixtures.setting(["bg", "mg_dl"], to: 9, in: FeedFixtures.latestObject())), at: FeedFixtures.nowInstant)
        XCTAssertEqual(code.feedGlucose?.value, .notGlucose(code: 9))
    }

    func test_S4_forecastAtTheModelsClipIsABoundNotANumber() throws {
        // zen-predict clips to 40…400 (model.py:34-35): 40 means "40 or lower", 400 "400 or higher".
        var object = FeedFixtures.setting(["predictions", "zen"], to: ["5": 40, "30": 40.01, "60": 399.99, "120": 400], in: FeedFixtures.latestObject())
        object = FeedFixtures.setting(["predictions", "oref"], to: ["5": 39, "30": 120, "60": 401, "120": 650], in: object)
        let latest = try decodeLatest(FeedFixtures.json(object), at: FeedFixtures.nowInstant)
        let run = try XCTUnwrap(latest.currentRun(at: FeedFixtures.nowInstant))
        XCTAssertEqual(run.points.map(\.modelBound), [.atOrBelowFloor, .within, .within, .atOrAboveCeiling])
        XCTAssertEqual(try XCTUnwrap(latest.oref).points.map(\.modelBound), [.atOrBelowFloor, .within, .atOrAboveCeiling, .atOrAboveCeiling])
        // Values the decoder lets through beyond the clip (20…600) are bounds too.
        object = FeedFixtures.setting(["predictions", "zen"], to: ["5": 20, "30": 39.99, "60": 400.01, "120": 600], in: FeedFixtures.latestObject())
        let beyond = try XCTUnwrap(try decodeLatest(FeedFixtures.json(object), at: FeedFixtures.nowInstant).currentRun(at: FeedFixtures.nowInstant))
        XCTAssertEqual(beyond.points.map(\.modelBound), [.atOrBelowFloor, .atOrBelowFloor, .atOrAboveCeiling, .atOrAboveCeiling])
        XCTAssertEqual(ForecastLimits.zenModelClip, 40...400)
    }
}
