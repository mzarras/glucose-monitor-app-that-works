// Original to Sensor (no ported code).
// Fixture documents and builders. No test touches the network.
//
// Fixtures/:
//   site_latest.json, site_metrics.json    zen-predict-infra site/fixtures/{latest,metrics}.json @ 3f3d682,
//                                          copied verbatim: the dashboard's sample documents
//                                          (site/app.js `SAMPLE`, "so the page previews from a local
//                                          checkout"); integer values, "Z" timestamps, no fraction.
//   synthetic_latest_live_format.json      synthetic values in the live feed's exact format (Python
//                                          `isoformat()`: 6-digit fractions, "+00:00"; two-decimal
//                                          Zen values; compact JSON): the run is on the newest reading.
//   synthetic_latest_lagging_run.json      the same format, with the run 5 minutes behind the newest
//                                          reading (as the live feed was before zen-predict-infra
//                                          3f3d682 made predict trigger publish).
//   synthetic_metrics_live_format.json     metrics.json in the live format, synthetic values.
// No real glucose values, model results or hosts are committed (review of 79c2c40).
//
// Epoch seconds used in assertions, worked by hand: 2026-01-01T00:00Z = 1_767_225_600
// (2025-01-01 = 1_735_689_600, + 365 × 86_400). 8 October is day 281, so 2026-10-08T00:00Z =
// 1_767_225_600 + 280 × 86_400 = 1_791_417_600. Then:
//   14:20:05 = 51_605 s → 1_791_469_205;  14:20:41 = 51_641 s → 1_791_469_241
//   14:25:05 = 51_905 s → 1_791_469_505;  14:30:06 = 52_206 s → 1_791_469_806
//   14:30:42 = 52_242 s → 1_791_469_842
// 31 July is day 212, so 2026-07-31T12:03:00Z = 1_767_225_600 + 211 × 86_400 + 43_380 = 1_785_499_380.

import Foundation
import XCTest
@testable import ForecastKit

enum FeedFixtures {
    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"), "missing fixture \(name)")
        return try Data(contentsOf: url)
    }

    /// 2026-10-08T00:00:00Z.
    static let october8 = Date(timeIntervalSince1970: 1_791_417_600)

    /// A time on 8 October 2026 (UTC).
    static func october8(_ hour: Int, _ minute: Int, _ second: Double = 0) -> Date {
        october8.addingTimeInterval(Double(hour * 3600 + minute * 60) + second)
    }

    /// The fixed "now" for synthetic documents: 2026-10-08T19:00:00Z.
    static let now = october8(19, 0)

    /// The monotonic reading tests pair with `now` unless they move it. Arbitrary: only
    /// differences between monotonic readings mean anything.
    static let monotonicAtNow: TimeInterval = 50_000

    /// An instant whose wall clock reads `wall`. By default the monotonic clock agrees with the
    /// wall clock (no clock change since `now`/`monotonicAtNow`); pass `monotonic` to model a
    /// changed wall clock.
    static func instant(_ wall: Date, monotonic: TimeInterval? = nil) -> ForecastInstant {
        ForecastInstant(wall: wall, monotonic: monotonic ?? monotonicAtNow + wall.timeIntervalSince(now))
    }

    /// `now` as an instant.
    static let nowInstant = instant(now)

    /// Formats like the live feed (Python `isoformat()` of a UTC datetime): 6-digit fraction,
    /// "+00:00". Whole seconds are written without a fraction, as Python does.
    static func pythonISO(_ date: Date) -> String {
        let seconds = date.timeIntervalSince1970
        let whole = seconds.rounded(.down)
        let micros = Int(((seconds - whole) * 1_000_000).rounded())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: whole))
        let base = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        return micros == 0 ? base + "+00:00" : base + String(format: ".%06d", micros) + "+00:00"
    }

    /// The synthetic model version every builder and synthetic fixture uses.
    static let modelVersion = "20261001T000000-0f0f0f0f"

    /// A valid latest.json as a mutable object: published 30 s before `now`, the run 2 min before.
    /// Synthetic values.
    static func latestObject(now: Date = now) -> [String: Any] {
        [
            "as_of": pythonISO(now.addingTimeInterval(-30)),
            "bg": ["ts": pythonISO(now.addingTimeInterval(-60)), "mg_dl": 108, "trend": "FortyFiveUp"],
            "predictions": [
                "generated_at": pythonISO(now.addingTimeInterval(-120)),
                "zen": ["5": 110.42, "30": 127.06, "60": 141.93, "120": 152.37],
                "oref": ["5": 111, "30": 129, "60": 146.5, "120": 160],
            ] as [String: Any],
            "model_version": modelVersion,
        ]
    }

    /// A valid metrics.json as a mutable object, published 30 s before `now`. Synthetic values;
    /// both windows the same.
    static func metricsObject(now: Date = now) -> [String: Any] {
        let window: [String: Any] = [
            "mae": ["5": 5.12, "30": 16.4, "60": 24.73, "120": 31.86],
            "persistence_mae": ["5": 5.47, "30": 17.95, "60": 27.31, "120": 38.6],
            "win_rate_vs_oref": ["5": 0.5512, "30": 0.5734, "60": 0.6081, "120": 0.6417],
            "n": 2016,
            "parkes_ab_pct": 98.12,
        ]
        return [
            "as_of": pythonISO(now.addingTimeInterval(-30)),
            "windows": ["7d": window, "30d": window],
            "model_version": modelVersion,
        ]
    }

    /// latest.json whose run (and reading) is at `generatedAt`, published 30 s later.
    static func latestBody(runAt generatedAt: Date, zen5: Double = 110.42) -> Data {
        var object = setting(["as_of"], to: pythonISO(generatedAt.addingTimeInterval(30)), in: latestObject())
        object = setting(["predictions", "generated_at"], to: pythonISO(generatedAt), in: object)
        object = setting(["predictions", "zen", "5"], to: zen5, in: object)
        object = setting(["bg", "ts"], to: pythonISO(generatedAt), in: object)
        return json(object)
    }

    /// `object` with the value at `path` replaced (`NSNull()` for null) or, with `nil`, removed.
    static func setting(_ path: [String], to value: Any?, in object: [String: Any]) -> [String: Any] {
        var copy = object
        guard let key = path.first else { return copy }
        if path.count == 1 {
            copy[key] = value
        } else {
            let child = copy[key] as? [String: Any] ?? [:]
            copy[key] = setting(Array(path.dropFirst()), to: value, in: child)
        }
        return copy
    }

    static func json(_ object: Any) -> Data {
        // Test inputs are built from literals; serialization cannot fail for them.
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func json(_ text: String) -> Data { Data(text.utf8) }
}
