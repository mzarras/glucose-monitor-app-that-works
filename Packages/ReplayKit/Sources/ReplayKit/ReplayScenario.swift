// The scripted scenarios (HANDOFF §9.3 WS2) and their milestones. DEBUG only (S6).
// Timelines, value tables and milestones are documented in docs/replay.md.
#if DEBUG
import Foundation
import GlucoseCore

public enum ReplayScenario: String, Sendable, CaseIterable {
    /// Warm-up, then in range and about flat at the 5-minute cadence.
    case steady
    /// Gradual fall through 70 to ≤ 55, down to a LOW flag, then recovery.
    case slowFallToUrgentLow
    /// Sudden drop to a compression low and back.
    case compressionLowSpike
    /// 45 minutes without delivery, then the missed readings arrive as backfill.
    case signalGapWithBackfill
    /// The session runs into the grace period (with a spike to HIGH) and then expires.
    case sensorExpiry

    /// The complete timeline with scenario time zero at `origin`. Deterministic: the same origin
    /// always gives the same timeline, and reading ids do not depend on the origin at all.
    public func timeline(origin: Date) -> ReplayTimeline {
        switch self {
        case .steady: return SteadyScenario.timeline(origin: origin)
        case .slowFallToUrgentLow: return SlowFallScenario.timeline(origin: origin)
        case .compressionLowSpike: return CompressionLowScenario.timeline(origin: origin)
        case .signalGapWithBackfill: return SignalGapScenario.timeline(origin: origin)
        case .sensorExpiry: return SensorExpiryScenario.timeline(origin: origin)
        }
    }

    /// Delivery offsets (seconds after the origin) of the moments alert tests assert on. The
    /// ScenarioTests recompute each one from the timeline, so these numbers cannot drift from it.
    public var milestones: [ScenarioMilestone: TimeInterval] {
        switch self {
        case .steady: return SteadyScenario.milestones
        case .slowFallToUrgentLow: return SlowFallScenario.milestones
        case .compressionLowSpike: return CompressionLowScenario.milestones
        case .signalGapWithBackfill: return SignalGapScenario.milestones
        case .sensorExpiry: return SensorExpiryScenario.milestones
        }
    }

    /// A source that plays this scenario. Use `ImmediateReplayClock(start: origin)` in tests,
    /// `ManualReplayClock` to step through it, `ScaledReplayClock(start: origin, speed:)` in UI demos.
    public func makeSource(origin: Date, clock: any ReplayClock) -> ReplaySource {
        ReplaySource(timeline: timeline(origin: origin), clock: clock)
    }
}

/// Named moments in a scenario. Each is the delivery offset of the first event that matches.
/// "Back above/below" milestones look only after the corresponding "first" milestone.
public enum ScenarioMilestone: String, Sendable, CaseIterable {
    /// State becomes `.active` after warm-up.
    case warmUpEnds
    case firstReading
    case lastReading
    /// First numeric reading ≤ 70 mg/dL (Low alert default, HANDOFF §5).
    case firstAtOrBelow70
    /// First numeric reading ≤ 55 mg/dL (Urgent low, HANDOFF §5, S7).
    case firstAtOrBelow55
    /// First sensor LOW flag (`.belowRange`).
    case firstLowFlag
    /// First numeric reading > 55 after `firstAtOrBelow55`.
    case backAbove55
    /// First numeric reading > 70 after `firstAtOrBelow70`.
    case backAbove70
    /// First reading with trend rate ≤ −3 mg/dL/min (Rise/fall alert default, HANDOFF §5).
    case firstFallRateAtLeast3
    /// First reading with trend rate ≥ +3 mg/dL/min.
    case firstRiseRateAtLeast3
    /// First numeric reading ≥ 250 mg/dL (High alert default, HANDOFF §5).
    case firstAtOrAbove250
    /// First sensor HIGH flag (`.aboveRange`).
    case firstHighFlag
    /// First numeric reading < 250 after `firstAtOrAbove250`.
    case backBelow250
    /// Last live reading delivered before the signal gap.
    case lastReadingBeforeGap
    /// First live reading after the gap.
    case liveReadingsResume
    /// The backfill batch is delivered.
    case backfillDelivered
    /// State becomes `.gracePeriod`.
    case gracePeriodStarts
    /// State becomes `.expired`.
    case expired
}
#endif
