import XCTest
import GlucoseCore
@testable import AlertEngine

/// Safety review WS4 minors: launch reconcile, a 60-minute repeat horizon at every interval, the
/// wake-before-slot tolerance, and snapshot decoding that survives new or unknown fields.
@MainActor
final class LaunchAndSchedulingTests: XCTestCase {
    // MARK: Launch reconcile

    func test_launchRemovesLeftoverUrgentLowRepeatsWhenNotFiring() {
        let h = EngineHarness()
        let actions = h.send(.launched)
        XCTAssertEqual(actions.first, .cancelScheduled(.urgentLow))
    }

    func test_launchRebuildsUrgentLowRepeatsWhenFiring() throws {
        let h = EngineHarness()
        h.mgdl(50)
        let stored = try XCTUnwrap(AlertEngineSnapshot.decode(h.engine.snapshot.encoded()))
        let later = Fixtures.t0.addingTimeInterval(minutes(2))
        var engine = AlertEngine(settings: .defaults, configuration: Fixtures.configuration, restoring: stored, now: later)
        let actions = engine.handle(.launched, at: later)
        XCTAssertEqual(actions.scheduled(.urgentLow)?.first, Fixtures.t0.addingTimeInterval(minutes(5)))
        XCTAssertFalse(actions.contains(.cancelScheduled(.urgentLow)))
    }

    func test_launchRebuildsMissedReadingsNotifications() {
        let h = EngineHarness()
        h.mgdl(120)
        let actions = h.send(.launched)
        XCTAssertEqual(actions.first(where: { if case .cancelSlots(.missedReadings, _) = $0 { return true } else { return false } }),
                       .cancelSlots(.missedReadings, Array(0..<AlertLimits.scheduleIDCycle)), "every slot, whatever the old process left")
        XCTAssertEqual(actions.scheduled(.missedReadings)?.first, Fixtures.t0.addingTimeInterval(minutes(15)))
    }

    // MARK: Horizon

    func test_urgentLowRepeatsCoverAnHourWhateverTheInterval() {
        for repeatMinutes in 2...5 {
            var settings = AlertSettings.defaults
            settings.urgentLow.repeatMinutes = repeatMinutes
            let h = EngineHarness(settings: settings)
            let dates = h.mgdl(50).scheduled(.urgentLow) ?? []
            XCTAssertGreaterThanOrEqual(dates.last.map { $0.timeIntervalSince(h.now) } ?? 0, minutes(60), "every \(repeatMinutes) min")
            XCTAssertLessThanOrEqual(dates.count, AlertLimits.maximumScheduledSlots)
        }
        // Worst case pending: urgent low 30 + missed readings 12, under iOS's 64.
        XCTAssertLessThanOrEqual(AlertLimits.maximumScheduledSlots + AlertLimits.scheduledNotificationCount, 64)
    }

    // MARK: Wake-before-slot tolerance

    func test_aWakeJustBeforeARepeatSlotPlaysThatSlotsSoundOnce() {
        let h = EngineHarness()
        h.mgdl(50)
        h.clock.advance(minutes: 4.5)
        XCTAssertEqual(h.mgdl(49).due, [.urgentLow], "the G7 wake 30 s before the 5-minute slot plays it")
        h.clock.advance(minutes: 0.75)
        XCTAssertEqual(h.mgdl(49).due, [], "not again at the slot itself")
        h.clock.advance(minutes: 4.5)
        XCTAssertEqual(h.mgdl(48).due, [.urgentLow], "next slot, also slightly early")
        XCTAssertLessThanOrEqual(AlertLimits.repeatSlotEarlyTolerance, LiveReadingGate.futureTolerance)
    }

    func test_aWakeWellBeforeTheSlotDoesNotPlay() {
        let h = EngineHarness()
        h.mgdl(50)
        h.clock.advance(minutes: 3.9)
        XCTAssertEqual(h.mgdl(49).due, [])
    }

    // MARK: Snapshot decoding

    func test_snapshotWithMissingAndUnknownFieldsKeepsWhatItCanRead() throws {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.acknowledge(.urgentLow))
        let data = try XCTUnwrap(h.engine.snapshot.encoded())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["someFieldFromAFutureBuild"] = ["x": 1]
        object["missedReadingsReference"] = nil
        object["bridgeStatus"] = "not a status"
        var episodes = try XCTUnwrap(object["episodes"] as? [String: Any])
        episodes["low"] = ["someFutureCase": [:]]
        object["episodes"] = episodes
        let tampered = try JSONSerialization.data(withJSONObject: object)

        let snapshot = try XCTUnwrap(AlertEngineSnapshot.decode(tampered), "one bad field must not reset the engine")
        let later = Fixtures.t0.addingTimeInterval(minutes(1))
        let engine = AlertEngine(settings: .defaults, configuration: Fixtures.configuration, restoring: snapshot, now: later)
        XCTAssertEqual(engine.phase(of: .urgentLow), .snoozed(until: Fixtures.t0.addingTimeInterval(minutes(30))), "the acknowledgement survives")
        XCTAssertEqual(engine.phase(of: .low), .armed, "the unreadable episode is dropped")
        XCTAssertEqual(engine.snapshot.missedReadingsReference, later, "a missing reference restarts the window at restore")
        XCTAssertEqual(engine.snapshot.bridgeStatus, .off)
    }

    func test_snapshotThatIsNotAnObjectStartsFresh() {
        XCTAssertNil(AlertEngineSnapshot.decode(Data("[1,2]".utf8)))
    }
}
