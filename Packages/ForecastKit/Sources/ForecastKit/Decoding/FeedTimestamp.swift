// Original to Sensor (no ported code).
// Parses the feed's timestamps. Written out by hand rather than with ISO8601DateFormatter, whose
// fractional-second option rejects timestamps without a fraction and has varied in how many
// digits it accepts; every rule below is visible and tested (S8).
//
// Formats the feed produces:
//   live feed:   2026-10-08T18:46:13.580641+00:00   (Python `datetime.isoformat()`, UTC)
//   live feed:   2026-10-08T18:46:13+00:00          (isoformat() omits the fraction when it is 0)
//   fixtures:    2026-07-31T12:03:00Z               (zen-predict-infra site/fixtures/*.json)

import Foundation

enum FeedTimestamp {
    /// Parses `YYYY-MM-DDTHH:MM:SS[.fraction](Z|+HH:MM|-HH:MM)`; nil for anything else.
    ///
    /// The fraction may have any number of digits (Python emits 6). The date must exist in the
    /// Gregorian calendar (no 31 February); hour 0…23, minute and second 0…59 (no leap second);
    /// offset hours 0…23, minutes 0…59. No other separators, lower-case letters or missing parts.
    static func parse(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        // "YYYY-MM-DDTHH:MM:SS" is 19 bytes; the shortest valid string adds "Z".
        guard bytes.count >= 20,
              bytes[4] == ascii("-"), bytes[7] == ascii("-"), bytes[10] == ascii("T"),
              bytes[13] == ascii(":"), bytes[16] == ascii(":"),
              let year = number(bytes, 0..<4), let month = number(bytes, 5..<7), let day = number(bytes, 8..<10),
              let hour = number(bytes, 11..<13), let minute = number(bytes, 14..<16), let second = number(bytes, 17..<19)
        else { return nil }

        var index = 19
        var fraction = 0.0
        if bytes[index] == ascii(".") {
            let start = index + 1
            var end = start
            while end < bytes.count, isDigit(bytes[end]) { end += 1 }
            guard end > start, let value = Double("0." + String(decoding: bytes[start..<end], as: UTF8.self)) else { return nil }
            fraction = value
            index = end
        }

        guard let offsetSeconds = utcOffset(bytes, from: index) else { return nil }
        guard hour <= 23, minute <= 59, second <= 59 else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard components.isValidDate(in: calendar), let wallClock = calendar.date(from: components) else { return nil }
        // The written time is UTC + offset, so UTC = written time − offset.
        return wallClock.addingTimeInterval(fraction - TimeInterval(offsetSeconds))
    }

    /// Seconds east of UTC for the zone designator starting at `index`, which must end the string.
    private static func utcOffset(_ bytes: [UInt8], from index: Int) -> Int? {
        guard index < bytes.count else { return nil }
        if bytes[index] == ascii("Z") { return index == bytes.count - 1 ? 0 : nil }
        let sign: Int
        switch bytes[index] {
        case ascii("+"): sign = 1
        case ascii("-"): sign = -1
        default: return nil
        }
        // "+HH:MM" is exactly 6 bytes and must end the string.
        guard bytes.count - index == 6, bytes[index + 3] == ascii(":"),
              let hours = number(bytes, (index + 1)..<(index + 3)), let minutes = number(bytes, (index + 4)..<(index + 6)),
              hours <= 23, minutes <= 59
        else { return nil }
        return sign * (hours * 3600 + minutes * 60)
    }

    /// The decimal number in `bytes[range]`, nil unless every byte is an ASCII digit.
    private static func number(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
        var value = 0
        for byte in bytes[range] {
            guard isDigit(byte) else { return nil }
            value = value * 10 + Int(byte - ascii("0"))
        }
        return value
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= ascii("0") && byte <= ascii("9") }

    private static func ascii(_ character: Unicode.Scalar) -> UInt8 { UInt8(character.value) }
}
