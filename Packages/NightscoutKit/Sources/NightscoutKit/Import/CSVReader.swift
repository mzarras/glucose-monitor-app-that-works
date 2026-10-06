// Original to Sensor (no ported code).
// A small RFC 4180 CSV reader, enough for Dexcom Clarity exports: comma separator, optional
// double-quoted fields with "" escapes, CRLF or LF line endings, optional UTF-8 byte-order mark
// (real exports have both a BOM and CRLF).

import Foundation

enum CSVReader {
    struct MalformedCSV: Error, Sendable, Equatable {
        let line: Int
        let reason: String
    }

    /// Parses `text` into rows of fields. Empty lines are dropped.
    static func rows(from text: String) throws(MalformedCSV) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var line = 1
        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }

        var index = 0
        func endRow() {
            row.append(field)
            field = ""
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }
        while index < scalars.count {
            let scalar = scalars[index]
            if inQuotes {
                if scalar == "\"" {
                    if index + 1 < scalars.count, scalars[index + 1] == "\"" {
                        field.unicodeScalars.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    if scalar == "\n" { line += 1 }
                    field.unicodeScalars.append(scalar)
                }
            } else {
                switch scalar {
                case "\"":
                    guard field.isEmpty else { throw MalformedCSV(line: line, reason: "quote inside an unquoted field") }
                    inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\r":
                    // CRLF: the LF ends the row. A lone CR also ends it.
                    if index + 1 < scalars.count, scalars[index + 1] == "\n" { index += 1 }
                    endRow()
                    line += 1
                case "\n":
                    endRow()
                    line += 1
                default:
                    field.unicodeScalars.append(scalar)
                }
            }
            index += 1
        }
        guard !inQuotes else { throw MalformedCSV(line: line, reason: "unterminated quoted field") }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
