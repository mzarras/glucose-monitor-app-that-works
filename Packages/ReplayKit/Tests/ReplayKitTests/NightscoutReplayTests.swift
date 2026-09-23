#if DEBUG
import GlucoseCore
import XCTest
@testable import ReplayKit

/// Fixtures/nightscout-entries.json (synthetic, newest first, 25 entries):
///   Segment A from 2026-01-10T08:00Z: 352, 371, 389, 401 (HIGH), 401 (HIGH), 396, 380 (+ an exact
///   duplicate from a second uploader), an mbg entry, 362 at 08:35; a hole 08:40–09:05; 301 at
///   09:10, 287.6 at 09:15; a cal entry.
///   Segment B from 14:00Z: 96, 84, 72, 61, 50, 42, 39 (LOW), 10 (error code), 44, 58, 75 at 14:50;
///   one sgv entry without a `date`.
final class NightscoutReplayTests: XCTestCase {
    private let segmentA = Date(timeIntervalSince1970: 1_768_032_000) // 2026-01-10T08:00:00Z
    private var segmentB: Date { segmentA.addingTimeInterval(6 * 3_600) }
    private let minute: TimeInterval = 60

    private func export() throws -> NightscoutExport {
        try NightscoutExport.parse(fixtureExportData())
    }

    private func play(_ source: NightscoutReplaySource) async throws -> [GlucoseReading] {
        try await source.start(pairingCode: nil)
        await source.waitForPlayback()
        var readings = source.readings.makeAsyncIterator()
        return await readings.next(source.timeline.readingsInDeliveryOrder.count)
    }

    func test_parsesTheFixture() throws {
        let export = try export()
        XCTAssertEqual(export.entries.count, 20)
        XCTAssertEqual(export.ignoredNonSGVCount, 2, "mbg + cal")
        XCTAssertEqual(export.skippedErrorCodeCount, 1, "sgv 10")
        XCTAssertEqual(export.skippedMalformedCount, 1, "no date")
        XCTAssertEqual(export.droppedDuplicateDateCount, 1, "second uploader")
        XCTAssertEqual(export.entries.first?.date, segmentA)
        XCTAssertEqual(export.entries.last?.date, segmentB.addingTimeInterval(50 * minute))
        XCTAssertEqual(export.entries.map(\.date), export.entries.map(\.date).sorted())
    }

    func test_S4_nightscoutLowAndHighConventionsMapToFlags() {
        let cases: [(Double, GlucoseValue?)] = [
            (0, nil), (1, nil), (10, nil), (12, nil), (38, nil), (38.9, nil), // error codes
            (39, .belowRange), (39.5, .belowRange),                          // LOW
            (40, .mgdl(40)), (104.4, .mgdl(104)), (104.6, .mgdl(105)), (400, .mgdl(400)),
            (400.4, .aboveRange), (401, .aboveRange), (500, .aboveRange),    // HIGH
        ]
        for (sgv, expected) in cases {
            XCTAssertEqual(NightscoutExport.glucoseValue(sgv: sgv), expected, "sgv \(sgv)")
        }
    }

    func test_S4_fixtureFlagsSurviveReplayAsFlags() async throws {
        let export = try export()
        let source = try NightscoutReplaySource(export: export, origin: segmentA, clock: ImmediateReplayClock(start: segmentA))
        let readings = try await play(source)

        XCTAssertEqual(readings.filter { $0.value == .aboveRange }.map(\.date), [15, 20].map { segmentA.addingTimeInterval(TimeInterval($0) * minute) })
        XCTAssertEqual(readings.filter { $0.value == .belowRange }.map(\.date), [segmentB.addingTimeInterval(30 * minute)])
        let numbers = readings.compactMap(\.value.numericMgdl)
        XCTAssertFalse(numbers.contains(39) || numbers.contains(401) || numbers.contains(10))
        XCTAssertTrue(numbers.allSatisfy { GlucoseValue.sensorReportableRange.contains($0) })
        XCTAssertEqual(readings.first { $0.date == segmentA.addingTimeInterval(75 * minute) }?.value, .mgdl(288))
    }

    func test_S1_replayEmitsOnlyExportedReadingsAndGapsStayGaps() async throws {
        let export = try export()
        let source = try NightscoutReplaySource(export: export, origin: segmentA, clock: ImmediateReplayClock(start: segmentA))
        let readings = try await play(source)

        XCTAssertEqual(readings.map(\.date), export.entries.map(\.date))
        XCTAssertEqual(readings.map(\.value), export.entries.map(\.value))
        let emitted = await source.emittedReadings
        XCTAssertEqual(emitted.count, 20, "nothing beyond the export")
        let inHole = readings.filter { $0.date > segmentA.addingTimeInterval(35 * minute) && $0.date < segmentA.addingTimeInterval(70 * minute) }
        XCTAssertEqual(inHole, [])
        let betweenSegments = readings.filter { $0.date > segmentA.addingTimeInterval(75 * minute) && $0.date < segmentB }
        XCTAssertEqual(betweenSegments, [])
    }

    func test_S2_everyNightscoutReadingPassesTheReplayGate() throws {
        let export = try export()
        for origin in [segmentA, fractionalOrigin] {
            let source = try NightscoutReplaySource(export: export, origin: origin, clock: ImmediateReplayClock(start: origin))
            let timeline = source.timeline
            XCTAssertTrue(timeline.session.isWellFormed)
            for delivery in timeline.deliveries {
                XCTAssertNoThrow(try LiveReadingGate.validateAllowingReplay(
                    delivery.reading, session: timeline.session, now: origin.addingTimeInterval(delivery.offset)
                ))
            }
        }
    }

    func test_S3_idsAreUniqueStableAndDerivedFromSessionTime() throws {
        let export = try export()
        let original = try NightscoutReplaySource(export: export, origin: segmentA, clock: ImmediateReplayClock(start: segmentA))
        let shifted = try NightscoutReplaySource(export: export, origin: fractionalOrigin, clock: ImmediateReplayClock(start: fractionalOrigin))
        let ids = original.timeline.readingsInDeliveryOrder.map(\.id)
        XCTAssertEqual(Set(ids).count, 20)
        XCTAssertEqual(ids, shifted.timeline.readingsInDeliveryOrder.map(\.id), "ids do not depend on the origin")
        // Session starts 1 h before the first entry; ids are milliseconds since the session start.
        XCTAssertEqual(ids.first, "REPLAY-NIGHTSCOUT:3600000")
        // Last entry 14:50Z = first + 6 h 50 min = 24 600 s, plus the 3 600 s lead-in.
        XCTAssertEqual(ids.last, "REPLAY-NIGHTSCOUT:28200000")
    }

    func test_S6_everyNightscoutReplayReadingIsReplay() async throws {
        let export = try export()
        let source = try NightscoutReplaySource(export: export, origin: segmentA, clock: ImmediateReplayClock(start: segmentA))
        let readings = try await play(source)
        XCTAssertEqual(readings.count, 20)
        XCTAssertTrue(readings.allSatisfy { $0.source == .replay && $0.sensorSerial == NightscoutReplaySource.serial })
        XCTAssertTrue(readings.allSatisfy { $0.trendRate == nil }, "no rate is invented from a direction name")
        XCTAssertFalse(readings.contains(where: \.isBackfill))
    }

    func test_originShiftKeepsSpacing() throws {
        let export = try export()
        let source = try NightscoutReplaySource(export: export, origin: testOrigin, clock: ImmediateReplayClock(start: testOrigin))
        let dates = source.timeline.readingsInDeliveryOrder.map(\.date)
        XCTAssertEqual(dates.first, testOrigin)
        let shift = testOrigin.timeIntervalSince(segmentA)
        XCTAssertEqual(dates, export.entries.map { $0.date.addingTimeInterval(shift) })
    }

    func test_stopThenStartKeepsDelivering() async throws {
        let export = try export()
        let clock = ManualReplayClock(start: segmentA)
        let source = try NightscoutReplaySource(export: export, origin: segmentA, clock: clock)
        let script = source.timeline.readingsInDeliveryOrder
        var readings = source.readings.makeAsyncIterator()

        try await source.start(pairingCode: nil)
        await clock.advance(to: segmentA.addingTimeInterval(10 * minute))
        let first = await readings.next(3)
        await source.stop()
        await clock.advance(to: segmentB.addingTimeInterval(60 * minute))
        try await source.start(pairingCode: nil)
        let rest = await readings.next(script.count - 3)
        XCTAssertEqual(first + rest, script)
    }

    func test_currentSessionEndsWhenReplayTimePassesTheGracePeriod() async throws {
        // No state event ends a Nightscout replay's session; replay time alone does (D28).
        let export = try export()
        let clock = ManualReplayClock(start: segmentA)
        let source = try NightscoutReplaySource(export: export, origin: segmentA, clock: clock)
        let session = source.timeline.session

        var current = await source.currentSession
        XCTAssertNil(current, "before the first start")
        try await source.start(pairingCode: nil)
        await source.stop()
        current = await source.currentSession
        XCTAssertEqual(current, session, "kept across a disconnect")

        await clock.advance(to: session.gracePeriodEndsAt)
        current = await source.currentSession
        XCTAssertEqual(current, session, "valid up to and including the end of the grace period")
        await clock.advance(by: 1)
        current = await source.currentSession
        XCTAssertNil(current, "ended after the grace period")
    }

    func test_backfillBurstOf288OverdueReadingsArrivesComplete() async throws {
        // A 24-hour export (288 entries) started a day late: every reading is overdue at start and
        // is delivered in one burst before the consumer reads anything.
        let start = segmentA
        let entries = (0..<288).map { index in
            "{\"type\":\"sgv\",\"sgv\":\(100 + index % 60),\"date\":\(Int64(start.timeIntervalSince1970 * 1000) + Int64(index) * 300_000)}"
        }
        let export = try NightscoutExport.parse(Data(("[" + entries.joined(separator: ",") + "]").utf8))
        let clock = ManualReplayClock(start: start)
        let source = try NightscoutReplaySource(export: export, origin: start, clock: clock)
        await clock.advance(by: 86_400)
        try await source.start(pairingCode: nil)
        await source.waitForPlayback()

        var readings = source.readings.makeAsyncIterator()
        let received = await readings.next(288)
        XCTAssertEqual(received, source.timeline.readingsInDeliveryOrder)
    }

    func test_rejectsInputThatIsNotAnArrayOrHasNoReadings() {
        XCTAssertThrowsError(try NightscoutExport.parse(Data("{\"sgv\": 100}".utf8))) { error in
            XCTAssertEqual(error as? NightscoutExport.ParseError, .notAJSONArray)
        }
        XCTAssertThrowsError(try NightscoutReplaySource(
            export: NightscoutExport.parse(Data("[{\"type\":\"mbg\",\"mbg\":100,\"date\":1}]".utf8)),
            origin: testOrigin, clock: ImmediateReplayClock(start: testOrigin)
        )) { error in
            XCTAssertEqual(error as? NightscoutReplaySource.ReplayError, .noReadings)
        }
    }

    func test_S3_entriesLessThanASecondApartStayDistinct() async throws {
        // Two uploaders posted the same reading 400 ms apart; a third copy has exactly the same
        // date as the first. The replay keeps the two distinct instants and drops (and counts) only
        // the exact duplicate.
        let json = """
            [{"type":"sgv","sgv":120,"date":1768032000000},
             {"type":"sgv","sgv":121,"date":1768032000400},
             {"type":"sgv","sgv":120,"date":1768032000000}]
            """
        let export = try NightscoutExport.parse(Data(json.utf8))
        XCTAssertEqual(export.droppedDuplicateDateCount, 1)
        let source = try NightscoutReplaySource(export: export, origin: segmentA, clock: ImmediateReplayClock(start: segmentA))
        let readings = try await play(source)
        XCTAssertEqual(readings.map(\.id), ["REPLAY-NIGHTSCOUT:3600000", "REPLAY-NIGHTSCOUT:3600400"])
        XCTAssertEqual(readings.map(\.value), [.mgdl(120), .mgdl(121)])
    }

    func test_numericStringsAreAcceptedAndBooleansAreNot() throws {
        let json = """
            [{"type":"sgv","sgv":"120","date":"1768032000000"},
             {"type":"sgv","sgv":true,"date":1768032300000}]
            """
        let export = try NightscoutExport.parse(Data(json.utf8))
        XCTAssertEqual(export.entries, [NightscoutExport.Entry(date: segmentA, value: .mgdl(120))])
        XCTAssertEqual(export.skippedMalformedCount, 1)
    }
}
#endif
