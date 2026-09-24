// Everything the Now screen shows (HANDOFF §7.3.1). Display-ready; Phase 2 fills it from the
// store, the CGM source, GlucoseStats and ServiceHealth. The screen classifies staleness itself
// with a live clock (GlucoseDisplayState), so an old reading goes stale on screen even if nothing
// updates this state (S5).

import Foundation
import GlucoseCore
import WidgetCore

struct NowViewState: Equatable, Sendable {
    /// The newest **live** reading (repository `latestLiveReading()`, never imported history) with
    /// its sensor-reported trend and the delta to the previous live reading. Nil if none.
    /// Source of the hero value, age, delta and staleness.
    var latestLiveReading: LatestReading?
    /// The CGM source's current state.
    var sensorState: SensorState
    /// Stored readings from the last 24 hours, any source (imported history may be charted),
    /// ascending. The chart shows the part inside `chartWindow`.
    var chartPoints: [ChartPoint]
    /// Fingerstick calibrations to mark on the chart; never drawn as readings (S1).
    var fingersticks: [FingerstickMarker]
    var chartWindow: ChartWindow
    /// "Today so far" (midnight to now), from GlucoseStats.
    var today: TodaySummary
    var health: ServiceHealth
    /// DEBUG only: name of the active ReplayKit scenario, shown in the build banner. Always nil in
    /// Release builds.
    var replayScenario: String?
    /// Review N1: the latest reading's date while a clock mismatch is latched for it. Maintained
    /// with `updatingClockMismatchLatch(now:)` on every clock tick and every new state; cleared
    /// when a newer live reading arrives. Phase 2 persists it with the rest of the Now state.
    var clockMismatchLatchedFor: Date? = nil
    /// Review minor 4: the sensor asked for a calibration and has not been calibrated since, even
    /// if its state has moved to a transient failure (e.g. the phone clock). Maintained with
    /// `CalibrationNeed.update(previous:sensorState:)` on every sensor-state change.
    var sensorNeedsCalibration: Bool = false

    /// The DEBUG/REPLAY banner. Computed, not stored, so no code path can clear it in a DEBUG
    /// build; nil in Release.
    var buildBanner: BuildBanner? { BuildBanner.forThisBuild(replayScenario: replayScenario) }

    func banners(now: Date, context: DisplayContext = .current) -> [AppBanner] {
        AppBanners.make(sensorState: sensorState, latestLiveReadingDate: latestLiveReading?.date, health: health, now: now,
                        clockMismatchLatched: isClockMismatchLatched, sensorNeedsCalibration: sensorNeedsCalibration, context: context)
    }

    func display(now: Date) -> GlucoseDisplayState {
        ClockMismatchLatch.apply(
            GlucoseDisplayState.classify(latest: latestLiveReading, sensorState: sensorState, now: now),
            latest: latestLiveReading,
            latchedFor: clockMismatchLatchedFor
        )
    }

    var isClockMismatchLatched: Bool {
        clockMismatchLatchedFor != nil && clockMismatchLatchedFor == latestLiveReading?.date
    }

    /// The latch after looking at the clock `now` (pure; call on every tick and state change).
    func updatingClockMismatchLatch(now: Date) -> NowViewState {
        var copy = self
        copy.clockMismatchLatchedFor = ClockMismatchLatch.update(latchedFor: clockMismatchLatchedFor, latest: latestLiveReading, now: now)
        return copy
    }

    /// Nothing known yet (before Phase 2 wiring, and a fresh install).
    static let empty = NowViewState(
        latestLiveReading: nil,
        sensorState: .notPaired,
        chartPoints: [],
        fingersticks: [],
        chartWindow: .threeHours,
        today: TodaySummary(timeInRangePercent: nil, averageMgdl: nil, lowCount: nil),
        health: .unconfigured,
        replayScenario: nil
    )
}

/// Now chart time window (HANDOFF §7.3.1: 3/6/12/24 H).
enum ChartWindow: Int, CaseIterable, Identifiable, Sendable {
    case threeHours = 3
    case sixHours = 6
    case twelveHours = 12
    case twentyFourHours = 24

    var id: Int { rawValue }
    var label: String { "\(rawValue)H" }
    var duration: TimeInterval { TimeInterval(rawValue) * 3_600 }
    /// Hours between x-axis labels, so there are about four.
    var hourStride: Int {
        switch self {
        case .threeHours: return 1
        case .sixHours: return 2
        case .twelveHours: return 3
        case .twentyFourHours: return 6
        }
    }
    var spokenName: String { "Last \(rawValue) hours" }
}

/// "Today so far" (HANDOFF §7.3.1). Nil fields show "—".
struct TodaySummary: Equatable, Sendable {
    /// Percent of today's readings in 70–180, rounded.
    var timeInRangePercent: Int?
    /// Mean of today's numeric readings, mg/dL, rounded.
    var averageMgdl: Int?
    /// Hypo events today (HANDOFF §6 level 1: ≥ 15 consecutive min < 70).
    var lowCount: Int?
}

/// Persistent banner that marks a DEBUG build (and an active replay), so a DEBUG build is never
/// mistaken for the Release build used with a live sensor (PROGRESS D19).
struct BuildBanner: Equatable, Sendable {
    let title: String
    let detail: String

    /// Non-nil in every DEBUG build; nil in Release (the type's text never ships).
    static func forThisBuild(replayScenario: String?) -> BuildBanner? {
        #if DEBUG
        if let replayScenario {
            return BuildBanner(title: "DEBUG BUILD · REPLAY: \(replayScenario.uppercased())", detail: "Replayed data, not a sensor. Not for treatment decisions.")
        }
        return BuildBanner(title: "DEBUG BUILD", detail: "Not for use with a live sensor. Test sensors with a Release build.")
        #else
        return nil
        #endif
    }
}
