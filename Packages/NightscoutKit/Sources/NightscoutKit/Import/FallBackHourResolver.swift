// Places Clarity EGV rows whose local time falls in the repeated hour of a DST fall-back (the
// wall-clock time happened twice: earlier instant E, later instant L). S3: the instant is derived
// from evidence in the file, never assumed; when the evidence does not decide, the row is rejected.
//
// Evidence, strongest first:
//
// 1. Transmitter time (column "Transmitter Time (Long Integer)": seconds on the transmitter's own
//    clock, which does not jump at DST). Take the nearest row in file order (earlier rows win ties)
//    whose instant is already known and that has a transmitter time from the same transmitter (same
//    "Transmitter ID", or both without one). The row's instant must be
//        anchor.instant + (row.transmitterTime − anchor.transmitterTime)   ± 60 s.
//    Exactly the candidate (E or L) within that tolerance is used; if neither is, the row is
//    rejected (`rejectedAmbiguousLocalTime`) — e.g. the transmitter clock was reset. File order
//    plays no role, so an export whose two passes of the repeated hour are interleaved is placed
//    correctly. Rows outside the repeated hour are known from the start; rows inside it become
//    known as they are placed (file order).
//
// 2. A row that has a transmitter time but no known row from the same transmitter to compare it
//    with (e.g. a sensor whose only rows sit inside the repeated hour after a data gap) is
//    rejected (`rejectedAmbiguousLocalTime`): its clock cannot be tied to an instant.
//
// 3. Only rows with no transmitter time at all use file order, which Clarity writes
//    chronologically. With P = the instant of the nearest earlier known row:
//       no earlier known row                → rejected
//       E and L both not before P:
//         E at most 10 min after P          → E   (continuous 5-minute data, still the first pass;
//                                                  E equal to P is the same reading listed twice
//                                                  and becomes a duplicate id, never a new reading
//                                                  an hour away, S1)
//         E more than 10 min after P        → rejected: across a data gap either pass fits
//       only L not before P                 → L   (the clock went back: second pass)
//       neither                             → rejected: out of order.
//
// So no instant is ever assumed: a placed row either matches the transmitter clock, or is the
// only candidate consistent with the file's chronological order, or (when both are) continues the
// sequence within 10 min. Everything else is rejected and counted.

import Foundation

struct FallBackHourResolver {
    /// One EGV row as far as placement is concerned.
    struct Row {
        enum Time {
            case known(Date)
            case ambiguous(earlier: Date, later: Date)
            /// Invalid or nonexistent local time: never placed, never an anchor.
            case unplaceable
        }

        let time: Time
        /// Seconds on the transmitter's clock, if the export has them.
        let transmitterTime: Double?
        /// "Transmitter ID"; `nil` when the column is absent or empty.
        let transmitterID: String?
    }

    enum Placement: Equatable {
        case placed(Date)
        case rejectedAmbiguous
        case unplaceable
    }

    /// Transmitter-time agreement required to accept a candidate (clock drift, rounding).
    static let transmitterTimeTolerance: TimeInterval = 60

    /// Placement for every row, same order as `rows`.
    static func place(_ rows: [Row]) -> [Placement] {
        var known: [Date?] = rows.map { row in
            if case .known(let date) = row.time { return date }
            return nil
        }
        var placements: [Placement] = rows.map { row in
            switch row.time {
            case .known(let date): return .placed(date)
            case .unplaceable: return .unplaceable
            case .ambiguous: return .rejectedAmbiguous   // replaced below
            }
        }
        for index in rows.indices {
            guard case .ambiguous(let earlier, let later) = rows[index].time else { continue }
            let chosen: Date?
            if rows[index].transmitterTime != nil {
                // Rules 1 and 2: the transmitter clock decides, or nothing does.
                if let expected = expectedByTransmitterTime(index, rows: rows, known: known) {
                    chosen = [earlier, later].first { abs($0.timeIntervalSince(expected)) <= transmitterTimeTolerance }
                } else {
                    chosen = nil
                }
            } else {
                // Rule 3: no transmitter time at all.
                chosen = byFileOrder(earlier: earlier, later: later, previous: known[..<index].last { $0 != nil } ?? nil)
            }
            if let chosen {
                known[index] = chosen
                placements[index] = .placed(chosen)
            }
        }
        return placements
    }

    /// Rule 1: where the transmitter clock says this row must be, or `nil` if there is no evidence.
    private static func expectedByTransmitterTime(_ index: Int, rows: [Row], known: [Date?]) -> Date? {
        guard let time = rows[index].transmitterTime else { return nil }
        let id = rows[index].transmitterID
        for distance in 1..<max(rows.count, 1) {
            for candidate in [index - distance, index + distance] where rows.indices.contains(candidate) {
                guard let anchorDate = known[candidate],
                      let anchorTime = rows[candidate].transmitterTime,
                      rows[candidate].transmitterID == id else { continue }
                return anchorDate.addingTimeInterval(time - anchorTime)
            }
        }
        return nil
    }

    /// Largest step from the previous row for which "E continues the sequence" is trusted (rule 3).
    /// G7 readings are 5 minutes apart; beyond this there is a gap in which either pass could fit.
    static let maximumContinuousGap: TimeInterval = 10 * 60

    /// Rule 3 (row without a transmitter time): chronological file order, no gaps.
    private static func byFileOrder(earlier: Date, later: Date, previous: Date?) -> Date? {
        guard let previous else { return nil }
        if earlier >= previous {
            // Both candidates fit the order; only a step of at most 10 min tells them apart.
            return earlier.timeIntervalSince(previous) <= maximumContinuousGap ? earlier : nil
        }
        if later >= previous { return later }
        return nil
    }
}
