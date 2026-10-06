// HANDOFF §10 gate 4 (the alert half; the UI half is SensorUITests): every ReplayKit scenario is
// played through the app's real replay wiring — `ReplayRun`: ReplaySource on a manual clock →
// separate replay store → the pipeline's gate (`validateAllowingReplay`, D11) → AlertService with
// the real AlertEngine and fake delivery ports — and alerts must fire when, and only when, the
// scenario's milestones say. The app is "awake" once a minute (the foreground ticker) and at every
// delivery. The Trio bridge and an uploader are real, over a fake App Group and a recording
// destination; they must receive nothing from replay (S6).
//
// Expected times come from the scenarios' own milestones (docs/replay.md), never from numbers
// copied into this file. Default alert settings, with the rise/fall alerts switched on.

#if DEBUG
import AlertEngine
import Foundation
import GlucoseCore
import NightscoutKit
import ReplayKit
import TrioBridge
import XCTest
@testable import Sensor

@MainActor
final class ReplayScenarioTests: XCTestCase {
    @MainActor
    private struct Run {
        let scenario: ReplayScenario
        let replay: ReplayRun
        let clock: PipelineTestClock
        let replayClock: ManualReplayClock
        let center: RecordingNotificationCenter
        let audio: RecordingAudioPlayer
        let recorder: AlertPhaseRecorder
        let trioStore: RecordingTrioStore
        let trio: TrioCoordinator
        let destination: RecordingUploadDestination
        let uploader: ReadingUploader

        var origin: Date { replay.origin }
        var timeline: ReplayTimeline { replay.source.timeline }

        func milestone(_ name: ScenarioMilestone) -> TimeInterval {
            guard let offset = scenario.milestones[name] else {
                XCTFail("\(scenario) has no milestone \(name)")
                return .nan
            }
            return offset
        }

        func date(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }

        /// When each immediate notification of `kind` was posted, as scenario offsets.
        func postedOffsets(_ kind: String) -> [TimeInterval] {
            center.posted(kind).map { $0.at.timeIntervalSince(origin) }
        }

        /// D43: when each sensor expiry reminder of `kind` reaches the person, as scenario offsets —
        /// posted at once (its moment had already passed when it became known), or a pending
        /// notification scheduled for its moment, which iOS posts even while the app is suspended.
        func reminderOffsets(_ kind: String) -> [TimeInterval] {
            (center.posted(kind).map(\.at) + center.pending(kind).compactMap(\.fireDate))
                .map { $0.timeIntervalSince(origin) }
                .sorted()
        }

        /// When the in-app (ringer-off) sound `file` played, as scenario offsets.
        func soundOffsets(_ file: String) -> [TimeInterval] {
            audio.plays.filter { $0.fileName == file }.map { $0.at.timeIntervalSince(origin) }
        }
    }

    /// 2030-01-01T00:00:00Z (1_893_456_000 s since 1970).
    private static let origin = Date(timeIntervalSince1970: 1_893_456_000)
    private var runs: [Run] = []

    override func tearDown() async throws {
        for run in runs { await run.replay.stop() }
        runs = []
    }

    /// - Parameter developerSwitchOn: D20. Off: the app attaches neither the Trio bridge nor an
    ///   uploader to a replay run. On: both are attached and must refuse every replay reading.
    private func start(_ scenario: ReplayScenario, developerSwitchOn: Bool = false) async throws -> Run {
        let clock = PipelineTestClock(Self.origin)
        let replayClock = ManualReplayClock(start: Self.origin)
        let diagnostics = CollectingDiagnosticLog()
        let center = RecordingNotificationCenter(clock: clock)
        let audio = RecordingAudioPlayer(clock: clock)
        let ports = AlertPorts(
            notificationCenter: center, audio: audio, alarms: nil,
            configuration: PipelineFixtures.utcConfiguration, diagnostics: diagnostics
        )
        let replay = try ReplayRun(
            scenario: scenario, origin: Self.origin, replayClock: replayClock, now: clock.closure,
            alertPorts: ports, settings: AlertPhaseRecorder.settingsWithRateAlerts, diagnostics: diagnostics
        )
        let trioStore = RecordingTrioStore()
        let trio = TrioCoordinator(appGroupID: "group.org.nightscout.ABCDE12345.trio.trio-app-group", store: trioStore, diagnostics: diagnostics, clock: clock.closure)
        trio.configure(enabled: true, liveOutputsAllowed: developerSwitchOn)
        let destination = RecordingUploadDestination()
        let queueFile = PipelineFixtures.temporaryDirectory().appendingPathComponent("replay-queue.json")
        let uploader = try ReadingUploader(destination: destination, queueFile: queueFile, clock: PipelineTestWallClock(clock: clock), log: diagnostics)
        // What LiveAppServices.attachOutputs does: the bridge only when allowed (D20), uploaders likewise.
        replay.pipeline.outputs.trio = trio
        if developerSwitchOn {
            replay.pipeline.outputs.uploaders = { [uploader] }
        }
        await replay.start()
        let run = Run(
            scenario: scenario, replay: replay, clock: clock, replayClock: replayClock, center: center, audio: audio,
            recorder: AlertPhaseRecorder(), trioStore: trioStore, trio: trio, destination: destination, uploader: uploader
        )
        runs.append(run)
        return run
    }

    /// Plays the scenario minute by minute up to `endOffset` (inclusive). Each minute: move both
    /// clocks, wait until the pipeline has handled everything delivered so far, tick the alert
    /// service (the app is awake), record the alert phases, then run `atMinute`.
    private func play(_ run: Run, through endOffset: TimeInterval, atMinute: (TimeInterval) async -> Void = { _ in }) async {
        var offset: TimeInterval = 0
        while offset <= endOffset {
            let date = run.date(offset)
            run.clock.set(date)
            await run.replayClock.advance(to: date)
            let readings = run.timeline.deliveries.filter { $0.offset <= offset }.count
            let states = 1 + run.timeline.stateChanges.filter { $0.offset <= offset }.count
            let pipeline = run.replay.pipeline
            await waitUntil("\(run.scenario) at +\(Int(offset / 60)) min: \(readings) readings, \(states) states") {
                pipeline.receivedReadingCount == readings && pipeline.receivedStateCount == states && pipeline.isIdle
            }
            await run.replay.alerts.send(.tick)
            run.recorder.record(run.replay.alerts, offset: offset)
            await atMinute(offset)
            offset += 60
        }
    }

    /// S6: nothing from a replay run reached Trio's App Group or an upload destination.
    private func assertNothingReachedTrioOrUploads(_ run: Run, file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertEqual(run.trioStore.writesOfReadings, 0, "replay reached Trio", file: file, line: line)
        XCTAssertTrue(run.trioStore.payload.isEmpty, file: file, line: line)
        XCTAssertNil(run.trioStore.string(forKey: TrioAppGroupContract.heartbeatDeviceAddressKey), file: file, line: line)
        _ = await run.uploader.flush()
        XCTAssertTrue(run.destination.uploaded.isEmpty, "replay reached an upload destination", file: file, line: line)
        let queueDepth = await run.uploader.status.queueDepth
        XCTAssertEqual(queueDepth, 0, file: file, line: line)
    }

    // MARK: - steady

    /// Warm-up, then in range: the only notice is "warm-up complete" when the sensor becomes active;
    /// missed readings stays quiet through warm-up and fires only 15 min after the last reading.
    func test_steady_onlyWarmUpNoticeThenMissedReadingsAfterTheLastReading() async throws {
        let run = try await start(.steady)
        let warmUpEnds = run.milestone(.warmUpEnds)
        let lastReading = run.milestone(.lastReading)
        await play(run, through: lastReading + 20 * 60)

        XCTAssertEqual(run.center.posted.map(\.kind), ["sensorWarmUpComplete"], "steady must raise nothing but the warm-up notice")
        XCTAssertEqual(run.postedOffsets("sensorWarmUpComplete"), [warmUpEnds])
        XCTAssertEqual(run.recorder.kindsThatFired, ["missedReadings"])
        XCTAssertEqual(run.recorder.firingOffsets["missedReadings"]?.min(), lastReading + 15 * 60,
                       "missed readings fires 15 min after the last reading, never during warm-up")
        await assertNothingReachedTrioOrUploads(run)
    }

    // MARK: - slowFallToUrgentLow

    /// Low at the first ≤ 70, urgent low at the first ≤ 55 (low superseded), urgent low repeating
    /// every 5 min until acknowledged, then silent for its ≤ 30-min snooze through the LOW flags;
    /// no rate or high alert; missed readings only after the last reading.
    func test_slowFallToUrgentLow_lowThenUrgentLowRepeatingUntilAcknowledged() async throws {
        let run = try await start(.slowFallToUrgentLow)
        let firstLow = run.milestone(.firstAtOrBelow70)
        let firstUrgent = run.milestone(.firstAtOrBelow55)
        let firstLowFlag = run.milestone(.firstLowFlag)
        let lastReading = run.milestone(.lastReading)
        let backAbove55 = run.milestone(.backAbove55)
        let acknowledgedAt = firstUrgent + 16 * 60
        let snoozeEnd = acknowledgedAt + 30 * 60
        var pendingUrgentLowAfterAcknowledge: [NotificationRequestSpec] = []
        var pendingUrgentLowAfterRecovery: [NotificationRequestSpec]?

        await play(run, through: lastReading + 20 * 60) { offset in
            if offset == acknowledgedAt {
                await AlertPhaseRecorder.acknowledgeUrgentLow(run.replay.alerts)
                pendingUrgentLowAfterAcknowledge = run.center.pending("urgentLow")
            }
            if offset == backAbove55 {
                pendingUrgentLowAfterRecovery = run.center.pending("urgentLow")
            }
        }

        // Low: first at the first reading ≤ 70, never earlier.
        XCTAssertEqual(run.recorder.firingOffsets["low"]?.min(), firstLow)
        XCTAssertEqual(run.recorder.episodeStarts["low"]?.first, run.date(firstLow))
        XCTAssertEqual(run.postedOffsets("low").first, firstLow)

        // Urgent low: first at the first reading ≤ 55, never earlier; one episode.
        XCTAssertEqual(run.recorder.firingOffsets["urgentLow"]?.min(), firstUrgent)
        XCTAssertEqual(run.recorder.episodeStarts["urgentLow"], [run.date(firstUrgent)])
        XCTAssertEqual(run.postedOffsets("urgentLow"), [firstUrgent])

        // Supersession: low never sounds while urgent low is firing or snoozed.
        for offset in (run.recorder.firingOffsets["urgentLow"] ?? []) + (run.recorder.snoozedOffsets["urgentLow"] ?? []) {
            XCTAssertFalse(run.recorder.isFiring("low", at: offset), "low firing at +\(Int(offset / 60)) during urgent low")
        }

        // Repeats every 5 min (default) until acknowledged: the in-app sound at each slot.
        let cascade = run.soundOffsets(AlertSoundCatalog.fileName(.cascade))
        for slot in stride(from: firstUrgent, to: acknowledgedAt, by: 5 * 60) {
            XCTAssertTrue(cascade.contains { abs($0 - slot) <= 60 }, "urgent low did not repeat at +\(Int(slot / 60)) min")
        }
        // Acknowledged: the pending repeats are replaced by the snooze-end series (D44) — nothing
        // pending before the snooze end, exactly one urgent-low alarm at it — and it stays silent for
        // the snooze (≤ 30 min, S7), also through the LOW flags.
        let pendingDates = pendingUrgentLowAfterAcknowledge.compactMap(\.fireDate)
        XCTAssertEqual(pendingDates.count, pendingUrgentLowAfterAcknowledge.count, "every pending urgent-low notification is scheduled")
        XCTAssertFalse(pendingDates.isEmpty)
        XCTAssertTrue(pendingDates.allSatisfy { $0 >= run.date(snoozeEnd) }, "acknowledge must remove the pending repeats before the snooze end: \(pendingDates)")
        XCTAssertEqual(pendingDates.filter { $0 == run.date(snoozeEnd) }.count, 1, "D44: exactly one urgent-low alarm at the snooze end")
        XCTAssertGreaterThan(firstLowFlag, acknowledgedAt)
        XCTAssertFalse(cascade.contains { $0 > acknowledgedAt && $0 < snoozeEnd }, "urgent low sounded during its snooze")
        XCTAssertTrue(run.recorder.snoozedOffsets["urgentLow"]?.contains(firstLowFlag) ?? false)

        // The run passes the snooze end, but glucose is back above 55 one minute before it (60 at
        // +130, snooze end +131). That reading removes the grid after the snooze end (D44); the
        // snooze-end alarm itself is due within AlertLimits.protectedLeadTime (60 s), and an alarm
        // that may be about to ring is never cancelled (WS4 B2), so it stays pending and iOS posts it
        // at +131. In the app nothing sounds after the acknowledge and the single episode is not
        // restarted. The case where the snooze ends while still low is
        // test_slowFallToUrgentLow_snoozeEndingWhileStillLowSoundsAgain.
        XCTAssertGreaterThan(lastReading + 20 * 60, snoozeEnd, "the run reaches the snooze end")
        XCTAssertEqual(snoozeEnd - backAbove55, 60)
        XCTAssertEqual(pendingUrgentLowAfterRecovery?.compactMap(\.fireDate), [run.date(snoozeEnd)],
                       "a reading above the threshold removes the grid; only the protected snooze-end alarm is left (D44)")
        XCTAssertFalse(cascade.contains { $0 > acknowledgedAt }, "urgent low sounded in the app after the acknowledge although glucose recovered before the snooze end")

        // Nothing else: no rate alert (|rate| < 3), no high, no urgent-low-soon (off), no sensor alert.
        XCTAssertEqual(run.recorder.kindsThatFired, ["low", "urgentLow", "missedReadings"])
        XCTAssertEqual(Set(run.center.posted.map(\.kind)), ["low", "urgentLow"])
        XCTAssertEqual(run.recorder.firingOffsets["missedReadings"]?.min(), lastReading + 15 * 60)
        await assertNothingReachedTrioOrUploads(run)
    }

    /// D44: acknowledged early, the snooze ends while the sensor still reads LOW. The snooze-end alarm
    /// was pending since the acknowledge, so it is the sounding at the snooze end (no new post), the
    /// episode resumes from the snooze end and repeats until glucose is back above 55.
    func test_slowFallToUrgentLow_snoozeEndingWhileStillLowSoundsAgain() async throws {
        let run = try await start(.slowFallToUrgentLow)
        let firstUrgent = run.milestone(.firstAtOrBelow55)
        let firstLowFlag = run.milestone(.firstLowFlag)
        let backAbove55 = run.milestone(.backAbove55)
        let lastReading = run.milestone(.lastReading)
        let acknowledgedAt = firstUrgent + 60
        let snoozeEnd = acknowledgedAt + 30 * 60
        // The premise: the latest reading at the snooze end is still urgent low (a LOW flag at +115).
        XCTAssertGreaterThan(snoozeEnd, firstLowFlag)
        XCTAssertLessThan(snoozeEnd, backAbove55)
        var pendingAtSnoozeEnd = 0

        await play(run, through: lastReading + 20 * 60) { offset in
            if offset == acknowledgedAt {
                await AlertPhaseRecorder.acknowledgeUrgentLow(run.replay.alerts)
            }
            if offset == snoozeEnd - 60 {
                pendingAtSnoozeEnd = run.center.pending("urgentLow").filter { $0.fireDate == run.date(snoozeEnd) }.count
            }
        }

        let cascade = run.soundOffsets(AlertSoundCatalog.fileName(.cascade))
        XCTAssertEqual(pendingAtSnoozeEnd, 1, "the snooze-end alarm stays pending through the low readings (D44)")
        XCTAssertFalse(cascade.contains { $0 > acknowledgedAt && $0 < snoozeEnd }, "silent during the snooze (S7 ≤ 30 min)")
        XCTAssertTrue(cascade.contains { abs($0 - snoozeEnd) <= 60 }, "D44: urgent low sounds again at the snooze end")
        for slot in stride(from: snoozeEnd + 5 * 60, to: backAbove55, by: 5 * 60) {
            XCTAssertTrue(cascade.contains { abs($0 - slot) <= 60 }, "urgent low did not repeat at +\(Int(slot / 60)) min after the snooze end")
        }
        XCTAssertFalse(cascade.contains { $0 > backAbove55 }, "nothing after glucose is back above 55")
        XCTAssertEqual(run.recorder.episodeStarts["urgentLow"], [run.date(firstUrgent), run.date(snoozeEnd)],
                       "the episode resumes from the snooze end")
        XCTAssertEqual(run.postedOffsets("urgentLow"), [firstUrgent], "the snooze-end sounding is the pending alarm, not a second post")
        await assertNothingReachedTrioOrUploads(run)
    }

    // MARK: - compressionLowSpike

    /// A fast fall, low, urgent low, then a fast rise back into range: each alert at its milestone,
    /// urgent low repeating while ≤ 55 and ending when glucose recovers.
    func test_compressionLowSpike_rateLowAndUrgentLowAtTheirMilestones() async throws {
        let run = try await start(.compressionLowSpike)
        let fallRate = run.milestone(.firstFallRateAtLeast3)
        let firstLow = run.milestone(.firstAtOrBelow70)
        let firstUrgent = run.milestone(.firstAtOrBelow55)
        let recovered = run.milestone(.backAbove55)
        let riseRate = run.milestone(.firstRiseRateAtLeast3)
        let lastReading = run.milestone(.lastReading)
        await play(run, through: lastReading + 20 * 60)

        XCTAssertEqual(run.recorder.firingOffsets["fallingFast"]?.min(), fallRate)
        XCTAssertEqual(run.recorder.firingOffsets["low"]?.min(), firstLow)
        XCTAssertEqual(run.recorder.firingOffsets["urgentLow"]?.min(), firstUrgent)
        XCTAssertEqual(run.recorder.firingOffsets["risingFast"]?.min(), riseRate)
        XCTAssertEqual(run.recorder.episodeStarts["urgentLow"], [run.date(firstUrgent)])

        // Urgent low repeats while ≤ 55 and ends at the recovery reading.
        let cascade = run.soundOffsets(AlertSoundCatalog.fileName(.cascade))
        for slot in stride(from: firstUrgent, to: recovered, by: 5 * 60) {
            XCTAssertTrue(cascade.contains { abs($0 - slot) <= 60 }, "urgent low did not repeat at +\(Int(slot / 60)) min")
        }
        XCTAssertFalse(run.recorder.isFiring("urgentLow", at: recovered))
        XCTAssertFalse(cascade.contains { $0 > recovered + 60 }, "urgent low sounded after glucose recovered")
        XCTAssertTrue(run.center.pending("urgentLow").isEmpty, "recovery must remove the pending repeats")
        for offset in run.recorder.firingOffsets["urgentLow"] ?? [] {
            XCTAssertFalse(run.recorder.isFiring("low", at: offset))
        }

        XCTAssertEqual(run.recorder.kindsThatFired, ["fallingFast", "low", "urgentLow", "risingFast", "missedReadings"])
        XCTAssertEqual(run.recorder.firingOffsets["missedReadings"]?.min(), lastReading + 15 * 60)
        await assertNothingReachedTrioOrUploads(run)
    }

    // MARK: - signalGapWithBackfill

    /// 45 minutes without a delivery: missed readings fires 15 min after the last reading (not
    /// before), stays until live readings resume, and the backfilled readings (stored with their
    /// own timestamps, S3) raise nothing.
    func test_signalGapWithBackfill_missedReadingsDuringTheGapOnly() async throws {
        let run = try await start(.signalGapWithBackfill)
        let lastBeforeGap = run.milestone(.lastReadingBeforeGap)
        let resumed = run.milestone(.liveReadingsResume)
        let lastReading = run.milestone(.lastReading)
        await play(run, through: lastReading + 20 * 60)

        let missed = run.recorder.firingOffsets["missedReadings"] ?? []
        XCTAssertEqual(missed.min(), lastBeforeGap + 15 * 60, "missed readings must fire 15 min after the last reading, not before")
        for offset in stride(from: lastBeforeGap + 15 * 60, to: resumed, by: 60) {
            XCTAssertTrue(missed.contains(offset), "missed readings not firing at +\(Int(offset / 60)) min in the gap")
        }
        XCTAssertFalse(missed.contains { $0 >= resumed && $0 < lastReading + 15 * 60 }, "missed readings still firing after readings resumed")
        XCTAssertEqual(run.recorder.kindsThatFired, ["missedReadings"])
        XCTAssertTrue(run.center.posted.isEmpty, "the gap and its backfill raise nothing but missed readings")

        // Every delivered reading is stored once; the backfill keeps its flag and timestamps (S3).
        let stored = try await run.replay.store.readings(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(stored.count, run.timeline.deliveries.count)
        XCTAssertEqual(stored.filter(\.isBackfill).count, run.timeline.deliveries.filter { $0.reading.isBackfill }.count)
        XCTAssertEqual(stored.map(\.date), stored.map(\.date).sorted())
        await assertNothingReachedTrioOrUploads(run)
    }

    // MARK: - sensorExpiry

    /// Expiring (2-hour notice) at once, grace period at its start, high at the first ≥ 250 and
    /// through the HIGH flags as one episode until it recovers, expired at the end; no rate alert.
    /// Played to 20 min after the end: missed readings stays quiet after the confirmed end while the
    /// sensor-expired alert is on (D41), although no reading arrives for 25 minutes.
    func test_sensorExpiry_noticesHighAndExpiredAtTheirMilestones() async throws {
        let run = try await start(.sensorExpiry)
        let graceStarts = run.milestone(.gracePeriodStarts)
        let firstHigh = run.milestone(.firstAtOrAbove250)
        let firstHighFlag = run.milestone(.firstHighFlag)
        let backBelow = run.milestone(.backBelow250)
        let lastReading = run.milestone(.lastReading)
        let expired = run.milestone(.expired)
        await play(run, through: expired + 20 * 60)

        XCTAssertEqual(run.reminderOffsets("sensorExpiringIn2Hours"), [0], "the sensor expires 30 min after the start: one 2-hour notice")
        XCTAssertTrue(run.reminderOffsets("sensorExpiringIn24Hours").isEmpty, "the 2-hour notice replaces the 24-hour one")
        XCTAssertTrue(run.reminderOffsets("sensorExpiringIn12Hours").isEmpty, "the 2-hour notice replaces the 12-hour one (D43)")
        // D43: the grace-start reminder is scheduled ahead for its moment.
        XCTAssertEqual(run.reminderOffsets("sensorGracePeriod"), [graceStarts])

        XCTAssertEqual(run.recorder.firingOffsets["high"]?.min(), firstHigh)
        XCTAssertEqual(run.recorder.episodeStarts["high"], [run.date(firstHigh)], "the HIGH flags are the same high episode (S4)")
        XCTAssertTrue(run.recorder.isFiring("high", at: firstHighFlag))
        XCTAssertFalse(run.recorder.firingOffsets["high"]?.contains { $0 >= backBelow } ?? true, "high must clear when glucose is back below 250")
        XCTAssertFalse(run.postedOffsets("high").contains { $0 < firstHigh || $0 >= backBelow })

        XCTAssertEqual(run.recorder.firingOffsets["sensorExpired"]?.min(), expired)
        // D43, review m10: at the end, "Sensor expired" plays its sound in-app (sound on silent is on
        // by default), and there is exactly one expired notification for that moment — already
        // delivered from the reminder scheduled for the grace end, or posted then. The test asserts
        // the outcome, not which of the two mechanisms produced it.
        XCTAssertTrue(run.soundOffsets(AlertSoundCatalog.fileName(.warble)).contains(expired), "the expired alert's sound plays at the end")
        XCTAssertEqual(run.reminderOffsets("sensorExpired"), [expired], "exactly one expired notification, for the end")
        XCTAssertTrue(run.recorder.isFiring("sensorExpired", at: expired + 20 * 60), "the sensor alert stays until a new sensor")
        // D41: after the confirmed end the expired alert speaks; missed readings does not add to it,
        // although the last reading is now 25 minutes old (it would fire at +15 min otherwise).
        XCTAssertGreaterThan(expired + 20 * 60, lastReading + 15 * 60)
        XCTAssertNil(run.recorder.firingOffsets["missedReadings"], "missed readings must stay quiet after the confirmed end (D41)")
        XCTAssertEqual(run.recorder.kindsThatFired, ["high", "sensorExpired"])
        await assertNothingReachedTrioOrUploads(run)
    }

    // MARK: - S6

    /// With the D20 developer switch on, the Trio bridge and an uploader are attached to a replay
    /// run — and still receive nothing: both refuse every replay reading with their own sensor-only
    /// gate, and the bridge is given no session, so Trio's App Group is never touched.
    func test_S6_replayNeverReachesTrioOrUploads() async throws {
        let run = try await start(.slowFallToUrgentLow, developerSwitchOn: true)
        XCTAssertNotNil(run.replay.pipeline.outputs.trio)
        XCTAssertEqual(run.replay.pipeline.outputs.uploaders?().count, 1)
        let lastReading = run.milestone(.lastReading)
        await play(run, through: lastReading)

        // The alert engine did get them (D11), so the run really delivered readings.
        XCTAssertFalse(run.center.posted("urgentLow").isEmpty)
        await assertNothingReachedTrioOrUploads(run)
        let trioStatus = await run.trio.bridge!.status
        XCTAssertEqual(trioStatus.lastGateRefusal?.reason, .gate(.notLiveSensor(.replay)))
        XCTAssertNil(trioStatus.lastSuccessfulWriteAt, "the bridge wrote nothing")
        XCTAssertFalse(trioStatus.isStarving(), "replay readings are not live readings Trio is missing")
        let uploadStatus = await run.uploader.status
        XCTAssertEqual(uploadStatus.refusedByGate, run.timeline.deliveries.count)
        if case .gate(.notLiveSensor(.replay)) = uploadStatus.lastRefusal {} else {
            XCTFail("the uploader must refuse replay readings as not live: \(String(describing: uploadStatus.lastRefusal))")
        }
    }
}
#endif
