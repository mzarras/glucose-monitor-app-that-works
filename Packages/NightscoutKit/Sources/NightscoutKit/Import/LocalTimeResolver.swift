// Turns a wall-clock time without an offset (how Clarity writes timestamps) into instants, making
// daylight-saving transitions explicit instead of letting a date formatter guess (S3).

import Foundation

/// A local date and time with no offset, e.g. Clarity's `2025-11-02T01:30:00`.
struct LocalDateTime: Sendable, Equatable {
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    let second: Int

    /// Parses `YYYY-MM-DDThh:mm:ss` (the Clarity column header's own format). Older exports use a
    /// space instead of `T` (header `Timestamp (YYYY-MM-DD hh:mm:ss)`), which is accepted too.
    init?(clarityTimestamp raw: String) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let chars = Array(text)
        guard chars.count == 19,
              chars[4] == "-", chars[7] == "-", chars[10] == "T" || chars[10] == " ",
              chars[13] == ":", chars[16] == ":" else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            let slice = chars[range]
            guard slice.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(String(slice))
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19) else { return nil }
        self.init(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
    }
}

struct LocalTimeResolver: Sendable {
    enum Resolution: Sendable, Equatable {
        /// The local time names exactly one instant.
        case unique(Date)
        /// Fall-back hour: the local time happened twice (e.g. 01:30 EDT and 01:30 EST).
        case ambiguous(earlier: Date, later: Date)
        /// Spring-forward gap: the local time never happened (e.g. 02:30 on the US spring-forward day).
        case nonexistent
        /// Not a real calendar date/time (e.g. February 30th, 25:00).
        case invalid
    }

    let timeZone: TimeZone

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Every instant at which `timeZone`'s clocks showed `local`.
    ///
    /// Method: read `local` as if it were UTC ("naive" instant N). An instant I shows `local` in the
    /// zone exactly when I + offset(I) = N, i.e. I = N − o for an offset o that the zone actually
    /// uses at N − o. The candidate offsets are the zone's offsets a day either side of N (a DST
    /// transition changes the offset only between those), plus the one at N.
    ///   0 valid instants → spring-forward gap; 1 → unique; 2 → fall-back repeat.
    func resolve(_ local: LocalDateTime) -> Resolution {
        let components = DateComponents(
            year: local.year, month: local.month, day: local.day,
            hour: local.hour, minute: local.minute, second: local.second
        )
        // Round-trip check: Calendar is lenient (Feb 30 → Mar 2); reject anything that moved.
        guard let naive = Self.utcCalendar.date(from: components) else { return .invalid }
        let back = Self.utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: naive)
        guard back.year == local.year, back.month == local.month, back.day == local.day,
              back.hour == local.hour, back.minute == local.minute, back.second == local.second else {
            return .invalid
        }

        let day: TimeInterval = 86_400
        let offsets = Set([
            timeZone.secondsFromGMT(for: naive.addingTimeInterval(-day)),
            timeZone.secondsFromGMT(for: naive),
            timeZone.secondsFromGMT(for: naive.addingTimeInterval(day)),
        ])
        let instants = offsets
            .map { naive.addingTimeInterval(-TimeInterval($0)) }
            .filter { instant in
                let offset = TimeInterval(timeZone.secondsFromGMT(for: instant))
                return instant.addingTimeInterval(offset) == naive
            }
            .sorted()
        switch instants.count {
        case 0: return .nonexistent
        case 1: return .unique(instants[0])
        default: return .ambiguous(earlier: instants[0], later: instants[instants.count - 1])
        }
    }
}
