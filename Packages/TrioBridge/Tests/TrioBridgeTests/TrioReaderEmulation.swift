// Test-only model of how Trio reads `latestReadings`, written from the contract in docs/trio-bridge.md
// ("How Trio reads the key"). It is not Trio code (Trio is AGPL-3.0 and nothing is copied); each rule
// names the Trio line it models so a reviewer can compare. Reference: Trio main @ 29350e31a,
// `Trio/Sources/APS/CGM/AppGroupSource.swift`.

import Foundation

enum TrioReaderEmulation {
    struct Element: Equatable {
        let mgdl: Int
        let date: Date
        let direction: String
    }

    enum Failure: Error, Equatable {
        /// Trio force-unwraps `Double(...)` of the text inside "DT"'s parentheses (`:104-115`); this input
        /// would crash it.
        case wouldCrashTrio(dt: String)
    }

    /// The `BloodGlucose.Direction` raw values Trio can store (`Trio/Sources/Models/BloodGlucose.swift:6-18`).
    static let trioDirectionRawValues: Set<String> = [
        "TripleUp", "DoubleUp", "SingleUp", "FortyFiveUp", "Flat", "FortyFiveDown", "SingleDown",
        "DoubleDown", "TripleDown", "NONE", "NOT COMPUTABLE", "RATE OUT OF RANGE",
    ]

    /// The elements Trio would accept from `data`, in array order, and the ones it would skip.
    static func read(_ data: Data, sourceFrom: String = "xDrip") throws -> (accepted: [Element], skipped: Int) {
        // `:54-57`: JSONSerialization; anything but a top-level array yields nothing.
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return ([], 0) }
        var accepted: [Element] = []
        var skipped = 0
        // `:40`, `:61`: only the first 60 elements are looked at.
        for case let element as [String: Any] in array.prefix(60) {
            // `:62-66`: "Value" must bridge to Int, "DT" must be a String.
            guard let value = element["Value"] as? Int, let dt = element["DT"] as? String,
                  let date = try parseDate(dt)
            else {
                skipped += 1
                continue
            }
            // `:70-81`: "direction" string first, then integer/string trend ordinals; none → skipped.
            let direction: String?
            if let text = element["direction"] as? String {
                direction = text
            } else if let trend = (element["trend"] as? Int) ?? (element["Trend"] as? Int) ?? (element["trend"] as? String).flatMap({ Int($0) }),
                      (1...7).contains(trend) {
                direction = ["DoubleUp", "SingleUp", "FortyFiveUp", "Flat", "FortyFiveDown", "SingleDown", "DoubleDown"][trend - 1]
            } else {
                direction = nil
            }
            guard let direction else {
                skipped += 1
                continue
            }
            // `:83-85`: an element naming a different "from" is skipped; one without "from" is kept.
            if let from = element["from"] as? String, from != sourceFrom {
                skipped += 1
                continue
            }
            accepted.append(Element(mgdl: value, date: date, direction: direction))
        }
        return (accepted, skipped)
    }

    /// `:104-115`: the greedy "(...)" group, parsed as milliseconds since 1970. No parentheses → nil
    /// (Trio skips the element); parentheses around a non-number → Trio crashes.
    private static func parseDate(_ dt: String) throws -> Date? {
        guard let open = dt.firstIndex(of: "("), let close = dt.lastIndex(of: ")"), open < close else { return nil }
        guard let milliseconds = Double(dt[dt.index(after: open)..<close]) else { throw Failure.wouldCrashTrio(dt: dt) }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
