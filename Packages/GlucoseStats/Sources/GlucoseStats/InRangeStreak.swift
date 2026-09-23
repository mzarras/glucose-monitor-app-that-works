// Longest continuous in-range stretch (HANDOFF §6: "Longest continuous run in 70–180 (gaps > 15 min
// break the run)").

import Foundation
import GlucoseCore

/// A run of consecutive in-range (70–180 mg/dL) readings inside the period with no gap over
/// 15 minutes, measured with the `Continuity` rules and cut at the period end. LOW and HIGH are out
/// of range (S4).
public struct InRangeStreak: Sendable, Equatable {
    /// Timestamp of the run's first reading.
    public let start: Date
    /// Coverage end of the run's last reading.
    public let end: Date
    public let readingCount: Int

    /// Seconds.
    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// The longest run in the period; the earliest wins a tie. `nil` without in-range readings.
    public static func longest(in period: PeriodReadings) -> InRangeStreak? {
        let readings = period.readings
        var best: InRangeStreak?
        var runStart: Int?

        func finishRun(lastIndex: Int) {
            guard let first = runStart else { return }
            let run = InRangeStreak(
                start: readings[first].date,
                end: Continuity.coverageEnd(ofReadingAt: lastIndex, in: readings, notAfter: period.interval.end),
                readingCount: lastIndex - first + 1
            )
            if run.duration > (best?.duration ?? 0) { best = run }
            runStart = nil
        }

        period.forEachReading { index, reading in
            if reading.startsAfterGap {
                finishRun(lastIndex: index - 1)
            }
            if reading.band == .inRange {
                if runStart == nil { runStart = index }
            } else {
                finishRun(lastIndex: index - 1)
            }
        }
        finishRun(lastIndex: readings.count - 1)
        return best
    }
}
