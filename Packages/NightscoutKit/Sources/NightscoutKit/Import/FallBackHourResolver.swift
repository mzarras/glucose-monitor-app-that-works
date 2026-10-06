// Original to Sensor (no ported code).
// Places Clarity EGV rows whose local time falls in the repeated hour of a DST fall-back (the
// wall-clock time happened twice: earlier instant E, later instant L). S3: the instant is derived
// from evidence in the file, never assumed; when the evidence does not decide, the row is rejected.
//
// Rules:
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
// 3. A row with no transmitter time is rejected (`rejectedAmbiguousLocalTime`). File order cannot
//    decide: a 60–70 min gap straddling the transition, or a file that is not strictly
//    chronological, makes the wrong pass look like the continuation (review n4).
//
// So no instant is ever assumed: a row in the repeated hour is placed only when the transmitter
// clock, measured from a row whose instant is known, matches one of its two candidates within
// 60 s. Everything else is rejected and counted. (Real Clarity exports carry transmitter times;
// at most one hour of rows per year can be affected.)

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
            // Rules 1–3: the transmitter clock decides, or nothing does.
            let chosen: Date?
            if let expected = expectedByTransmitterTime(index, rows: rows, known: known) {
                chosen = [earlier, later].first { abs($0.timeIntervalSince(expected)) <= transmitterTimeTolerance }
            } else {
                chosen = nil
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
}
