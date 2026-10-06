import GlucoseCore
import XCTest
@testable import WidgetCore

final class ChartScrubTests: XCTestCase {
    private let base = Fixture.now

    private func at(_ minutes: Double, _ value: GlucoseValue) -> ChartPoint {
        ChartPoint(date: base.addingTimeInterval(minutes * 60), value: value)
    }

    private func date(_ minutes: Double) -> Date {
        base.addingTimeInterval(minutes * 60)
    }

    private func time(_ date: Date) -> String {
        "t+\(Int(date.timeIntervalSince(base) / 60))"
    }

    // MARK: S1

    func test_S1_scrubSnapsToRealReadingsAndNeverInterpolates() {
        // 0: 100, 5: 110, 10: 120 (then a 10-minute step, still joined), 20: 140
        let points = [at(0, .mgdl(100)), at(5, .mgdl(110)), at(10, .mgdl(120)), at(20, .mgdl(140))]
        let input = Set(points)

        // Sweep the finger across the whole span in 10-second steps: every selection is one of the
        // input readings, unchanged; nothing in between is ever produced.
        var minute = -2.0
        while minute <= 22 {
            let selection = ChartScrub.select(at: date(minute), in: points)
            if let reading = selection.reading {
                XCTAssertTrue(input.contains(reading), "at \(minute) min: \(reading) is not a stored reading")
            }
            if case .gap = selection { XCTFail("no gap > 15 min in this data (at \(minute) min)") }
            minute += 1.0 / 6
        }

        XCTAssertEqual(ChartScrub.select(at: date(2.4), in: points), .reading(at(0, .mgdl(100))), "nearest, not 104.8")
        XCTAssertEqual(ChartScrub.select(at: date(2.6), in: points), .reading(at(5, .mgdl(110))))
        XCTAssertEqual(ChartScrub.select(at: date(2.5), in: points), .reading(at(0, .mgdl(100))), "a tie goes to the earlier reading")
        XCTAssertEqual(ChartScrub.select(at: date(14), in: points), .reading(at(10, .mgdl(120))), "10-min step: nearest reading, not 128")
        XCTAssertEqual(ChartScrub.select(at: date(20), in: points), .reading(at(20, .mgdl(140))))
        // Beyond the data: only within the snap tolerance.
        XCTAssertEqual(ChartScrub.select(at: date(22.5), in: points), .reading(at(20, .mgdl(140))))
        XCTAssertEqual(ChartScrub.select(at: date(22.6), in: points), .none)
        XCTAssertEqual(ChartScrub.select(at: date(-3), in: points), .none)
        XCTAssertEqual(ChartScrub.select(at: date(5), in: []), .none)
    }

    func test_S1_scrubInGapShowsNoData() {
        // 45-minute signal gap between 10 and 55.
        let points = [at(0, .mgdl(100)), at(5, .mgdl(102)), at(10, .mgdl(104)), at(55, .mgdl(150)), at(60, .mgdl(152))]
        XCTAssertEqual(ChartScrub.select(at: date(30), in: points), .gap(from: date(10), to: date(55)))
        XCTAssertEqual(ChartScrub.select(at: date(12.6), in: points), .gap(from: date(10), to: date(55)))
        XCTAssertEqual(ChartScrub.select(at: date(12.5), in: points), .reading(at(10, .mgdl(104))), "edge of the gap snaps to the real reading")
        XCTAssertEqual(ChartScrub.select(at: date(52.5), in: points), .reading(at(55, .mgdl(150))))

        let callout = ChartScrub.callout(.gap(from: date(10), to: date(55)), time: time)
        XCTAssertEqual(callout?.headline, "No data")
        XCTAssertEqual(callout?.detail, "t+10 – t+55")
        XCTAssertNil(callout?.time)

        // No haptic tick into or inside a gap, and no highlighted reading.
        let before = ChartScrub.select(at: date(10), in: points)
        let inGap = ChartScrub.select(at: date(30), in: points)
        XCTAssertNil(inGap.reading)
        XCTAssertNil(ChartScrub.feedback(from: before, to: inGap))
        XCTAssertNil(ChartScrub.feedback(from: inGap, to: ChartScrub.select(at: date(31), in: points)))
        // Leaving the gap onto a reading ticks.
        XCTAssertEqual(ChartScrub.feedback(from: inGap, to: ChartScrub.select(at: date(55), in: points)), .selection)
        // Exactly 15 minutes is not a gap (the line is joined there too).
        let joined = [at(0, .mgdl(100)), at(15, .mgdl(110))]
        XCTAssertEqual(ChartScrub.select(at: date(7), in: joined), .reading(at(0, .mgdl(100))))
    }

    // MARK: S4

    func test_S4_scrubShowsLowHighAsText() {
        let points = [at(0, .mgdl(45)), at(5, .belowRange), at(10, .aboveRange)]
        let low = ChartScrub.select(at: date(5), in: points)
        XCTAssertEqual(low, .reading(at(5, .belowRange)))
        let lowCallout = ChartScrub.callout(low, time: time)
        XCTAssertEqual(lowCallout?.headline, "LOW")
        XCTAssertEqual(lowCallout?.detail, "below sensor range")
        XCTAssertEqual(lowCallout?.spoken, "LOW, below the sensor's range at t+5")

        let highCallout = ChartScrub.callout(ChartScrub.select(at: date(10), in: points), time: time)
        XCTAssertEqual(highCallout?.headline, "HIGH")
        XCTAssertEqual(highCallout?.detail, "above sensor range")
        for callout in [lowCallout, highCallout] {
            XCTAssertFalse(callout?.headline.contains("40") ?? true)
            XCTAssertFalse(callout?.spoken.contains("400") ?? true)
            XCTAssertFalse(callout?.detail.contains("mg/dL") ?? true)
        }
    }

    // MARK: Haptics, VoiceOver stepping, callout

    func test_feedbackOnlyForADifferentReading_strongerAcrossBands() {
        let a = ScrubSelection.reading(at(0, .mgdl(100)))
        let b = ScrubSelection.reading(at(5, .mgdl(110)))
        let low = ScrubSelection.reading(at(10, .mgdl(65)))
        XCTAssertEqual(ChartScrub.feedback(from: .none, to: a), .selection, "first touch on a reading")
        XCTAssertNil(ChartScrub.feedback(from: a, to: a), "same reading again")
        XCTAssertEqual(ChartScrub.feedback(from: a, to: b), .selection)
        XCTAssertEqual(ChartScrub.feedback(from: b, to: low), .bandChange, "in range → low")
        XCTAssertNil(ChartScrub.feedback(from: b, to: .none))
    }

    func test_stepMovesThroughRealReadings() {
        let points = [at(10, .mgdl(120)), at(0, .mgdl(100)), at(5, .belowRange)]
        XCTAssertEqual(ChartScrub.step(from: nil, forward: true, in: points), at(10, .mgdl(120)), "starts at the latest")
        XCTAssertEqual(ChartScrub.step(from: at(10, .mgdl(120)), forward: false, in: points), at(5, .belowRange))
        XCTAssertEqual(ChartScrub.step(from: at(5, .belowRange), forward: false, in: points), at(0, .mgdl(100)))
        XCTAssertNil(ChartScrub.step(from: at(0, .mgdl(100)), forward: false, in: points))
        XCTAssertNil(ChartScrub.step(from: at(10, .mgdl(120)), forward: true, in: points))
    }

    func test_readingCallout() {
        let callout = ChartScrub.callout(.reading(at(15, .mgdl(105))), time: time)
        XCTAssertEqual(callout, ScrubCallout(headline: "105", detail: "mg/dL", time: "t+15", spoken: "105 milligrams per deciliter at t+15"))
        XCTAssertNil(ChartScrub.callout(.none, time: time))
    }
}

final class ScrubCalloutPlacementTests: XCTestCase {
    func test_calloutSitsBesideTheRuleAndInsideThePlot() {
        // Room on the right: 8 pt right of the rule.
        XCTAssertEqual(PlacedScrubCallout.left(ruleX: 100, width: 80, plotWidth: 300), 108)
        // No room on the right: 8 pt left of the rule.
        XCTAssertEqual(PlacedScrubCallout.left(ruleX: 280, width: 80, plotWidth: 300), 192)
        // Wider than either side: pinned to the left edge rather than leaving the plot.
        XCTAssertEqual(PlacedScrubCallout.left(ruleX: 50, width: 280, plotWidth: 300), 0)
        // Never covers the rule when it fits on either side.
        for ruleX in stride(from: CGFloat(0), through: 300, by: 10) {
            let left = PlacedScrubCallout.left(ruleX: ruleX, width: 90, plotWidth: 300)
            XCTAssertTrue(left >= ruleX || left + 90 <= ruleX, "rule at \(ruleX) is under the callout")
        }
    }
}
