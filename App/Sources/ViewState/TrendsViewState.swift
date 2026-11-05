// Everything the Trends screen shows for one period (HANDOFF §6, §7.3.2). Filled by
// `TrendsMapping.make` from GlucoseStats for the selected period (off the main actor); every
// percentage is 0...100.

import Foundation
import GlucoseCore
import WidgetCore

/// Trends period selector (HANDOFF §7.3.2: 1/3/7/14/30/90 D, default 14 D).
enum TrendsPeriod: Int, CaseIterable, Identifiable, Sendable {
    case oneDay = 1
    case threeDays = 3
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30
    case ninetyDays = 90

    static let `default`: TrendsPeriod = .fourteenDays

    var id: Int { rawValue }
    var days: Int { rawValue }
    var label: String { "\(rawValue)D" }
    /// 1 D and 3 D show real readings instead of percentile bands (HANDOFF §7.3.2).
    var showsDailyTraces: Bool { self == .oneDay || self == .threeDays }
}

struct TrendsViewState: Equatable, Sendable {
    var period: TrendsPeriod
    /// The span the statistics cover (e.g. Sep 10 00:00 – Sep 23 now). Nil when there is no data.
    var interval: DateInterval?
    /// % of readings in 70–180.
    var timeInRange: Double?
    /// Change in time in range, percentage points, vs the immediately preceding equal-length
    /// period (HANDOFF §6). Nil if the prior period has no data.
    var timeInRangeChange: Double?
    /// The prior period has readings but under 70 % of the expected ones, so the change rests on
    /// thin data (`PeriodComparison.previousHasSufficientData`); the change line says so.
    var priorPeriodIsSparse: Bool = false
    /// The five consensus bins; nil when there are no readings.
    var rangeBins: RangeBins?
    /// "A typical day": percentile bands for ≥ 7 D, the actual daily traces for 1 D / 3 D.
    var profile: DailyProfile
    /// % in 70–140.
    var tightRange: Double?
    var meanMgdl: Double?
    /// GMI (%). Shown only when the period is ≥ 14 days, whatever this holds (HANDOFF §7.3.2).
    var gmiPercent: Double?
    /// Coefficient of variation, %.
    var cvPercent: Double?
    var lows: LowsSummary?
    /// % in range 00:00–06:00 (HANDOFF §6 overnight window).
    var overnightTimeInRange: Double?
    /// Longest continuous run in 70–180; gaps > 15 min break a run (HANDOFF §6).
    var longestInRangeStreak: TimeInterval?
    /// v1.1 (needs HealthKit workouts). The row stays hidden while
    /// `FeatureFlags.showsAfterExerciseRow` is false.
    var afterExerciseTimeInRange: Double?
    /// % of expected 5-minute readings present. Under 70 % shows a warning (HANDOFF §6).
    var dataSufficiency: Double
    /// Set when the period includes imported history (HANDOFF §4.5 step 4: footnote).
    var importedData: ImportedDataNote?
    /// Statistics for `period` are being computed (a period was just selected); the screen shows a
    /// progress note instead of "no readings".
    var isComputing: Bool = false
    /// Why the statistics could not be computed (e.g. the database is not open yet, S5).
    var loadError: String? = nil

    static func empty(period: TrendsPeriod) -> TrendsViewState {
        TrendsViewState(
            period: period, interval: nil, timeInRange: nil, timeInRangeChange: nil, rangeBins: nil,
            profile: .none, tightRange: nil, meanMgdl: nil, gmiPercent: nil, cvPercent: nil, lows: nil,
            overnightTimeInRange: nil, longestInRangeStreak: nil, afterExerciseTimeInRange: nil,
            dataSufficiency: 0, importedData: nil
        )
    }
}

/// Percent of readings in each consensus bin (HANDOFF §6). LOW flags count in `veryLow`, HIGH
/// flags in `veryHigh`.
struct RangeBins: Equatable, Sendable {
    var veryLow: Double
    var low: Double
    var inRange: Double
    var high: Double
    var veryHigh: Double

    func percent(for band: GlucoseBand) -> Double {
        switch band {
        case .veryLow: return veryLow
        case .low: return low
        case .inRange: return inRange
        case .high: return high
        case .veryHigh: return veryHigh
        }
    }

    /// The whole percentage shown for `band`. Rounding each bin on its own can total 99 or 101, so
    /// the bins are rounded together (largest remainder): the shown values add up to 100 whenever
    /// any bin is non-zero. A bin that is exactly 0 always shows 0, and no bin shows 100 while
    /// another bin is non-zero (that bin shows "<1%", TrendsText.binPercent).
    func displayPercent(for band: GlucoseBand) -> Int {
        let bands = GlucoseBand.allCases
        let values = bands.map { max(0, percent(for: $0)) }
        let total = values.reduce(0, +)
        guard total > 0 else { return 0 }
        // Normalised so the bins total exactly 100 before rounding (the inputs can drift by a
        // floating-point hair).
        let scaled = values.map { $0 * 100 / total }
        var shown = scaled.map { Int($0.rounded(.down)) }
        let missing = max(0, 100 - shown.reduce(0, +))
        // Largest fractional part first; ties go to the lower band so a low is never rounded away
        // in favour of a high. Compared to 1e-9 so floating-point noise does not break a tie.
        let remainders = bands.indices.map { ((scaled[$0] - Double(shown[$0])) * 1e9).rounded() }
        let order = bands.indices
            .filter { scaled[$0] > 0 }
            .sorted { (remainders[$0], -$0) > (remainders[$1], -$1) }
        for index in order.prefix(missing) { shown[index] += 1 }
        let nonZero = values.filter { $0 > 0 }.count
        if nonZero > 1, let full = shown.firstIndex(of: 100) { shown[full] = 99 }
        return shown[bands.firstIndex(of: band) ?? 0]
    }
}

enum DailyProfile: Equatable, Sendable {
    case none
    /// Ambulatory glucose profile buckets over the day, ascending by `minuteOfDay` (≥ 7 D).
    case percentiles([AGPBucket])
    /// Real readings of each day, by time of day (1 D: today; 3 D: today and the two days before).
    case days([DayTrace])
}

/// One time-of-day bucket of the AGP (HANDOFF §6: 5/25/50/75/95th percentiles, 15-min buckets,
/// lightly smoothed for display by `AGPDisplaySmoothing`). Chart geometry, not readings (S1).
struct AGPBucket: Equatable, Sendable {
    /// Start of the bucket, minutes after midnight (0 ..< 1440).
    var minuteOfDay: Int
    var p5: AGPLineValue
    var p25: AGPLineValue
    var p50: AGPLineValue
    var p75: AGPLineValue
    var p95: AGPLineValue

    init(minuteOfDay: Int, p5: AGPLineValue, p25: AGPLineValue, p50: AGPLineValue, p75: AGPLineValue, p95: AGPLineValue) {
        self.minuteOfDay = minuteOfDay
        self.p5 = p5
        self.p25 = p25
        self.p50 = p50
        self.p75 = p75
        self.p95 = p95
    }

    /// All-numeric bucket (fixtures, previews).
    init(minuteOfDay: Int, p5: Double, p25: Double, p50: Double, p75: Double, p95: Double) {
        self.init(minuteOfDay: minuteOfDay, p5: .mgdl(p5), p25: .mgdl(p25), p50: .mgdl(p50), p75: .mgdl(p75), p95: .mgdl(p95))
    }
}

/// A point on an AGP percentile line. A percentile can be the sensor's LOW or HIGH flag (GlucoseStats
/// orders flags as the extremes, S4); it stays a flag here and is drawn at the chart's floor or
/// ceiling, never as 40 or 400.
enum AGPLineValue: Equatable, Sendable {
    case mgdl(Double)
    case belowRange
    case aboveRange

    /// The number, if this is one.
    var mgdl: Double? {
        if case .mgdl(let value) = self { return value }
        return nil
    }

    /// Where the chart draws it: numbers as themselves, LOW at `floor`, HIGH at `ceiling`. Chart
    /// geometry only; never shown as a value.
    func chartY(floor: Double, ceiling: Double) -> Double {
        switch self {
        case .mgdl(let value): return min(max(value, floor), ceiling)
        case .belowRange: return floor
        case .aboveRange: return ceiling
        }
    }
}

/// One day's real readings for the 1 D / 3 D overlay.
struct DayTrace: Equatable, Identifiable, Sendable {
    /// Local midnight that starts the day.
    var dayStart: Date
    var isToday: Bool
    /// Readings of that day, ascending (flags included; the chart shows them as markers).
    var points: [ChartPoint]
    /// The zone `dayStart` is local midnight in: the overlay plots wall-clock hours (review m17).
    var timeZone: TimeZone = .current

    var id: Date { dayStart }
}

/// Hypo events (HANDOFF §6 level 1).
struct LowsSummary: Equatable, Sendable {
    var count: Int
    var meanDurationMinutes: Int?
    /// The time-of-day window where most events started, if one stands out.
    var peakWindow: HourWindow?
}

/// "4 of 6 between 2–5 AM": `count` events started in [startHour, endHour).
struct HourWindow: Equatable, Sendable {
    var startHour: Int
    var endHour: Int
    var count: Int
}

struct ImportedDataNote: Equatable, Sendable {
    var origins: [ImportOrigin]
    /// The part of the period covered by imported readings.
    var interval: DateInterval
}

enum FeatureFlags {
    /// "In range after runs" (HANDOFF §6: v1.1, needs HealthKit). Hidden until then.
    static let showsAfterExerciseRow = false
}
