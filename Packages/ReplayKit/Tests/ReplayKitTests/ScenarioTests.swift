#if DEBUG
import GlucoseCore
import XCTest
@testable import ReplayKit

final class ScenarioTests: XCTestCase {
    private let minute: TimeInterval = 60

    // MARK: Determinism

    func test_timelinesAreDeterministicAndIDsDoNotDependOnTheOrigin() {
        for scenario in ReplayScenario.allCases {
            XCTAssertEqual(scenario.timeline(origin: testOrigin), scenario.timeline(origin: testOrigin), "\(scenario)")
            let ids = scenario.timeline(origin: testOrigin).readingsInDeliveryOrder.map(\.id)
            let shiftedIDs = scenario.timeline(origin: fractionalOrigin).readingsInDeliveryOrder.map(\.id)
            XCTAssertEqual(ids, shiftedIDs, "\(scenario): ids come from session time, not the wall clock")
            XCTAssertEqual(Set(ids).count, ids.count, "\(scenario): ids are unique")
        }
    }

    func test_sourcesProduceTheSameStreamEveryRun() async throws {
        for scenario in ReplayScenario.allCases {
            let first = try await playToEnd(scenario.makeSource(origin: testOrigin, clock: ImmediateReplayClock(start: testOrigin)))
            let second = try await playToEnd(scenario.makeSource(origin: testOrigin, clock: ImmediateReplayClock(start: testOrigin)))
            XCTAssertEqual(first.streamed, second.streamed, "\(scenario)")
            XCTAssertEqual(first.states, second.states, "\(scenario)")
        }
    }

    // MARK: Safety

    func test_S1_sourceEmitsExactlyTheScriptedReadings() async throws {
        for scenario in ReplayScenario.allCases {
            let source = scenario.makeSource(origin: testOrigin, clock: ImmediateReplayClock(start: testOrigin))
            let played = try await playToEnd(source)
            let script = source.timeline.readingsInDeliveryOrder
            XCTAssertEqual(played.streamed, script, "\(scenario)")
            XCTAssertEqual(played.logged, script, "\(scenario): nothing was emitted beyond the script")
            XCTAssertEqual(played.states, [source.timeline.initialState] + source.timeline.stateChanges.map(\.state), "\(scenario)")
        }
    }

    func test_S1_signalGapStaysAGapUntilTheBackfill() {
        let timeline = ReplayScenario.signalGapWithBackfill.timeline(origin: testOrigin)
        let beforeReconnect = timeline.deliveries.filter { $0.offset < 75 * minute }
        XCTAssertEqual(beforeReconnect.map(\.reading.date), stride(from: 0, through: 30, by: 5).map { testOrigin.addingTimeInterval(TimeInterval($0) * minute) })
        // Every reading dated inside the gap is one of the eight scripted backfilled readings.
        let insideGap = timeline.readingsInDeliveryOrder.filter {
            $0.date > testOrigin.addingTimeInterval(30 * minute) && $0.date < testOrigin.addingTimeInterval(75 * minute)
        }
        XCTAssertEqual(insideGap.map(\.date), stride(from: 35, through: 70, by: 5).map { testOrigin.addingTimeInterval(TimeInterval($0) * minute) })
        XCTAssertTrue(insideGap.allSatisfy(\.isBackfill))
    }

    func test_S2_everyScriptedReadingPassesTheReplayGateForItsSession() throws {
        for origin in [testOrigin, fractionalOrigin] {
            for scenario in ReplayScenario.allCases {
                let timeline = scenario.timeline(origin: origin)
                XCTAssertTrue(timeline.session.isWellFormed, "\(scenario)")
                for delivery in timeline.deliveries {
                    let now = origin.addingTimeInterval(delivery.offset)
                    XCTAssertNoThrow(
                        try LiveReadingGate.validateAllowingReplay(delivery.reading, session: timeline.session, now: now),
                        "\(scenario) \(delivery.reading.id)"
                    )
                }
            }
        }
    }

    func test_S3_backfillIsFlaggedWithOriginalTimestampsAscendingAndStableIDs() throws {
        let timeline = ReplayScenario.signalGapWithBackfill.timeline(origin: testOrigin)
        let batches = timeline.events.compactMap { event -> (TimeInterval, [GlucoseReading])? in
            if case .backfill(let readings) = event.kind { return (event.offset, readings) }
            return nil
        }
        XCTAssertEqual(batches.count, 1)
        let (deliveredAt, backfill) = try XCTUnwrap(batches.first)
        XCTAssertEqual(deliveredAt, 75 * minute)
        XCTAssertTrue(backfill.allSatisfy(\.isBackfill))
        XCTAssertEqual(backfill.map(\.date), stride(from: 35, through: 70, by: 5).map { testOrigin.addingTimeInterval(TimeInterval($0) * minute) })
        XCTAssertEqual(backfill.map(\.date), backfill.map(\.date).sorted(), "ascending")
        // Session started 1 day before the origin, so sensor seconds = 86 400 + minute × 60.
        XCTAssertEqual(
            backfill.map(\.id),
            stride(from: 35, through: 70, by: 5).map { GlucoseReading.sensorID(serial: "REPLAY-GAP", sensorTimestamp: UInt32(86_400 + $0 * 60)) }
        )
        let live = timeline.readingsInDeliveryOrder.filter { !backfill.contains($0) }
        XCTAssertFalse(live.contains(where: \.isBackfill), "only the backfill batch is flagged")
    }

    func test_S3_liveReadingsAreInDateOrderInEveryScenario() {
        for scenario in ReplayScenario.allCases where scenario != .signalGapWithBackfill {
            let dates = scenario.timeline(origin: testOrigin).readingsInDeliveryOrder.map(\.date)
            XCTAssertEqual(dates, dates.sorted(), "\(scenario)")
        }
    }

    func test_S4_lowAndHighAreFlagsNeverNumbers() {
        let fall = ReplayScenario.slowFallToUrgentLow.timeline(origin: testOrigin)
        XCTAssertEqual(fall.readingsInDeliveryOrder.filter { $0.value == .belowRange }.map(\.date),
                       [110, 115].map { testOrigin.addingTimeInterval(TimeInterval($0) * minute) })
        let expiry = ReplayScenario.sensorExpiry.timeline(origin: testOrigin)
        XCTAssertEqual(expiry.readingsInDeliveryOrder.filter { $0.value == .aboveRange }.map(\.date),
                       [160, 165, 170].map { testOrigin.addingTimeInterval(TimeInterval($0) * minute) })

        for scenario in ReplayScenario.allCases {
            for reading in scenario.timeline(origin: testOrigin).readingsInDeliveryOrder {
                if let number = reading.value.numericMgdl {
                    XCTAssertTrue(GlucoseValue.sensorReportableRange.contains(number), "\(scenario) \(reading.id): \(number)")
                } else {
                    XCTAssertNil(reading.trendRate, "\(scenario) \(reading.id): a flag carries no rate")
                }
            }
        }
    }

    func test_S6_everyScenarioReadingIsReplay() async throws {
        for scenario in ReplayScenario.allCases {
            let played = try await playToEnd(scenario.makeSource(origin: testOrigin, clock: ImmediateReplayClock(start: testOrigin)))
            XCTAssertFalse(played.streamed.isEmpty)
            for reading in played.streamed {
                XCTAssertEqual(reading.source, .replay, "\(scenario) \(reading.id)")
                XCTAssertThrowsError(try LiveReadingGate.validate(reading, session: scenario.timeline(origin: testOrigin).session, now: reading.date),
                                     "the production gate refuses every replay reading")
            }
        }
    }

    // MARK: Scenario facts (docs/replay.md)

    func test_milestonesMatchTheTimelines() {
        for scenario in ReplayScenario.allCases {
            XCTAssertEqual(computedMilestones(scenario.timeline(origin: testOrigin)), scenario.milestones, "\(scenario)")
        }
    }

    func test_steadyWarmUpHasNoReadings() {
        let timeline = ReplayScenario.steady.timeline(origin: testOrigin)
        XCTAssertEqual(timeline.stateChanges.first?.state, .warmingUp(endsAt: testOrigin.addingTimeInterval(30 * minute)))
        XCTAssertEqual(timeline.stateChanges.first?.offset, 0)
        XCTAssertEqual(timeline.readingsInDeliveryOrder.first?.date, timeline.session.warmUpEndsAt)
        XCTAssertFalse(timeline.readingsInDeliveryOrder.contains { $0.date < timeline.session.warmUpEndsAt })
        XCTAssertEqual(timeline.readingsInDeliveryOrder.count, 25)
    }

    func test_sensorExpiryStopsReadingsAndEndsExpired() {
        let timeline = ReplayScenario.sensorExpiry.timeline(origin: testOrigin)
        XCTAssertEqual(timeline.readingsInDeliveryOrder.count, 150)
        XCTAssertEqual(timeline.session.expiresAt, testOrigin.addingTimeInterval(30 * minute))
        XCTAssertEqual(timeline.session.gracePeriodEndsAt, testOrigin.addingTimeInterval(750 * minute))
        XCTAssertEqual(timeline.stateChanges.map(\.state), [
            .active(sessionStart: timeline.session.start, expiresAt: timeline.session.expiresAt),
            .gracePeriod(endsAt: timeline.session.gracePeriodEndsAt),
            .expired,
        ])
        XCTAssertEqual(timeline.events.last?.kind, .state(.expired), "nothing is delivered after expiry")
        XCTAssertTrue(timeline.readingsInDeliveryOrder.allSatisfy { $0.date < timeline.session.gracePeriodEndsAt })
    }

    func test_rateAlertThresholdIsReachedOnlyInTheCompressionScenario() {
        for scenario in ReplayScenario.allCases {
            let fastest = scenario.timeline(origin: testOrigin).readingsInDeliveryOrder.compactMap(\.trendRate).map(abs).max() ?? 0
            if scenario == .compressionLowSpike {
                XCTAssertGreaterThanOrEqual(fastest, 3)
            } else {
                XCTAssertLessThan(fastest, 3, "\(scenario)")
            }
        }
    }

    func test_valueTablesMatchTheDocumentedShape() {
        let fall = ReplayScenario.slowFallToUrgentLow.timeline(origin: testOrigin).readingsInDeliveryOrder
        XCTAssertEqual(fall.count, 31)
        let compression = ReplayScenario.compressionLowSpike.timeline(origin: testOrigin).readingsInDeliveryOrder
        XCTAssertEqual(compression.count, 25)
        XCTAssertEqual(compression.compactMap(\.value.numericMgdl).min(), 51)
        let gap = ReplayScenario.signalGapWithBackfill.timeline(origin: testOrigin).readingsInDeliveryOrder
        XCTAssertEqual(gap.count, 25)
        XCTAssertEqual(gap.compactMap(\.value.numericMgdl).max(), 182)
        let expiry = ReplayScenario.sensorExpiry.timeline(origin: testOrigin).readingsInDeliveryOrder
        XCTAssertEqual(expiry.compactMap(\.value.numericMgdl).max(), 396)
    }

    // MARK: Milestone rules, recomputed from a timeline

    private func computedMilestones(_ timeline: ReplayTimeline) -> [ScenarioMilestone: TimeInterval] {
        var result: [ScenarioMilestone: TimeInterval] = [:]
        let deliveries = timeline.deliveries
        result[.firstReading] = deliveries.first?.offset
        result[.lastReading] = deliveries.last?.offset

        let hadWarmUp = timeline.stateChanges.contains { if case .warmingUp = $0.state { return true } else { return false } }
        if hadWarmUp {
            result[.warmUpEnds] = timeline.firstStateOffset { if case .active = $0 { return true } else { return false } }
        }
        result[.gracePeriodStarts] = timeline.firstStateOffset { if case .gracePeriod = $0 { return true } else { return false } }
        result[.expired] = timeline.firstStateOffset { $0 == .expired }

        let at70 = timeline.firstDeliveryOffset { ($0.value.numericMgdl ?? .max) <= 70 }
        let at55 = timeline.firstDeliveryOffset { ($0.value.numericMgdl ?? .max) <= 55 }
        let at250 = timeline.firstDeliveryOffset { ($0.value.numericMgdl ?? .min) >= 250 }
        result[.firstAtOrBelow70] = at70
        result[.firstAtOrBelow55] = at55
        result[.firstAtOrAbove250] = at250
        result[.backAbove70] = at70.flatMap { timeline.firstDeliveryOffset(after: $0) { ($0.value.numericMgdl ?? .min) > 70 } }
        result[.backAbove55] = at55.flatMap { timeline.firstDeliveryOffset(after: $0) { ($0.value.numericMgdl ?? .min) > 55 } }
        result[.backBelow250] = at250.flatMap { timeline.firstDeliveryOffset(after: $0) { ($0.value.numericMgdl ?? .max) < 250 } }
        result[.firstLowFlag] = timeline.firstDeliveryOffset { $0.value == .belowRange }
        result[.firstHighFlag] = timeline.firstDeliveryOffset { $0.value == .aboveRange }
        result[.firstFallRateAtLeast3] = timeline.firstDeliveryOffset { ($0.trendRate ?? 0) <= -3 }
        result[.firstRiseRateAtLeast3] = timeline.firstDeliveryOffset { ($0.trendRate ?? 0) >= 3 }

        if let backfill = timeline.events.first(where: { if case .backfill = $0.kind { return true } else { return false } }) {
            result[.backfillDelivered] = backfill.offset
            let live = deliveries.filter { !$0.reading.isBackfill }
            result[.lastReadingBeforeGap] = live.last { $0.offset < backfill.offset }?.offset
            result[.liveReadingsResume] = live.first { $0.offset >= backfill.offset }?.offset
        }
        return result
    }
}
#endif
